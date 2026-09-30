import Foundation

enum JobStatus: String, Sendable { case pending, running, completed, failed }

struct Job: Sendable {
    var id: String
    var status: JobStatus
    var error: String?
    var createdAt: Date
    var completedAt: Date?
    /// PNG bytes for async screenshot jobs.
    var data: Data?
    var contentType = "image/png"
    var resultData: Data?

    var json: [String: Any] {
        [
            "id": id, "status": status.rawValue,
            "result": resultData.flatMap(JSON.object) ?? error.map { ["error": $0] } ?? [:],
            "created_at": JSON.iso(createdAt),
            "completed_at": completedAt.map { JSON.iso($0) } ?? NSNull(),
        ]
    }
}

/// In-memory job store keeping the most recent 500 jobs.
actor JobStore {
    static let capacity = 500
    /// Screenshot payloads are large, so only the newest few keep their bytes.
    static let payloadCapacity = 20
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var payloads: [String] = []

    func create() -> Job {
        let job = Job(id: UUID().uuidString.lowercased(), status: .pending, createdAt: Date())
        jobs[job.id] = job
        order.append(job.id)
        while order.count > Self.capacity { jobs[order.removeFirst()] = nil }
        return job
    }

    func get(_ id: String) -> Job? { jobs[id] }

    func markRunning(_ id: String) {
        if jobs[id]?.status == .pending { jobs[id]?.status = .running }
    }

    func finish(_ id: String, error: String?, data: Data? = nil, contentType: String = "image/png", resultData: Data? = nil) {
        guard var job = jobs[id], job.status == .pending || job.status == .running else { return }
        job.status = error == nil ? .completed : .failed
        job.error = error
        job.completedAt = Date()
        job.data = data
        job.contentType = contentType
        job.resultData = resultData
        jobs[id] = job
        if data != nil && contentType != "application/json" {
            payloads.append(id)
            while payloads.count > Self.payloadCapacity {
                let expired = payloads.removeFirst()
                jobs[expired]?.data = nil
            }
        }
    }
}
