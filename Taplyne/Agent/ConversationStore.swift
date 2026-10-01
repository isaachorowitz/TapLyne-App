import Foundation
import CryptoKit

/// Device-bound authenticated encryption; the per-install key stays in Keychain.
struct ConversationStore {
    struct Message: Codable { var id: UUID; var kind: String; var text: String }
    struct Workflow: Codable, Identifiable { var id = UUID(); var name: String; var prompt: String }
    struct WorkflowRun: Codable, Identifiable {
        var id = UUID(); var workflowID: UUID; var name: String; var startedAt = Date()
        var status: String; var result: String
    }
    struct AcceptedCommand: Codable { var id: UUID; var fingerprint: Data }
    struct Snapshot: Codable {
        var messages: [Message] = []
        var sessionID: UUID?
        var wasRunning = false
        var workflows: [Workflow] = []
        var workflowRuns: [WorkflowRun]? = nil
        var commands: [AcceptedCommand]? = nil
    }
    var directory: URL
    private var keyProvider: () throws -> SymmetricKey
    init(directory: URL, key: SymmetricKey) { self.directory = directory; keyProvider = { key } }
    private init(directory: URL, keyProvider: @escaping () throws -> SymmetricKey) {
        self.directory = directory; self.keyProvider = keyProvider
    }
    static var standard: Self {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TAPLYNE_PREVIEW"] != nil {
            return Self(directory: FileManager.default.temporaryDirectory.appendingPathComponent("taplyne-preview-conversations"),
                        key: SymmetricKey(data: Data(repeating: 1, count: 32)))
        }
        #endif
        return Self(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Taplyne/conversations", isDirectory: true)) {
            if let saved = Keychain.read("conversation-encryption-key"), let bytes = Data(base64Encoded: saved), bytes.count == 32 {
                return SymmetricKey(data: bytes)
            }
            let key = SymmetricKey(size: .bits256)
            let encoded = key.withUnsafeBytes { Data($0).base64EncodedString() }
            guard Keychain.write(encoded, account: "conversation-encryption-key") else { throw StoreError.keyUnavailable }
            return key
        }
    }
    func url(_ deviceID: String) -> URL {
        let hash = SHA256.hash(data: Data(deviceID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".sealed")
    }
    func load(_ deviceID: String) throws -> Snapshot {
        let destination = url(deviceID)
        guard FileManager.default.fileExists(atPath: destination.path) else { return Snapshot() }
        let data = try Data(contentsOf: destination)
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: keyProvider(), authenticating: Data(deviceID.utf8))
        return try JSONDecoder().decode(Snapshot.self, from: plaintext)
    }
    func save(_ snapshot: Snapshot, deviceID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let plaintext = try JSONEncoder().encode(snapshot)
        guard let data = try AES.GCM.seal(plaintext, using: keyProvider(), authenticating: Data(deviceID.utf8)).combined else { throw StoreError.encryptionFailed }
        let destination = url(deviceID)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    enum StoreError: Error { case keyUnavailable, encryptionFailed }
}

extension ConversationStore.Workflow {
    var inputs: [String] {
        guard let expression = try? NSRegularExpression(pattern: #"\{\{([A-Za-z][A-Za-z0-9_]{0,39})\}\}"#) else { return [] }
        let range = NSRange(prompt.startIndex..., in: prompt)
        return Array(Set(expression.matches(in: prompt, range: range).compactMap {
            Range($0.range(at: 1), in: prompt).map { String(prompt[$0]) }
        })).sorted()
    }
    func rendered(_ values: [String: String]) throws -> String {
        guard inputs.allSatisfy({ !(values[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw WorkflowFailure() }
        let expression = try NSRegularExpression(pattern: #"\{\{([A-Za-z][A-Za-z0-9_]{0,39})\}\}"#)
        var text = prompt
        for match in expression.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)).reversed() {
            guard let keyRange = Range(match.range(at: 1), in: prompt), let range = Range(match.range, in: text) else { continue }
            text.replaceSubrange(range, with: values[String(prompt[keyRange])] ?? "")
        }
        guard text.count <= 16000 else { throw WorkflowFailure() }
        return text
    }
    struct WorkflowFailure: LocalizedError { var errorDescription: String? { "Fill every workflow input and keep the result under 16000 characters." } }
}
