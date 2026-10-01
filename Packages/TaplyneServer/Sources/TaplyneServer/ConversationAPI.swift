import Foundation

public struct ConversationMessage: Codable, Sendable {
    public var id: String
    public var kind: String
    public var text: String
    public init(id: String, kind: String, text: String) { self.id = id; self.kind = kind; self.text = text }
}

public struct ConversationSnapshot: Codable, Sendable {
    public var phoneID: String
    public var running: Bool
    public var paused: Bool
    public var messages: [ConversationMessage]
    public var controlGeneration: UInt64?
    public var serverSessionID: UUID?
    public init(phoneID: String, running: Bool, paused: Bool, messages: [ConversationMessage], controlGeneration: UInt64? = nil, serverSessionID: UUID? = nil) {
        self.phoneID = phoneID; self.running = running; self.paused = paused; self.messages = messages; self.controlGeneration = controlGeneration; self.serverSessionID = serverSessionID
    }
}

public struct ConversationCommand: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case send, stop, pause, resume, reset, heartbeat, releaseLease }
    public var id: UUID
    public var action: Action
    public var text: String?
    public var leaseID: UUID?
    public var clientID: UUID?
    public var sequence: UInt64?
    public var controlGeneration: UInt64?
    public var serverSessionID: UUID?
    public var issuedAt: Date?
    public init(id: UUID = UUID(), action: Action, text: String? = nil, leaseID: UUID? = nil, clientID: UUID? = nil, sequence: UInt64? = nil, controlGeneration: UInt64? = nil, issuedAt: Date? = nil, serverSessionID: UUID? = nil) {
        self.id = id; self.action = action; self.text = text; self.leaseID = leaseID
        self.clientID = clientID; self.sequence = sequence; self.controlGeneration = controlGeneration; self.issuedAt = issuedAt; self.serverSessionID = serverSessionID
    }
}

public protocol ConversationService: Sendable {
    func voiceCredential(phoneID: String) async throws -> Data
    func snapshot(phoneID: String) async throws -> ConversationSnapshot
    func command(phoneID: String, command: ConversationCommand) async throws -> ConversationSnapshot
}

public extension ConversationService {
    func voiceCredential(phoneID: String) async throws -> Data { throw PhoneServiceError.invalidArgument("Live voice is unavailable.") }
}

struct ConversationAPI: Sendable {
    let service: any ConversationService
    func handle(_ request: HTTPRequest, phoneID: String) async -> HTTPResponse {
        do {
            let snapshot: ConversationSnapshot
            switch request.method {
            case "GET": snapshot = try await service.snapshot(phoneID: phoneID)
            case "POST":
                guard request.body.count <= 100_000,
                      let command = try? JSONDecoder().decode(ConversationCommand.self, from: request.body),
                      command.clientID != nil, (command.sequence ?? 0) > 0, command.controlGeneration != nil, command.serverSessionID != nil,
                      command.issuedAt.map({ abs($0.timeIntervalSinceNow) <= 30 }) == true,
                      (command.text?.count ?? 0) <= 16000,
                      command.action != .send || !(command.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return APIError(status: 400, code: "INVALID_COMMAND", message: "Provide current serverSessionID and controlGeneration, clientID, increasing sequence, issuedAt, UUID id and a valid action with text of at most 16000 characters.").response
                }
                snapshot = try await service.command(phoneID: phoneID, command: command)
            default: return APIError(status: 405, code: "METHOD_NOT_ALLOWED", message: "Use GET or POST.").response
            }
            return .data(try JSONEncoder().encode(snapshot), contentType: "application/json")
        } catch {
            return APIError(status: 409, code: "CONVERSATION_UNAVAILABLE", message: "The device or conversation is unavailable. Inspect its state before retrying.").response
        }
    }
}
