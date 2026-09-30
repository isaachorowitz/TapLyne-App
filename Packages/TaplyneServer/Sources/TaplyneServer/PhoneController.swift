import Foundation

/// A one-shot gate so a continuation is resumed exactly once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// Runs `op`, returning nil if it has not finished within `seconds`.
func withDeadline<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
    await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        let once = Once()
        let work = Task {
            let value = await op()
            if once.fire() { cont.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if once.fire() {
                work.cancel()
                cont.resume(returning: nil)
            }
        }
    }
}

/// FIFO mutual exclusion keyed by phone, so gestures on one phone never interleave.
actor PhoneLock {
    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ id: String) async {
        if busy.contains(id) {
            await withCheckedContinuation { waiters[id, default: []].append($0) }
        } else {
            busy.insert(id)
        }
    }

    func release(_ id: String) {
        if var queue = waiters[id], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[id] = queue.isEmpty ? nil : queue
            next.resume()  // ownership passes straight to the next waiter
        } else {
            busy.remove(id)
        }
    }
}

/// Shared by REST and MCP: phone lookup, per-phone serialization, deadlines, and jobs.
final class PhoneController: Sendable {
    let service: any PhoneService
    let jobs = JobStore()
    let automation: PhoneAutomation
    private let lock = PhoneLock()
    let timeout: Double

    init(service: any PhoneService, timeout: Double = 60) {
        self.service = service
        self.automation = PhoneAutomation(service: service)
        self.timeout = timeout
    }

    func phone(_ id: String) async throws(APIError) -> PhoneRecord {
        guard let phone = await service.listPhones().first(where: { $0.id == id }) else {
            throw .phoneNotFound(id)
        }
        return phone
    }

    func onlinePhone(_ id: String) async throws(APIError) -> PhoneRecord {
        let p = try await phone(id)
        guard p.connectionStatus == .online else {
            throw APIError(
                status: 409, code: "PHONE_NOT_READY",
                message: p.statusReason ?? "Phone is \(p.connectionStatus.rawValue)",
                context: ["phone_id": id, "connection_status": p.connectionStatus.rawValue])
        }
        return p
    }

    /// Runs `work` under the deadline, optionally holding the phone's lock. Failure carries the job error string.
    func run<T: Sendable>(
        phoneID: String, serialized: Bool, deadline: Double? = nil, work: @escaping @Sendable () async throws -> T
    ) async -> Result<T, JobFailure> {
        let lock = self.lock
        let outcome = await withDeadline(deadline ?? timeout) { () async -> Result<T, JobFailure> in
            if serialized {
                await lock.acquire(phoneID)
                // A caller that already timed out must not run its gesture late.
                if Task.isCancelled {
                    await lock.release(phoneID)
                    return .failure(JobFailure(CancellationError()))
                }
            }
            let result: Result<T, JobFailure>
            do { result = .success(try await work()) } catch { result = .failure(JobFailure(error)) }
            if serialized { await lock.release(phoneID) }
            return result
        }
        return outcome ?? .failure(JobFailure(InputFailure(PhoneServiceError.timeout, delivery: serialized ? .unknown : .notDelivered)))
    }

    /// Creates a job that performs `work`; the returned task finishes when the job does.
    func submit(
        phoneID: String, serialized: Bool,
        work: @escaping @Sendable () async throws -> Data?
    ) async -> (job: Job, done: Task<Void, Never>) {
        await submitPayload(phoneID: phoneID, serialized: serialized) {
            JobPayload(data: try await work())
        }
    }

    func submitPayload(phoneID: String, serialized: Bool, deadline: Double? = nil,
                       work: @escaping @Sendable () async throws -> JobPayload) async -> (job: Job, done: Task<Void, Never>) {
        let job = await jobs.create()
        let store = jobs
        let id = job.id
        let done = Task {
            let result = await self.run(phoneID: phoneID, serialized: serialized, deadline: deadline) {
                await store.markRunning(id)
                return try await work()
            }
            switch result {
            case .success(let payload): await store.finish(id, error: nil, data: payload.data, contentType: payload.contentType, resultData: payload.resultData)
            case .failure(let f): await store.finish(id, error: f.message, resultData: f.delivery.map { JSON.data($0.json) })
            }
        }
        return (job, done)
    }
}

struct JobPayload: Sendable {
    var data: Data?
    var contentType = "image/png"
    var resultData: Data?
}

struct JobFailure: Error, Sendable {
    var message: String
    var underlying: PhoneServiceError?
    var delivery: InputFailure?

    init(_ error: Error) {
        message = jobErrorString(error)
        underlying = error as? PhoneServiceError
        delivery = error as? InputFailure
    }

    init(message: String, underlying: PhoneServiceError) {
        self.message = message
        self.underlying = underlying
    }
}
