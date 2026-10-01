import Foundation
import TaplyneServer

struct RelayDeviceProfile: Codable {
    var runnerHost: RelayConfiguration
    var runnerDevice: RelayConfiguration
    var conversationHost: RelayConfiguration
    var conversationDevice: RelayConfiguration
    static func load(_ id: String) -> Self? {
        guard let value = Keychain.read("relay-" + id), let data = Data(base64Encoded: value) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func save(_ id: String) throws {
        guard Keychain.write(try JSONEncoder().encode(self).base64EncodedString(), account: "relay-" + id) else {
            throw RelayFailure("Could not store relay pairing securely.")
        }
    }
}

@MainActor
extension AppModel {
    func createRelay(for phone: Phone, endpoint: URL, enrollment: String) throws -> RelayDeviceProfile {
        let runner = try RelayConfiguration.pair(endpoint: endpoint, scope: .runner, enrollment: enrollment.isEmpty ? nil : enrollment)
        let conversation = try RelayConfiguration.pair(endpoint: endpoint, scope: .conversation, enrollment: enrollment.isEmpty ? nil : enrollment)
        let profile = RelayDeviceProfile(runnerHost: runner.host, runnerDevice: runner.device,
                                         conversationHost: conversation.host, conversationDevice: conversation.device)
        let companionKey = APIKeyGenerator.generate()
        try profile.save(phone.udid)
        guard Keychain.write(companionKey, account: "companion-" + phone.udid) else {
            Keychain.delete("relay-" + phone.udid)
            throw RelayFailure("Could not store companion pairing securely.")
        }
        registry.detachRemote(phone)
        phone.config.relayEnabled = true
        phone.config.remoteEndpoint = nil
        registry.attachRelay(phone)
        startServer()
        return profile
    }

    /// Revoke both companion authorization and its relay credentials, retaining runner pairing.
    @discardableResult
    func rotateCompanionPairing(for phone: Phone) throws -> String {
        let key = APIKeyGenerator.generate()
        if var profile = RelayDeviceProfile.load(phone.udid), phone.config.relayEnabled == true {
            let old = profile
            let pair = try RelayConfiguration.pair(endpoint: profile.conversationHost.endpoint, scope: .conversation,
                                                    enrollment: profile.conversationHost.enrollmentToken)
            profile.conversationHost = pair.host; profile.conversationDevice = pair.device
            try profile.save(phone.udid)
            guard Keychain.write(key, account: "companion-" + phone.udid) else {
                try? old.save(phone.udid)
                throw RelayFailure("Could not rotate the companion key.")
            }
            phone.conversationRelay?.stop(); phone.conversationRelay = nil
            try registry.attachConversationRelay(phone, configuration: pair.host)
        } else {
            guard Keychain.write(key, account: "companion-" + phone.udid) else { throw RelayFailure("Could not save the companion key.") }
        }
        // Fence any old-channel commands already accepted by the previous HTTP server.
        phone.control(.pause)
        startServer()
        return key
    }

    func relayPairing(for phone: Phone) throws -> URL {
        guard let profile = RelayDeviceProfile.load(phone.udid), let key = Keychain.read("companion-" + phone.udid) else {
            throw RelayFailure("Set up this device's relay first.")
        }
        return try RelayCompanionPairing(configuration: profile.conversationDevice, phoneID: phone.udid, companionKey: key).url()
    }

    func revokeRelay(_ phone: Phone) {
        registry.detachRemote(phone)
        Keychain.delete("relay-" + phone.udid)
        Keychain.delete("companion-" + phone.udid)
        phone.config.relayEnabled = nil
        registry.scheduleRefresh(delay: 0)
        startServer()
    }
}

@MainActor
extension PhoneRegistry {
    func detachRemote(_ phone: Phone) {
        phone.control(.stop)
        phone.remoteTask?.cancel(); phone.remoteTask = nil
        phone.runnerRelay?.stop(); phone.runnerRelay = nil
        phone.conversationRelay?.stop(); phone.conversationRelay = nil
        phone.remote = nil; phone.remoteImage = nil
        phone.plugged = false; phone.readiness = .unplugged
    }

    func attachRelay(_ phone: Phone) {
        guard phone.remote == nil, phone.config.relayEnabled == true else { return }
        guard let profile = RelayDeviceProfile.load(phone.udid) else {
            phone.lastError = "Relay pairing is missing. Run remote setup again."; return
        }
        do {
            let runner = try RelayPeer(configuration: profile.runnerHost)
            let connection = try WebDriverConnection(endpoint: URL(string: "http://127.0.0.1:8100")!, exchange: { method, path, body in
                let request = RelayRequest(method: method, path: path, body: body, expiresAt: Date().addingTimeInterval(method == "GET" ? 20 : 5))
                let reply = try await runner.request(request)
                return (reply.body, reply.status)
            })
            runner.onDisconnect = { [weak phone] in
                phone?.control(.pause); phone?.plugged = false; phone?.readiness = .waitingForScreen
                phone?.lastError = "Runner disconnected. Inspect the device and resume manually after reconnecting."
            }
            phone.runnerRelay = runner
            phone.remote = connection
            try attachConversationRelay(phone, configuration: profile.conversationHost)
            runner.start()
            pollRemote(phone, connection: connection)
        } catch { phone.lastError = error.localizedDescription }
    }

    func attachConversationRelay(_ phone: Phone, configuration: RelayConfiguration) throws {
        let conversation = try RelayPeer(configuration: configuration)
            conversation.requestHandler = { [weak self, weak phone] request in
                guard let self, let phone, self.phone(phone.udid) === phone,
                      RelayCompanionPolicy.allows(request, phoneID: phone.udid),
                      let port = self.relayServerPort?(),
                      let base = URL(string: "http://127.0.0.1:\(port)") else { return .failure(request, status: 403) }
                do { return try await RelayHTTP.exchange(request, baseURL: base) }
                catch { return .failure(request) }
            }
        phone.conversationRelay = conversation
        conversation.start()
    }

}
