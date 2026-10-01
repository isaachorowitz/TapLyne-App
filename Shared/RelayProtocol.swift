import Foundation
import CryptoKit

/// Pairing secrets stay on the paired endpoints; relay operators see only opaque frames.
struct RelayConfiguration: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case host, device; var opposite: Role { self == .host ? .device : .host } }
    enum Scope: String, Codable, Sendable { case runner, conversation }
    var endpoint: URL
    var room: String
    var role: Role
    var token: String
    var encryptionKey: String
    var scope: Scope
    var peerTokenHash: String?
    var enrollmentToken: String?

    func validated() throws -> Self {
        guard let host = endpoint.host, !host.isEmpty, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil, ["", "/"].contains(endpoint.path),
              endpoint.scheme == "wss" || (endpoint.scheme == "ws" && ["localhost", "127.0.0.1", "::1"].contains(host)),
              Self.isHex(room), Self.isHex(token), Data(base64Encoded: encryptionKey)?.count == 32,
              role != .host || peerTokenHash.map(Self.isHex) == true,
              (enrollmentToken?.utf8.count ?? 0) <= 512 else { throw RelayFailure("Invalid relay pairing. Create a new pairing on your Mac.") }
        return self
    }

    static func isHex(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func randomHex() -> String { SymmetricKey(size: .bits256).withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() } }
    static func pair(endpoint: URL, scope: Scope, enrollment: String? = nil) throws -> (host: Self, device: Self) {
        let room = randomHex(), hostToken = randomHex(), deviceToken = randomHex()
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        let digest = SHA256.hash(data: Data(deviceToken.utf8)).map { String(format: "%02x", $0) }.joined()
        let host = Self(endpoint: endpoint, room: room, role: .host, token: hostToken, encryptionKey: key, scope: scope, peerTokenHash: digest, enrollmentToken: enrollment)
        let device = Self(endpoint: endpoint, room: room, role: .device, token: deviceToken, encryptionKey: key, scope: scope)
        return (try host.validated(), try device.validated())
    }
}

struct RelayRequest: Codable, Sendable {
    var id: UUID = UUID()
    var method: String
    var path: String
    var body: Data?
    var authorization: String?
    var issuedAt = Date()
    var expiresAt = Date().addingTimeInterval(20)
    var isFresh: Bool {
        issuedAt.timeIntervalSinceNow <= 5 && expiresAt > Date() && expiresAt.timeIntervalSince(issuedAt) > 0 && expiresAt.timeIntervalSince(issuedAt) <= 30
    }
}
struct RelayResponse: Codable, Sendable {
    var id: UUID
    var status: Int
    var body: Data
    static func failure(_ request: RelayRequest, status: Int = 502) -> Self {
        Self(id: request.id, status: status, body: Data("{\"error\":\"Remote service unavailable. Inspect before retrying.\"}".utf8))
    }
}
struct RelayFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct RelayCompanionPairing: Codable {
    var version = 1
    var configuration: RelayConfiguration
    var phoneID: String
    var companionKey: String
    func validated() throws -> Self {
        _ = try configuration.validated()
        guard version == 1, configuration.role == .device, configuration.scope == .conversation,
              phoneID.count <= 100, !phoneID.isEmpty, phoneID.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
              (20...200).contains(companionKey.count) else { throw RelayFailure("Invalid companion pairing.") }
        return self
    }
    func url() throws -> URL {
        let encoded = try JSONEncoder().encode(self).base64EncodedString()
        var parts = URLComponents(); parts.scheme = "taplyne"; parts.host = "relay"
        parts.queryItems = [URLQueryItem(name: "pairing", value: encoded)]
        guard let url = parts.url else { throw RelayFailure("Could not create pairing code.") }
        return url
    }
    static func parse(_ url: URL) throws -> Self {
        guard url.absoluteString.utf8.count <= 6000, url.scheme == "taplyne", url.host == "relay",
              let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              fields.count == 1, fields[0].name == "pairing", let raw = fields[0].value,
              let data = Data(base64Encoded: raw) else { throw RelayFailure("Invalid companion pairing code.") }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }
}
