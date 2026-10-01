import Foundation
import Combine

enum RelaySendAdmission {
    static func allows(requestID: UUID?, pendingIDs: Set<UUID>, currentConnection: UUID, requestConnection: UUID) -> Bool {
        guard currentConnection == requestConnection else { return false }
        guard let requestID else { return true }
        return pendingIDs.contains(requestID)
    }
}

/// Serializes outbound frames and performs admission immediately before the
/// frame is sealed. This keeps canceled or stale work from consuming a cipher
/// sequence number while an earlier frame is still queued.
@MainActor
final class RelayOutboundQueue {
    private var tail: Task<Void, Error>?
    private var count = 0
    var queuedCount: Int { count }

    func enqueue(
        admission: @escaping @MainActor () -> Bool,
        frame: @escaping @MainActor () throws -> Data,
        deliver: @escaping @MainActor (Data) async throws -> Void
    ) async throws {
        guard count < 32 else { throw RelayFailure("Remote send queue is full.") }
        let previous = tail
        count += 1
        let task = Task { @MainActor in
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            guard admission() else { throw CancellationError() }
            try await deliver(try frame())
        }
        tail = task
        defer { count = max(0, count - 1) }
        try await task.value
    }

    func reset() {
        tail?.cancel(); tail = nil; count = 0
    }
}

@MainActor
final class RelayPeer: ObservableObject {
    enum State: Equatable { case stopped, connecting, waiting, ready, failed }
    @Published private(set) var state: State = .stopped
    @Published private(set) var message = "Remote connection is stopped."
    var requestHandler: (RelayRequest) async -> RelayResponse = { .failure($0, status: 403) }
    var onDisconnect: () -> Void = {}
    let configuration: RelayConfiguration
    private var cipher: RelayCipher
    private var receiver: Task<Void, Never>?
    private var lifecycle = UUID()
    private var consecutiveFailures = 0
    private var socket: URLSessionWebSocketTask?
    private var connection = UUID()
    private var peerAvailable = false
    private var pending: [UUID: (CheckedContinuation<RelayResponse, Error>, Task<Void, Never>)] = [:]
    private var handlers: [UUID: Task<Void, Never>] = [:]
    private let outgoing = RelayOutboundQueue()
    private let session: URLSession

    init(configuration: RelayConfiguration, session: URLSession? = nil) throws {
        self.configuration = try configuration.validated()
        cipher = try RelayCipher(configuration: configuration)
        self.session = session ?? RelayHTTP.session
    }

    func start() {
        guard receiver == nil else { return }
        let run = UUID(); lifecycle = run; consecutiveFailures = 0
        receiver = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, lifecycle == run {
                do { try await connect() }
                catch {
                    if Task.isCancelled || lifecycle != run { break }
                    let replaced = socket?.closeCode.rawValue == 4001
                    resetConnection()
                    if replaced {
                        state = .failed; message = "This connection was replaced by another paired endpoint. Reconnect explicitly to take it back."
                        break
                    }
                    consecutiveFailures = min(6, consecutiveFailures + 1)
                    state = .connecting; message = "Connection interrupted. Reconnecting; commands will not be replayed."
                    do { try await Task.sleep(for: .seconds(min(30, pow(2, Double(consecutiveFailures - 1))))) }
                    catch { break }
                }
            }
            if lifecycle == run { receiver = nil }
        }
    }

    func stop() {
        lifecycle = UUID(); receiver?.cancel(); receiver = nil; resetConnection()
        state = .stopped; message = "Remote connection is stopped."
    }

    func request(_ request: RelayRequest, timeout: Double = 20) async throws -> RelayResponse {
        guard state == .ready, pending.count < 16, pending[request.id] == nil,
              request.body?.count ?? 0 <= 100_000 else { throw RelayFailure("Remote peer is not ready or busy. No request was queued.") }
        let id = request.id, requestConnection = connection
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(1, min(30, timeout)))) } catch { return }
                    self?.finish(id, result: .failure(RelayFailure("Remote request timed out. Delivery is unknown; inspect before retrying.")))
                }
                pending[id] = (continuation, timer)
                Task { [weak self] in
                    guard let self, connection == requestConnection, pending[id] != nil else { return }
                    do {
                        try await send(requestID: id) { [weak self] in
                            guard let self else { throw CancellationError() }
                            return try self.cipher.seal(.request, request: request)
                        }
                    }
                    catch { finish(id, result: .failure(RelayFailure("Remote request disconnected. Delivery is unknown; inspect before retrying."))) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, result: .failure(CancellationError())) }
        }
    }

    private func finish(_ id: UUID, result: Result<RelayResponse, Error>) {
        guard let (continuation, timer) = pending.removeValue(forKey: id) else { return }
        timer.cancel(); continuation.resume(with: result)
    }

    private func resetConnection() {
        connection = UUID(); socket?.cancel(with: .goingAway, reason: nil); socket = nil
        outgoing.reset()
        resetPeer()
    }
    private func resetPeer() {
        peerAvailable = false; cipher.reset()
        for id in Array(pending.keys) { finish(id, result: .failure(RelayFailure("Remote peer disconnected. Delivery is unknown; commands were not replayed."))) }
        for task in handlers.values { task.cancel() }; handlers.removeAll()
        onDisconnect()
    }

    private func connect() async throws {
        resetConnection()
        let epoch = connection
        state = .connecting; message = "Connecting to relay…"
        var request = URLRequest(url: configuration.endpoint.appendingPathComponent("v1/rooms/\(configuration.room)/\(configuration.role.rawValue)"), timeoutInterval: 20)
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        if let digest = configuration.peerTokenHash { request.setValue(digest, forHTTPHeaderField: "X-Taplyne-Device-Token-SHA256") }
        if let enrollment = configuration.enrollmentToken { request.setValue(enrollment, forHTTPHeaderField: "X-Taplyne-Enrollment") }
        let ws = session.webSocketTask(with: request)
        ws.maximumMessageSize = RelayCipher.maxFrame
        socket = ws; ws.resume()
        let heartbeat = Task { [weak self, weak ws] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, connection == epoch, let ws else { return }
                ws.sendPing { error in if error != nil { ws.cancel(with: .goingAway, reason: nil) } }
            }
        }
        defer { heartbeat.cancel() }
        while !Task.isCancelled, connection == epoch {
            let message = try await ws.receive()
            guard connection == epoch else { throw CancellationError() }
            switch message {
            case .string(let text):
                guard text.utf8.count < 256, let data = text.data(using: .utf8),
                      let event = try? JSONDecoder().decode(PeerEvent.self, from: data), event.type == "peer" else { throw RelayFailure("Invalid relay state.") }
                if !event.connected { resetPeer(); state = .waiting; self.message = "Waiting for the paired device." }
                else if !peerAvailable {
                    peerAvailable = true; state = .connecting; self.message = "Verifying the paired device…"
                    try await send { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try self.cipher.seal(.hello)
                    }
                }
            case .data(let data):
                guard peerAvailable else { throw RelayFailure("Unexpected encrypted message.") }
                let frame = try cipher.open(data)
                switch frame.kind {
                case .hello:
                    try await send { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try self.cipher.seal(.acknowledgment)
                    }
                case .acknowledgment: consecutiveFailures = 0; state = .ready; self.message = "Encrypted connection ready."
                case .response:
                    if let response = frame.response { finish(response.id, result: .success(response)) }
                case .request:
                    guard let request = frame.request, handlers.count < 16, handlers[request.id] == nil else { throw RelayFailure("Remote peer exceeded its request limit.") }
                    let handler = requestHandler
                    let sendCipherEpoch = cipher.localEpoch
                    handlers[request.id] = Task { [weak self] in
                        defer {
                            if let self, self.connection == epoch, self.cipher.localEpoch == sendCipherEpoch {
                                self.handlers.removeValue(forKey: request.id)
                            }
                        }
                        guard !Task.isCancelled, request.isFresh else { return }
                        let response = await handler(request)
                        guard let self, connection == epoch, cipher.localEpoch == sendCipherEpoch, !Task.isCancelled else { return }
                        do {
                            try await send { [weak self] in
                                guard let self else { throw CancellationError() }
                                return try self.cipher.seal(.response, response: response)
                            }
                        }
                        catch {
                            guard connection == epoch, cipher.localEpoch == sendCipherEpoch else { return }
                            socket?.cancel(with: .goingAway, reason: nil)
                        }
                    }
                }
            @unknown default: throw RelayFailure("Unsupported relay message.")
            }
        }
        throw CancellationError()
    }
    private func send(requestID: UUID? = nil, frame: @escaping @MainActor () throws -> Data) async throws {
        guard let socket else { throw RelayFailure("Remote send queue is unavailable.") }
        let epoch = connection, cipherEpoch = cipher.localEpoch
        try await outgoing.enqueue(
            admission: { [weak self] in
                guard let self else { return false }
                return RelaySendAdmission.allows(requestID: requestID, pendingIDs: Set(self.pending.keys),
                                                 currentConnection: self.connection, requestConnection: epoch)
                    && self.cipher.localEpoch == cipherEpoch
            },
            frame: frame,
            deliver: { data in try await socket.send(.data(data)) }
        )
    }
    private struct PeerEvent: Decodable { var type: String; var connected: Bool }
}
