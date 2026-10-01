import Foundation
import CryptoKit

/// Direction-bound AEAD plus fresh two-way epochs prevent replay across reconnects.
struct RelayCipher {
    struct Frame: Codable {
        enum Kind: String, Codable { case hello, acknowledgment, request, response }
        var kind: Kind
        var sender: UUID
        var recipient: UUID?
        var sequence: UInt64
        var request: RelayRequest?
        var response: RelayResponse?
    }
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let sendAAD: Data
    private let receiveAAD: Data
    private(set) var localEpoch = UUID()
    private(set) var peerEpoch: UUID?
    private(set) var ready = false
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    static let maxFrame = 8 * 1024 * 1024

    init(configuration: RelayConfiguration) throws {
        let config = try configuration.validated()
        let root = SymmetricKey(data: Data(base64Encoded: config.encryptionKey)!)
        func context(_ role: RelayConfiguration.Role) -> Data { Data("TaplyneRelay/1/\(config.room)/\(config.scope.rawValue)/\(role.rawValue)".utf8) }
        sendAAD = context(config.role); receiveAAD = context(config.role.opposite)
        sendKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: root, salt: Data(config.room.utf8), info: sendAAD, outputByteCount: 32)
        receiveKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: root, salt: Data(config.room.utf8), info: receiveAAD, outputByteCount: 32)
    }
    mutating func reset() { localEpoch = UUID(); peerEpoch = nil; ready = false; sent = 0; received = 0 }
    mutating func seal(_ kind: Frame.Kind, request: RelayRequest? = nil, response: RelayResponse? = nil) throws -> Data {
        guard sent < UInt64.max, kind == .hello || peerEpoch != nil,
              kind == .hello || kind == .acknowledgment || ready else { throw RelayFailure("The encrypted peer is not ready.") }
        sent += 1
        let frame = Frame(kind: kind, sender: localEpoch, recipient: kind == .hello ? nil : peerEpoch, sequence: sent, request: request, response: response)
        let plaintext = try JSONEncoder().encode(frame)
        guard plaintext.count < Self.maxFrame - 128 else { throw RelayFailure("Remote message exceeds the frame limit.") }
        return try AES.GCM.seal(plaintext, using: sendKey, authenticating: sendAAD).combined!
    }
    mutating func open(_ data: Data) throws -> Frame {
        guard (28...Self.maxFrame).contains(data.count) else { throw RelayFailure("Invalid encrypted frame size.") }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: receiveKey, authenticating: receiveAAD)
        let frame = try JSONDecoder().decode(Frame.self, from: plaintext)
        guard received < UInt64.max, frame.sequence == received + 1 else { throw RelayFailure("Invalid relay sequence.") }
        if frame.kind == .hello {
            guard frame.recipient == nil, frame.request == nil, frame.response == nil,
                  peerEpoch == nil else { throw RelayFailure("Unexpected peer handshake.") }
            peerEpoch = frame.sender
        } else {
            guard frame.recipient == localEpoch, frame.sender == peerEpoch,
                  frame.sequence > received else { throw RelayFailure("Stale or replayed relay message.") }
        }
        switch frame.kind {
        case .hello: break
        case .acknowledgment:
            guard frame.request == nil, frame.response == nil else { throw RelayFailure("Invalid handshake.") }
            ready = true
        case .request:
            guard ready, frame.response == nil, let request = frame.request,
                  ["GET", "POST", "DELETE"].contains(request.method), request.path.utf8.count <= 512,
                  !request.path.contains(".."), !request.path.contains("%"), !request.path.contains("?"), !request.path.contains("#"),
                  !request.path.hasPrefix("/"), (request.body?.count ?? 0) <= 100_000,
                  (request.authorization?.count ?? 0) <= 512, request.isFresh else { throw RelayFailure("Invalid relay request.") }
        case .response:
            guard ready, frame.request == nil, let response = frame.response, (100...599).contains(response.status),
                  response.body.count <= 5 * 1024 * 1024 else { throw RelayFailure("Invalid relay response.") }
        }
        received = frame.sequence
        return frame
    }
}
