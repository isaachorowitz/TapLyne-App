import Foundation
#if canImport(TaplyneServer)
import TaplyneServer
#endif
import Combine
import Security

@MainActor
final class CompanionConnection: ObservableObject {
    struct Device: Decodable, Identifiable {
        var id: String; var name: String; var displayName: String?; var connectionStatus: String
        enum CodingKeys: String, CodingKey { case id, name; case displayName = "display_name"; case connectionStatus = "connection_status" }
    }
    struct Message: Codable, Identifiable { var id: String; var kind: String; var text: String }
    struct Snapshot: Decodable { var phoneID: String; var running: Bool; var paused: Bool; var messages: [Message]; var controlGeneration: UInt64?; var serverSessionID: UUID? }
    struct Command: Encodable { let id: UUID; let action: String; let text: String?; let leaseID: UUID?; let clientID: UUID; let sequence: UInt64; let controlGeneration: UInt64; let issuedAt: Date; let serverSessionID: UUID }
    @Published var address = UserDefaults.standard.string(forKey: "serverAddress") ?? ""
    @Published var token = ""
    @Published var devices: [Device] = []
    @Published var selectedDevice = "" { didSet { snapshot = nil; spoken.removeAll(); seedHistory = true } }
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    private var retiredServerSessions: Set<UUID> = []
    private var clientID = UUID()
    private var commandSequence: UInt64 = 0
    private var generation = UUID()
    @Published private(set) var sending = false
    @Published var error: String?
    var onReply: (String) -> Void = { _ in }
    var onConnectionLost: () -> Void = {}
    var session: URLSession = PrivateHTTPClient.session
    var credentialWriter: ((String, String) throws -> Void)?
    private var poll: Task<Void, Never>?
    private var nativeVoiceTask: Task<Void, Never>?
    private var nativeVoiceTurn = UUID()
    private var voiceLeaseID: UUID?
    private var heartbeat: Task<Void, Never>?
    private var seedHistory = true
    private var spoken: Set<String> = []
    @Published private(set) var relayPairing: RelayCompanionPairing?
    private var relay: RelayPeer?
    private var baseURL: URL?
    private var sessionToken = ""

    init() {
        if let saved = readKey("relay-pairing"), let data = Data(base64Encoded: saved) {
            relayPairing = try? JSONDecoder().decode(RelayCompanionPairing.self, from: data).validated()
        }
    }

    func acceptPairing(_ url: URL) {
        if url.host == "relay" {
            do {
                let pairing = try RelayCompanionPairing.parse(url)
                disconnect(); relayPairing = pairing; address = pairing.configuration.endpoint.absoluteString; token = ""; error = nil
            } catch { self.error = error.localizedDescription }
            return
        }
        guard url.scheme == "taplyne", url.host == "pair", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fields = parts.queryItems, Set(fields.map(\.name)).count == fields.count,
              let server = fields.first(where: { $0.name == "server" })?.value, let endpoint = URL(string: server), EndpointPolicy.allows(endpoint),
              let key = fields.first(where: { $0.name == "key" })?.value, (20...200).contains(key.count) else { error = "That pairing code is invalid."; return }
        disconnect(); relayPairing = nil; address = server; token = key; error = nil
    }

    func connect() async {
        guard !connecting else { return }
        disconnect()
        connecting = true
        let attempt = generation
        defer { if generation == attempt { connecting = false } }
        error = nil
        var directURL: URL?
        do {
            if let pairing = relayPairing {
                let peer = try RelayPeer(configuration: pairing.configuration)
                relay = peer; sessionToken = pairing.companionKey; selectedDevice = pairing.phoneID
                peer.onDisconnect = { [weak self] in
                    guard let self, self.connected else { return }
                    self.onConnectionLost(); self.connected = false
                    self.error = "Relay disconnected. Reconnect to inspect progress; commands are never repeated."
                    self.poll?.cancel(); self.heartbeat?.cancel()
                }
                peer.start()
                let deadline = Date().addingTimeInterval(20)
                while peer.state != .ready, generation == attempt, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard generation == attempt, peer.state == .ready else { throw Failure("The Mac relay is unavailable. Keep Taplyne open and check its relay address.") }
            } else {
                guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), EndpointPolicy.allows(url) else {
                    throw Failure("Enter your Mac's HTTPS or local address, or scan its relay pairing code.")
                }
                directURL = url; baseURL = url
                sessionToken = token.isEmpty ? (readKey(url.absoluteString) ?? "") : token
                guard !sessionToken.isEmpty else { throw Failure("Paste this device’s companion key from Taplyne on your Mac.") }
            }
        } catch { if generation == attempt { self.error = error.localizedDescription }; return }
        do {
            let data = try await request("companion/phones")
            guard generation == attempt else { return }
            devices = try JSONDecoder().decode([Device].self, from: data)
            guard !devices.isEmpty else { throw Failure("No devices are registered on this Mac.") }
            if !devices.contains(where: { $0.id == selectedDevice }) { selectedDevice = devices[0].id }
            if let pairing = relayPairing {
                try saveKey(try JSONEncoder().encode(pairing).base64EncodedString(), account: "relay-pairing")
            } else if let url = directURL {
                try saveKey(sessionToken, account: url.absoluteString)
                SecItemDelete(keyQuery("relay-pairing") as CFDictionary)
                UserDefaults.standard.set(url.absoluteString, forKey: "serverAddress")
            }
            token = ""
            connected = true
            try await refresh(speak: false)
            guard generation == attempt else { return }
            poll = Task { [weak self] in
                while !Task.isCancelled, self?.generation == attempt {
                    do { try await Task.sleep(for: .seconds(1)); try await self?.refresh(speak: true) }
                    catch is CancellationError { return }
                    catch {
                        guard self?.generation == attempt else { return }
                        self?.error = "Connection lost. Voice-controlled work pauses when its 10-second lease expires. Reconnect to inspect progress; the last command will not be repeated."
                        self?.onConnectionLost()
                        self?.connected = false
                        return
                    }
                }
            }
        } catch { if generation == attempt { self.error = error.localizedDescription; connected = false } }
    }

    func disconnect() { if connected || connecting { onConnectionLost() }; nativeVoiceTask?.cancel(); nativeVoiceTask = nil; relay?.stop(); relay = nil; heartbeat?.cancel(); heartbeat = nil; voiceLeaseID = nil; generation = UUID(); poll?.cancel(); poll = nil; connected = false; connecting = false; sending = false; sessionToken = ""; snapshot = nil; retiredServerSessions.removeAll() }

    func send(_ action: String, text: String? = nil, leaseID: UUID? = nil) async {
        let priority = action == "pause" || action == "stop" || action == "heartbeat" || action == "releaseLease"
        guard connected, (!sending || priority), !selectedDevice.isEmpty else { return }
        if !priority { sending = true }
        let attempt = generation
        let target = selectedDevice
        defer { if generation == attempt, !priority { sending = false } }
        do {
            guard let serverSessionID = snapshot?.serverSessionID else { throw Failure("Refresh the Mac connection before issuing commands.") }
            commandSequence += 1
            let body = try JSONEncoder().encode(Command(id: UUID(), action: action, text: text, leaseID: leaseID,
                clientID: clientID, sequence: commandSequence, controlGeneration: snapshot?.controlGeneration ?? 0, issuedAt: Date(), serverSessionID: serverSessionID))
            let data = try await request("companion/conversations/\(target)", body: body)
            guard generation == attempt, selectedDevice == target else { return }
            if action == "heartbeat", leaseID != voiceLeaseID { return }
            let value = try JSONDecoder().decode(Snapshot.self, from: data)
            let restarted = snapshot?.serverSessionID != value.serverSessionID
            guard try acceptSnapshot(value) else { return }
            if !restarted { error = nil }
        } catch {
            guard generation == attempt, selectedDevice == target else { return }
            self.error = "The command's result is uncertain. Check progress before sending it again. \(error.localizedDescription)"
        }
    }

    func voiceCredential() async throws -> String {
        let data = try await request("companion/voice/\(selectedDevice)", body: Data("{}".utf8))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String], let value = object["value"] else { throw Failure("Live voice is unavailable.") }
        return value
    }

    func sendVoiceUtterance(_ text: String) {
        guard connected else { return }
        interruptVoice()
        let attempt = generation, turn = UUID(); nativeVoiceTurn = turn
        nativeVoiceTask = Task { [weak self] in
            guard let self else { return }
            defer { if nativeVoiceTurn == turn { nativeVoiceTask = nil } }
            do {
                let result = try await runVoiceTask(text)
                try Task.checkCancellation()
                if generation == attempt, nativeVoiceTurn == turn, !result.isEmpty { onReply(result) }
            }
            catch is CancellationError { }
            catch { if generation == attempt { self.error = error.localizedDescription } }
        }
    }

    func interruptVoice() {
        nativeVoiceTurn = UUID()
        nativeVoiceTask?.cancel(); nativeVoiceTask = nil
        heartbeat?.cancel(); heartbeat = nil
        let lease = voiceLeaseID; voiceLeaseID = nil
        guard let lease else { return }
        // Carry the lease id even if the send has not returned yet; server revocation wins.
        let attempt = generation, target = selectedDevice
        Task {
            guard generation == attempt, selectedDevice == target else { return }
            await send("pause", leaseID: lease)
        }
    }

    func runVoiceTask(_ text: String) async throws -> String {
        let attempt = generation
        let target = selectedDevice
        while sending {
            try Task.checkCancellation()
            guard connected, generation == attempt, selectedDevice == target else { throw Failure("Connection changed.") }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        let previous = Set(snapshot?.messages.map(\.id) ?? [])
        let lease = UUID(); voiceLeaseID = lease
        await send("send", text: text, leaseID: lease)
        try Task.checkCancellation()
        guard voiceLeaseID == lease else { throw CancellationError() }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.voiceLeaseID == lease else { return }
                await self.send("heartbeat", leaseID: lease)
                if self.error != nil { self.onConnectionLost(); return }
            }
        }
        defer { if voiceLeaseID == lease { heartbeat?.cancel(); heartbeat = nil } }
        if let error { throw Failure(error) }
        for _ in 0..<600 {
            try Task.checkCancellation()
            guard voiceLeaseID == lease else { throw CancellationError() }
            guard connected, generation == attempt, selectedDevice == target else { throw Failure("Connection changed.") }
            try await refresh(speak: false)
            if snapshot?.running == false {
                await send("releaseLease", leaseID: lease)
                if voiceLeaseID == lease { voiceLeaseID = nil; heartbeat?.cancel(); heartbeat = nil }
                return snapshot?.messages.filter { !previous.contains($0.id) && ["assistant", "error", "system"].contains($0.kind) }.map(\.text).joined(separator: "\n") ?? "No result is available."
            }
            try await Task.sleep(for: .seconds(1))
        }
        await send("pause")
        throw Failure("The voice task reached its limit and was paused.")
    }

    private func refresh(speak: Bool) async throws {
        let target = selectedDevice
        let attempt = generation
        let data = try await request("companion/conversations/\(target)")
        try Task.checkCancellation()
        let value = try JSONDecoder().decode(Snapshot.self, from: data)
        guard generation == attempt, selectedDevice == target else { return }
        guard try acceptSnapshot(value) else { return }
        for message in value.messages where message.kind == "assistant" {
            if spoken.insert(message.id).inserted, speak, !seedHistory, nativeVoiceTask == nil { onReply(message.text) }
        }
        seedHistory = false
    }

    private func acceptSnapshot(_ value: Snapshot) throws -> Bool {
        guard let incoming = value.serverSessionID else { throw Failure("Update and reconnect to the Mac app before issuing commands.") }
        guard !retiredServerSessions.contains(incoming) else { return false }
        if let current = snapshot?.serverSessionID, current != incoming {
            guard retiredServerSessions.count < 128 else { throw Failure("The Mac changed sessions repeatedly. Reconnect to inspect its state.") }
            retiredServerSessions.insert(current)
            // Retire the old voice work before callbacks can attempt a pause against the new Mac.
            voiceLeaseID = nil; heartbeat?.cancel(); heartbeat = nil
            nativeVoiceTurn = UUID(); nativeVoiceTask?.cancel(); nativeVoiceTask = nil
            onConnectionLost()
            spoken.removeAll(); seedHistory = true
            clientID = UUID(); commandSequence = 0
            error = "The Mac restarted. Voice stopped and no command was repeated. Review the current state before continuing."
        } else if (value.controlGeneration ?? 0) < (snapshot?.controlGeneration ?? 0) { return false }
        snapshot = value
        return true
    }

    func useDirectConnection() { disconnect(); relayPairing = nil; address = "" }

    private func request(_ path: String, body: Data? = nil) async throws -> Data {
        if let relay {
            let reply = try await relay.request(RelayRequest(method: body == nil ? "GET" : "POST", path: path, body: body, authorization: "Bearer \(sessionToken)"))
            guard (200..<300).contains(reply.status) else { throw Failure("Mac returned HTTP \(reply.status). Pair again if your key was revoked.") }
            return reply.body
        }
        guard let baseURL else { throw Failure("Connect to your Mac first.") }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 20)
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure("Mac returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Check the address and companion key.")
        }
        return data
    }

    private struct Failure: LocalizedError { var text: String; init(_ text: String) { self.text = text }; var errorDescription: String? { text } }
    private func keyQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "agency.ziplyne.taplyne.companion", kSecAttrAccount as String: account]
    }
    private func readKey(_ account: String) -> String? {
        var query = keyQuery(account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func saveKey(_ value: String, account: String) throws {
        if let credentialWriter { try credentialWriter(value, account); return }
        let query = keyQuery(account)
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure("Could not save the connection securely.") }
        } else if status != errSecSuccess { throw Failure("Could not save the connection securely.") }
    }
}
