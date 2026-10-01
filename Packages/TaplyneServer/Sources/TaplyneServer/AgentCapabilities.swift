import Foundation

/// Updating a device capability does not restart listeners or interrupt active requests.
final class AgentCapabilities: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (key: String, server: MCPServer)] = [:]
    private let service: any PhoneService
    private let version: String
    init(service: any PhoneService, version: String, keys: [String: String]) {
        self.service = service; self.version = version
        for (id, key) in keys { register(phoneID: id, key: key) }
    }
    func register(phoneID: String, key: String) {
        let server = MCPServer(controller: PhoneController(service: ScopedPhoneService(base: service, deviceID: phoneID)), version: version)
        lock.withLock { entries[phoneID] = (key, server) }
    }
    func server(for key: String) -> MCPServer? {
        lock.withLock { entries.values.first(where: { Router.constantTimeEqual($0.key, key) })?.server }
    }
}
