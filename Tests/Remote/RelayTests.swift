import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct RelayTests {
    static func expect(_ test: @autoclosure () -> Bool, _ message: String) throws {
        if !test() { throw RelayFailure("FAILED: " + message) }
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw RelayFailure("FAILED: accepted " + message)
    }
    @MainActor static func main() async throws {
        let url = URL(string: ProcessInfo.processInfo.environment["TAPLYNE_RELAY_TEST_URL"] ?? "ws://127.0.0.1:8787")!
        let pair = try RelayConfiguration.pair(endpoint: url, scope: .runner)
        var host = try RelayCipher(configuration: pair.host), device = try RelayCipher(configuration: pair.device)
        let hello = try host.seal(.hello), peerHello = try device.seal(.hello)
        _ = try host.open(peerHello); _ = try device.open(hello)
        let acknowledgment = try host.seal(.acknowledgment), peerAcknowledgment = try device.seal(.acknowledgment)
        _ = try host.open(peerAcknowledgment); _ = try device.open(acknowledgment)
        try expect(host.ready && device.ready, "authenticated handshake")
        let request = RelayRequest(method: "POST", path: "session", body: Data("{}".utf8))
        let encrypted = try host.seal(.request, request: request)
        let opened = try device.open(encrypted)
        try expect(opened.request?.id == request.id, "request roundtrip")
        try rejects("replayed ciphertext") { _ = try device.open(encrypted) }
        var tampered = encrypted; tampered[tampered.count - 1] ^= 1
        try rejects("tampered ciphertext") { _ = try device.open(tampered) }
        try rejects("reflected role") { _ = try host.open(encrypted) }
        var wrongRoom = pair.device; wrongRoom.room = RelayConfiguration.randomHex()
        var wrong = try RelayCipher(configuration: wrongRoom)
        try rejects("cross-room frame") { _ = try wrong.open(hello) }
        var wrongScope = pair.device; wrongScope.scope = .conversation
        var scoped = try RelayCipher(configuration: wrongScope)
        try rejects("cross-service frame") { _ = try scoped.open(hello) }
        var gapDevice = device
        let dropped = try host.seal(.request, request: request)
        let afterGap = try host.seal(.request, request: request)
        try rejects("missing sequence") { _ = try gapDevice.open(afterGap) }
        _ = try device.open(dropped); _ = try device.open(afterGap)
        var expired = request; expired.issuedAt = Date().addingTimeInterval(-20); expired.expiresAt = Date().addingTimeInterval(-1)
        let expiredFrame = try host.seal(.request, request: expired)
        try rejects("expired encrypted command") { _ = try device.open(expiredFrame) }
        try expect(!RelayWDAProxy.allows(expired), "runner rejects expired command before HTTP")
        device.reset()
        try rejects("old connection frame") { _ = try device.open(encrypted) }
        try expect(!RelayWDAProxy.allows(RelayRequest(method: "POST", path: "wda/shutdown")), "shutdown excluded")
        try expect(!RelayWDAProxy.allows(RelayRequest(method: "GET", path: "../screenshot")), "path traversal excluded")
        try expect(!RelayWDAProxy.allows(RelayRequest(method: "GET", path: "screenshot", authorization: "secret")), "credentials excluded")
        let conversationPair = try RelayConfiguration.pair(endpoint: url, scope: .conversation)
        let pairing = RelayCompanionPairing(configuration: conversationPair.device, phoneID: "phone-A", companionKey: String(repeating: "a", count: 32))
        let roundTrip = try RelayCompanionPairing.parse(pairing.url())
        try expect(roundTrip.phoneID == "phone-A" && roundTrip.configuration == conversationPair.device, "QR roundtrip")
        var hostPairing = pairing; hostPairing.configuration = conversationPair.host
        try rejects("host role in companion") { _ = try hostPairing.validated() }
        var runnerPairing = pairing; runnerPairing.configuration = pair.device
        try rejects("runner role in companion") { _ = try runnerPairing.validated() }
        for path in ["phones", "mcp", "companion/conversations/phone-B", "companion/voice/phone-B", "companion/conversations/../phone-A"] {
            try expect(!RelayCompanionPolicy.allows(RelayRequest(method: "POST", path: path, authorization: "Bearer test"), phoneID: "phone-A"), "companion isolation " + path)
        }
        try expect(RelayCompanionPolicy.allows(RelayRequest(method: "POST", path: "companion/conversations/phone-A", authorization: "Bearer test"), phoneID: "phone-A"), "assigned conversation")
        let pixels = CGContext(data: nil, width: 2732, height: 2048, bitsPerComponent: 8, bytesPerRow: 2732 * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        pixels.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)); pixels.fill(CGRect(x: 0, y: 0, width: 2732, height: 2048))
        let png = NSMutableData(); let encoder = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, pixels.makeImage()!, nil); try expect(CGImageDestinationFinalize(encoder), "PNG fixture")
        let screenBody = try JSONSerialization.data(withJSONObject: ["value": (png as Data).base64EncodedString()])
        let normalized = try RelayWDAProxy.normalizedScreenshot(RelayResponse(id: UUID(), status: 200, body: screenBody))
        let normalizedJSON = try JSONSerialization.jsonObject(with: normalized.body) as! [String: String]
        let jpeg = CGImageSourceCreateWithData(Data(base64Encoded: normalizedJSON["value"]!)! as CFData, nil)!
        let dimensions = CGImageSourceCopyPropertiesAtIndex(jpeg, 0, nil)! as NSDictionary
        let width = dimensions[kCGImagePropertyPixelWidth] as! Int, height = dimensions[kCGImagePropertyPixelHeight] as! Int
        try expect(width == 2048 && abs(Double(width) / Double(height) - 2732.0 / 2048.0) < 0.01, "screenshot aspect ratio and bound")
        try expect(normalized.body.count < 5 * 1024 * 1024, "screenshot transport budget")
        print("PASS: relay handshake, direction, scope, tamper, replay, reconnect epochs and route boundaries")
        guard ProcessInfo.processInfo.environment["TAPLYNE_RELAY_TEST_URL"] != nil else { return }
        let mac = try RelayPeer(configuration: pair.host), phone = try RelayPeer(configuration: pair.device)
        phone.requestHandler = { RelayResponse(id: $0.id, status: 200, body: Data("שלום 👋".utf8)) }
        mac.requestHandler = { RelayResponse(id: $0.id, status: 201, body: Data("conversation".utf8)) }
        defer { mac.stop(); phone.stop() }
        mac.start()
        // Host establishes the room; device retry is bounded if it arrives first.
        phone.start()
        for _ in 0..<150 {
            if mac.state == .ready && phone.state == .ready { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try expect(mac.state == .ready && phone.state == .ready, "network handshake")
        let reply = try await mac.request(RelayRequest(method: "GET", path: "screenshot"))
        try expect(String(decoding: reply.body, as: UTF8.self) == "שלום 👋", "real websocket encrypted reply")
        let reverse = try await phone.request(RelayRequest(method: "GET", path: "companion/phones"))
        try expect(reverse.status == 201, "bidirectional request")
        phone.requestHandler = { request in
            try? await Task.sleep(for: .seconds(3))
            return RelayResponse(id: request.id, status: 200, body: Data())
        }
        let pending = Task { try await mac.request(RelayRequest(method: "GET", path: "status")) }
        try await Task.sleep(for: .milliseconds(100)); phone.stop()
        do { _ = try await pending.value; throw RelayFailure("FAILED: disconnected command succeeded") }
        catch let error as RelayFailure where error.message.hasPrefix("FAILED") { throw error }
        catch { }
        phone.start()
        for _ in 0..<150 {
            if mac.state == .ready && phone.state == .ready { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try expect(mac.state == .ready && phone.state == .ready, "fresh reconnect handshake")
        let replacement = try RelayPeer(configuration: pair.host)
        replacement.start()
        defer { replacement.stop() }
        for _ in 0..<150 {
            if replacement.state == .ready && phone.state == .ready && mac.state == .failed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try expect(replacement.state == .ready && phone.state == .ready, "authenticated role replacement resets cipher")
        try expect(mac.state == .failed, "replaced endpoint does not steal the role back")
        let companionHost = try RelayPeer(configuration: conversationPair.host)
        var serverSessionID = UUID(), controlGeneration: UInt64 = 0
        var voiceLease: String?, releasedVoiceLease: String?
        var voiceSubmitted = false
        var receivedTexts: [String] = []
        companionHost.requestHandler = { request in
            if request.path == "companion/phones" {
                return RelayResponse(id: request.id, status: 200, body: Data("[{\"id\":\"phone-A\",\"name\":\"Test phone\",\"connection_status\":\"online\"}]".utf8))
            }
            if let body = request.body, let command = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if command["action"] as? String == "send" {
                    receivedTexts.append(command["text"] as? String ?? "")
                    if command["text"] as? String == "Pending manual request" { try? await Task.sleep(for: .milliseconds(200)) }
                    voiceLease = command["leaseID"] as? String; voiceSubmitted = voiceLease != nil
                }
                if command["action"] as? String == "releaseLease" { releasedVoiceLease = command["leaseID"] as? String }
            }
            let messages = voiceSubmitted ? [["id": "native-reply", "kind": "assistant", "text": "Native voice done"]] : []
            let body = try! JSONSerialization.data(withJSONObject: ["phoneID": "phone-A", "serverSessionID": serverSessionID.uuidString, "controlGeneration": controlGeneration, "running": false, "paused": false, "messages": messages])
            return RelayResponse(id: request.id, status: 200, body: body)
        }
        companionHost.start()
        let companion = CompanionConnection()
        var saved = false
        companion.credentialWriter = { _, account in saved = account == "relay-pairing" }
        companion.acceptPairing(try pairing.url())
        await companion.connect()
        try expect(companion.connected && companion.selectedDevice == "phone-A" && saved, "production companion connects and persists relay")
        await companion.send("pause")
        try expect(companion.error == nil && companion.snapshot?.phoneID == "phone-A", "production companion relay command")
        var spoken: [String] = []; companion.onReply = { spoken.append($0) }
        let pendingSend = Task { await companion.send("send", text: "Pending manual request") }
        try await Task.sleep(for: .milliseconds(50))
        companion.sendVoiceUtterance("Native voice fixture")
        for _ in 0..<100 {
            if !spoken.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await pendingSend.value
        try expect(receivedTexts == ["Pending manual request", "Native voice fixture"], "voice correction waits for the in-flight send")
        try expect(voiceLease != nil && voiceLease == releasedVoiceLease, "native dictation uses and releases a scoped voice lease")
        try expect(spoken == ["Native voice done"], "native dictation speaks the final result once")
        controlGeneration = 9
        for _ in 0..<100 {
            if companion.snapshot?.controlGeneration == 9 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(companion.snapshot?.controlGeneration == 9, "poll observes old Mac generation")
        var restartNotifications = 0; companion.onConnectionLost = { restartNotifications += 1 }
        let commandCount = receivedTexts.count
        serverSessionID = UUID(); controlGeneration = 0
        for _ in 0..<100 {
            if companion.snapshot?.serverSessionID == serverSessionID { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(companion.connected && companion.snapshot?.controlGeneration == 0 && companion.snapshot?.serverSessionID == serverSessionID, "Mac restart accepts new session generation zero")
        try expect(restartNotifications == 1 && receivedTexts.count == commandCount, "Mac restart ends voice without command replay")
        companion.disconnect(); companionHost.stop()
        print("PASS: native Swift peers through real relay, production companion pairing, leased native voice reply, disconnect failure and reconnect")
    }
}
