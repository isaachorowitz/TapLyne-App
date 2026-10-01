import Foundation
import CryptoKit
import TaplyneServer

@MainActor
final class AppConversationService: ConversationService {
    private let serverSessionID = UUID()
    private struct Order { let sequence: UInt64; let seen: Date }
    private var commandOrder: [String: [UUID: Order]] = [:]
    private var leases = ConversationLeaseBook()
    private var leaseWatchdogs: [String: Task<Void, Never>] = [:]
    private struct Credential { let data: Data; let expires: Date }
    private var voiceCredentials: [String: Credential] = [:]
    private var voiceRequests: [String: Task<Credential, Error>] = [:]
    private weak var model: AppModel?
    init(model: AppModel) { self.model = model }

    func voiceCredential(phoneID: String) async throws -> Data {
        guard let model, model.registry.phone(phoneID) != nil, let key = model.openAIKey(voice: true), !key.isEmpty else {
            throw PhoneServiceError.invalidArgument("Voice unavailable. Add an OpenAI key in Settings.")
        }
        let cacheID = phoneID + ":" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = voiceCredentials[cacheID], cached.expires.timeIntervalSinceNow > 15 { return cached.data }
        if let pending = voiceRequests[cacheID] { return try await pending.value.data }
        let task = Task<Credential, Error> {
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/client_secrets")!, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["expires_after": ["anchor": "created_at", "seconds": 60], "session": RealtimeVoice.configuration])
            let (data, response) = try await PrivateHTTPClient.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["value"] as? String, let expiry = object["expires_at"] as? Double,
                  expiry > Date().timeIntervalSince1970 else { throw PhoneServiceError.invalidArgument("Voice provider unavailable.") }
            return Credential(data: try JSONSerialization.data(withJSONObject: ["value": value]), expires: Date(timeIntervalSince1970: expiry))
        }
        voiceRequests[cacheID] = task
        defer { voiceRequests[cacheID] = nil }
        let credential = try await task.value
        voiceCredentials = voiceCredentials.filter { !$0.key.hasPrefix(phoneID + ":") }
        voiceCredentials[cacheID] = credential
        return credential.data
    }

    func snapshot(phoneID: String) async throws -> ConversationSnapshot {
        guard let model, let phone = model.registry.phone(phoneID) else { throw PhoneServiceError.phoneNotFound(phoneID) }
        let chat = model.conversation(for: phoneID)
        return ConversationSnapshot(phoneID: phoneID, running: chat.running, paused: chat.paused || phone.controlState.mode != .automatic,
            messages: chat.entries.filter { $0.kind != .image }.suffix(250).map {
                ConversationMessage(id: $0.id.uuidString, kind: $0.kind.rawValue, text: $0.text)
            }, controlGeneration: phone.controlState.generation, serverSessionID: serverSessionID)
    }

    func command(phoneID: String, command: ConversationCommand) async throws -> ConversationSnapshot {
        guard let model, let phone = model.registry.phone(phoneID) else { throw PhoneServiceError.phoneNotFound(phoneID) }
        guard command.serverSessionID == serverSessionID else { throw PhoneServiceError.invalidArgument("The Mac restarted. Refresh its state before issuing a new command.") }
        let chat = model.conversation(for: phoneID)
        if let clientID = command.clientID, let sequence = command.sequence {
            var order = (commandOrder[phoneID] ?? [:]).filter { $0.value.seen.timeIntervalSinceNow > -300 }
            if let previous = order[clientID], sequence <= previous.sequence { return try await snapshot(phoneID: phoneID) }
            guard order[clientID] != nil || order.count < 128 else { throw PhoneServiceError.invalidArgument("Too many companion sessions. Reconnect later.") }
            order[clientID] = Order(sequence: sequence, seen: Date()); commandOrder[phoneID] = order
        }
        if [.send, .resume, .reset].contains(command.action), let expected = command.controlGeneration,
           expected != phone.controlState.generation {
            throw PhoneServiceError.invalidArgument("Control changed before the command arrived. Inspect and issue a new command.")
        }
        if command.action == .releaseLease {
            guard let id = command.leaseID, leases.currentID(phoneID: phoneID) == id else { return try await snapshot(phoneID: phoneID) }
            leases.revoke(id, phoneID: phoneID); leaseWatchdogs.removeValue(forKey: phoneID)?.cancel()
            return try await snapshot(phoneID: phoneID)
        }
        // Emergency controls must work even when local history cannot be saved.
        if command.action == .pause || command.action == .stop {
            let active = leases.currentID(phoneID: phoneID)
            leases.revoke(command.leaseID, phoneID: phoneID)
            if let requested = command.leaseID, let active, requested != active { return try await snapshot(phoneID: phoneID) }
            leaseWatchdogs.removeValue(forKey: phoneID)?.cancel()
            if let requested = command.leaseID, chat.voiceLeaseID != requested { return try await snapshot(phoneID: phoneID) }
            phone.control(command.action == .stop ? .stop : .pause)
            if command.action == .stop { chat.stop() }
            return try await snapshot(phoneID: phoneID)
        }
        if command.action == .heartbeat {
            guard let id = command.leaseID, leases.renew(id, phoneID: phoneID) else { throw PhoneServiceError.invalidArgument("Voice lease expired.") }
            return try await snapshot(phoneID: phoneID)
        }
        if command.action == .send, let id = command.leaseID {
            guard leases.grant(id, phoneID: phoneID) else { throw PhoneServiceError.invalidArgument("Voice request was interrupted.") }
            leaseWatchdogs.removeValue(forKey: phoneID)?.cancel()
            leaseWatchdogs[phoneID] = Task { [weak self, weak phone] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    if chat.voiceLeaseID != id || (!chat.running && chat.pendingPrompt == nil) {
                        self.leases.revoke(id, phoneID: phoneID); self.leaseWatchdogs.removeValue(forKey: phoneID)
                        return
                    }
                    if self.leases.expired(id, phoneID: phoneID) {
                        self.leases.revoke(id, phoneID: phoneID); phone?.control(.pause)
                        self.leaseWatchdogs.removeValue(forKey: phoneID)
                        return
                    }
                }
            }
        }
        if command.action == .reset, chat.running { throw PhoneServiceError.invalidArgument("Stop the run before clearing its conversation.") }
        guard try chat.accept(command) else { return try await snapshot(phoneID: phoneID) }
        switch command.action {
        case .send: chat.steer(command.text ?? "", leaseID: command.leaseID)
        case .stop: chat.stop()
        case .pause: phone.control(.pause)
        case .resume: if chat.paused { chat.resume() } else { phone.control(.resume) }
        case .reset: chat.reset()
        case .heartbeat, .releaseLease: break
        }
        return try await snapshot(phoneID: phoneID)
    }
}
