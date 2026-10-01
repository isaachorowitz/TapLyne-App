import Foundation

/// Revocation wins over a delayed send. Voice work must renew its device-bound lease.
public struct ConversationLeaseBook {
    private struct Lease { var id: UUID; var deadline: Date }
    private var active: [String: Lease] = [:]
    private var revoked: Set<UUID> = []
    private var revocationOrder: [UUID] = []
    public init() {}
    public func currentID(phoneID: String) -> UUID? { active[phoneID]?.id }
    public mutating func grant(_ id: UUID, phoneID: String, now: Date = Date()) -> Bool {
        guard !revoked.contains(id) else { return false }
        if let previous = active[phoneID], previous.id != id { revoke(previous.id, phoneID: phoneID) }
        active[phoneID] = Lease(id: id, deadline: now.addingTimeInterval(10)); return true
    }
    public mutating func renew(_ id: UUID, phoneID: String, now: Date = Date()) -> Bool {
        guard let lease = active[phoneID], lease.id == id, lease.deadline > now, !revoked.contains(id) else { return false }
        active[phoneID]?.deadline = now.addingTimeInterval(10); return true
    }
    public mutating func revoke(_ id: UUID?, phoneID: String) {
        if let id {
            if revoked.insert(id).inserted { revocationOrder.append(id) }
            if revocationOrder.count > 1000 { revoked.remove(revocationOrder.removeFirst()) }
        }
        if id == nil || active[phoneID]?.id == id { active.removeValue(forKey: phoneID) }
    }
    public func expired(_ id: UUID, phoneID: String, now: Date = Date()) -> Bool {
        guard let lease = active[phoneID], lease.id == id else { return true }
        return lease.deadline <= now
    }
}
