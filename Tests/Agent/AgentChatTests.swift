import AppKit
import Foundation
import CryptoKit
import TaplyneServer

@main struct AgentChatTests {
    @MainActor static func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(condition(), "Agent state did not settle")
    }

    @MainActor static func verifyIdentityTokens() throws {
        let key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!
        let pub = SecKeyCopyPublicKey(key)!
        let bytes = [UInt8](SecKeyCopyExternalRepresentation(pub, nil)! as Data)
        var offset = 0
        func read(_ tag: UInt8) -> Data {
            precondition(bytes[offset] == tag); offset += 1
            var length = Int(bytes[offset]); offset += 1
            if length > 127 {
                let width = length & 127; length = 0
                for _ in 0..<width { length = (length << 8) | Int(bytes[offset]); offset += 1 }
            }
            if tag == 0x30 { return Data() }
            let data = Data(bytes[offset..<offset+length]); offset += length
            return data.first == 0 ? Data(data.dropFirst()) : data
        }
        _ = read(0x30); let modulus = read(0x02), exponent = read(0x02)
        let keys: [String: Any] = ["keys": [["kty": "RSA", "kid": "test", "n": ChatGPTAuth.base64(modulus), "e": ChatGPTAuth.base64(exponent)]]]
        var claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": "taplyne-test", "sub": "account-test", "nonce": "nonce-test", "exp": Date().timeIntervalSince1970 + 60, "iat": Date().timeIntervalSince1970]
        func token(_ claims: [String: Any]) throws -> String {
            let header = ChatGPTAuth.base64(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test"]))
            let payload = ChatGPTAuth.base64(try JSONSerialization.data(withJSONObject: claims))
            let signed = header + "." + payload
            let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(signed.utf8) as CFData, nil)! as Data
            return signed + "." + ChatGPTAuth.base64(signature)
        }
        let valid = try token(claims)
        let result = try ChatGPTAuth.validate(valid, keys: keys, client: "taplyne-test", nonce: "nonce-test")
        precondition(result["sub"] as? String == "account-test")
        for (client, nonce) in [("wrong-client", "nonce-test"), ("taplyne-test", "wrong-nonce")] {
            do { _ = try ChatGPTAuth.validate(valid, keys: keys, client: client, nonce: nonce); preconditionFailure("Invalid audience/nonce accepted") } catch { }
        }
        claims["exp"] = Date().timeIntervalSince1970 - 1
        do { _ = try ChatGPTAuth.validate(token(claims), keys: keys, client: "taplyne-test", nonce: "nonce-test"); preconditionFailure("Expired token accepted") } catch { }
        let pieces = valid.split(separator: ".")
        let tampered = pieces[0] + "." + ChatGPTAuth.base64(Data("{}".utf8)) + "." + pieces[2]
        do { _ = try ChatGPTAuth.validate(tampered, keys: keys, client: "taplyne-test", nonce: "nonce-test"); preconditionFailure("Forged token accepted") } catch { }
    }

    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/agent-tests/fixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await AuthAndDirectAgentTests.run()
        let child = directory.appendingPathComponent("fake-claude.py")
        try """
        #!/usr/bin/python3
        import json,signal,sys,time
        signal.signal(signal.SIGTERM,lambda *_:sys.exit(143))
        prompt=sys.argv[sys.argv.index('-p')+1]
        assert '--no-session-persistence' in sys.argv
        if 'Current request:' in prompt:
            assert 'current screen' in prompt and 'coordinates are invalid' in prompt
            print(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':'Resumed from a fresh screen.'}]}}),flush=True)
            sys.exit(0)
        print(json.dumps({'type':'user','message':{'content':[{'type':'tool_result','is_error':True,'content':'POINTER_UNCERTAIN: No click was sent.'}]}}),flush=True)
        while True:time.sleep(.05)
        """.write(to: child, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
        func chat() -> AgentChat {
            let chat = AgentChat()
            chat.executableURL = { child }
            chat.workDirectoryOverride = directory
            chat.mcpURL = { URL(string: "http://127.0.0.1:1/mcp") }
            chat.apiKey = { "test-only" }
            return chat
        }
        precondition(AgentChat.toolResultText(["content": "Actual error"]) == "Actual error")
        precondition(AgentChat.toolResultText(["content": [["type": "text", "text": "Array error"]]]) == "Array error")
        let first = chat()
        first.send("Observe only")
        try await waitUntil { first.entries.contains { $0.text.contains("POINTER_UNCERTAIN") } }
        first.pauseForControlChange()
        first.pauseForControlChange()
        first.pauseForControlChange()
        try await waitUntil { !first.running }
        precondition(first.paused)
        precondition(first.entries.filter { $0.kind == .status && $0.text.hasPrefix("Paused") }.count == 1)
        precondition(!first.entries.contains { $0.text.contains("143") || $0.text == "The action failed." })
        first.resume()
        try await waitUntil { !first.running && first.entries.contains { $0.text == "Resumed from a fresh screen." } }
        precondition(!first.paused)
        let immediate = chat()
        immediate.send("Observe only")
        try await waitUntil { immediate.entries.contains { $0.text.contains("POINTER_UNCERTAIN") } }
        immediate.pauseForControlChange()
        immediate.resume()
        try await waitUntil { !immediate.running && immediate.entries.contains { $0.text == "Resumed from a fresh screen." } }
        precondition(!immediate.entries.contains { $0.text.contains("143") })
        let stopped = chat()
        stopped.send("Observe only")
        try await waitUntil { stopped.entries.contains { $0.text.contains("POINTER_UNCERTAIN") } }
        stopped.stop()
        try await waitUntil { !stopped.running }
        precondition(!stopped.entries.contains { $0.text.contains("143") })
        precondition(InputFailure(PhoneServiceError.failed("Useful error"), delivery: .notDelivered).localizedDescription == "Useful error")
        let stored = chat()
        stored.store = ConversationStore(directory: directory.appendingPathComponent("history"), key: SymmetricKey(data: Data(repeating: 7, count: 32)))
        stored.selectDevice("../../phone-a")
        stored.saveWorkflow(name: "Weather", prompt: "Check the weather")
        stored.send("Observe only")
        try await waitUntil { stored.entries.contains { $0.text.contains("POINTER_UNCERTAIN") } }
        let recovered = chat()
        recovered.store = stored.store
        recovered.selectDevice("../../phone-a")
        precondition(recovered.entries.contains { $0.text.contains("previous run was interrupted") })
        precondition(recovered.workflows.count == 1)
        recovered.selectDevice("phone-b")
        precondition(recovered.entries.isEmpty && recovered.workflows.isEmpty)
        var cancelled = 0
        var resumed = 0
        stored.cancelInput = { _, _ in cancelled += 1 }
        stored.onResumeReady = { _ in resumed += 1 }
        stored.steer("Look at the current screen; coordinates are invalid")
        try await waitUntil { !stored.running && stored.entries.contains { $0.text == "Resumed from a fresh screen." } }
        precondition(cancelled == 1 && resumed == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: stored.store.url("../../phone-a").path)[.posixPermissions] as? Int
        precondition(permissions == 0o600)
        precondition(stored.store.url("../../phone-a").deletingLastPathComponent().standardizedFileURL.path == stored.store.directory.standardizedFileURL.path)
        let command = ConversationCommand(action: .send, text: "שלום 👋")
        let accepted = try stored.accept(command); precondition(accepted)
        let restored = chat(); restored.store = stored.store; restored.selectDevice("../../phone-a")
        let duplicate = try restored.accept(command); precondition(!duplicate)
        let encrypted = try Data(contentsOf: stored.store.url("../../phone-a"))
        precondition(!String(decoding: encrypted, as: UTF8.self).contains("Weather"))
        try Data("corrupt".utf8).write(to: stored.store.url("../../phone-a"))
        let corrupt = chat(); corrupt.store = stored.store; corrupt.selectDevice("../../phone-a")
        precondition(corrupt.entries.contains { $0.text.contains("could not be decrypted") })
        let preserved = try Data(contentsOf: stored.store.url("../../phone-a")); precondition(preserved == Data("corrupt".utf8))
        let workflow = ConversationStore.Workflow(name: "Message", prompt: "Ask {{recipient}} about {{topic}}. {{recipient}}")
        precondition(workflow.inputs == ["recipient", "topic"])
        let filled = try workflow.rendered(["recipient": "שלום 👋", "topic": "{{recipient}}"])
        precondition(filled == "Ask שלום 👋 about {{recipient}}. שלום 👋")
        do { _ = try workflow.rendered([:]); preconditionFailure("Missing input accepted") } catch { }
        var stream = ResponseStreamParser()
        let partial = try stream.consume(Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".utf8))
        guard partial.count == 1, case let .delta(delta) = partial[0] else { preconditionFailure("Streaming delta rejected") }
        precondition(delta == "partial")
        let terminal = try stream.consume(Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n".utf8))
        guard terminal.count == 1, case let .completed(completed) = terminal[0] else { preconditionFailure("Completed stream rejected") }
        precondition(completed["status"] as? String == "completed")
        do {
            _ = try stream.consume(Data("data: {\"type\":\"response.incomplete\"}\n\n".utf8))
            preconditionFailure("Incomplete stream accepted")
        } catch { }
        var fence = RealtimeTurnFence()
        fence.created("old")
        precondition(fence.allows("old"))
        let oldRevision = fence.revision
        fence.interrupt()
        precondition(!fence.allows("old") && fence.revision != oldRevision)
        fence.created("late-created")
        precondition(!fence.allows("late-created"))
        fence.speechEnded(); fence.created("new")
        precondition(fence.allows("new") && !fence.allows("old") && !fence.allows("late-created") && !fence.allows(nil))
        let testModel = AppModel()
        let service = AppConversationService(model: testModel)
        func invoke(_ input: ConversationCommand) async throws -> ConversationSnapshot {
            var command = input
            command.serverSessionID = try await service.snapshot(phoneID: "phone-a").serverSessionID
            return try await service.command(phoneID: "phone-a", command: command)
        }
        let originalServerSession = try await service.snapshot(phoneID: "phone-a").serverSessionID
        let restartedModel = AppModel()
        // Retain the model, because the production service intentionally holds it weakly.
        let newService = AppConversationService(model: restartedModel)
        do {
            _ = try await newService.command(phoneID: "phone-a", command: ConversationCommand(action: .send, text: "Old generation zero request", clientID: UUID(), sequence: 1, controlGeneration: 0, serverSessionID: originalServerSession))
            preconditionFailure("Previous Mac session accepted after restart")
        } catch PhoneServiceError.invalidArgument(let message) {
            precondition(message.contains("Mac restarted"))
        } catch { preconditionFailure("Unexpected restart rejection: \(error)") }
        precondition(!restartedModel.chat.running && restartedModel.registry.device.controls.isEmpty)

        let blockedStore = directory.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blockedStore)
        testModel.chat.store = ConversationStore(directory: blockedStore, key: SymmetricKey(data: Data(repeating: 3, count: 32)))
        testModel.chat.selectDevice("phone-a")
        _ = try await invoke(ConversationCommand(action: .stop))
        precondition(testModel.registry.device.controls == [.stop])
        let cancelledLease = UUID()
        _ = try await invoke(ConversationCommand(action: .pause, leaseID: cancelledLease))
        do {
            _ = try await invoke(ConversationCommand(action: .send, text: "Delayed send", leaseID: cancelledLease))
            preconditionFailure("Revoked delayed send accepted")
        } catch { }
        testModel.chat.voiceLeaseID = UUID()
        let count = testModel.registry.device.controls.count
        _ = try await invoke(ConversationCommand(action: .pause, leaseID: cancelledLease))
        precondition(testModel.registry.device.controls.count == count)
        testModel.chat.voiceLeaseID = nil
        _ = try await invoke(ConversationCommand(action: .pause, leaseID: cancelledLease))
        precondition(testModel.registry.device.controls.count == count)
        let clientID = UUID(), beforeStop = testModel.registry.device.controlState.generation
        _ = try await invoke(ConversationCommand(action: .stop, clientID: clientID, sequence: 2, controlGeneration: beforeStop))
        let stoppedCount = testModel.registry.device.controls.count
        let stoppedSnapshot = try await service.snapshot(phoneID: "phone-a")
        precondition(stoppedSnapshot.paused && stoppedSnapshot.controlGeneration == testModel.registry.device.controlState.generation)
        _ = try await invoke(ConversationCommand(action: .send, text: "Overtaken send", clientID: clientID, sequence: 1, controlGeneration: beforeStop))
        precondition(testModel.registry.device.controls.count == stoppedCount && !testModel.chat.running)
        do {
            _ = try await invoke(ConversationCommand(action: .send, text: "Old connection send", clientID: UUID(), sequence: 1, controlGeneration: beforeStop))
            preconditionFailure("Stale control generation accepted")
        } catch PhoneServiceError.invalidArgument(let message) {
            precondition(message.contains("Control changed"))
        } catch { preconditionFailure("Unexpected control rejection: \(error)") }
        print("PASS: storage-independent emergency stop and stale voice pause rejection")
        let connection = CompanionConnection()
        connection.acceptPairing(URL(string: "taplyne://pair?server=http%3A%2F%2Fevil.example&key=123456789012345678901234")!)
        precondition(connection.error != nil)
        connection.acceptPairing(URL(string: "taplyne://pair?server=http%3A%2F%2F127.0.0.1%3A17788&key=123456789012345678901234")!)
        precondition(connection.error == nil && connection.address == "http://127.0.0.1:17788")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CompanionProtocol.self]
        connection.session = URLSession(configuration: config); connection.credentialWriter = { _, _ in }
        var replies: [String] = []; connection.onReply = { replies.append($0) }
        await connection.connect()
        precondition(connection.connected && connection.snapshot?.messages.first?.text == "Old history")
        precondition(replies.isEmpty)
        connection.disconnect()
        precondition(!connection.connected && connection.snapshot == nil)
        connection.acceptPairing(URL(string: "taplyne://pair?server=http%3A%2F%2F127.0.0.1%3A17788&key=123456789012345678901234&key=duplicate")!)
        precondition(connection.error != nil)
        connection.session.invalidateAndCancel()
        print("PASS: companion pairing policy, secure persistence boundary, silent history seed and disconnect")
        try verifyIdentityTokens()
        print("PASS: workflow inputs, incomplete SSE rejection and signed OIDC validation")
        print("PASS: device-isolated persistent Unicode-ready histories, owner-only permissions, recovery and live steering")
        print("PASS: real string tool errors, single pause notification, intentional exit 143, immediate resume, stop and local error text")
    }
}

// Minimal app boundary for running the production command service without Bluetooth or UI.
@MainActor final class AppModel {
    let registry = TestPhoneRegistry()
    let chat = AgentChat()
    func conversation(for id: String) -> AgentChat { chat }
    func openAIKey(voice: Bool = false) -> String? { nil }
}
@MainActor final class TestPhoneRegistry {
    let device = TestPhone()
    func phone(_ id: String) -> TestPhone? { id == "phone-a" ? device : nil }
}
@MainActor final class TestPhone {
    var controls: [PhoneControlCommand] = []
    var controlState = PhoneControlState()
    func control(_ command: PhoneControlCommand) { controls.append(command); controlState.generation += 1; controlState.mode = command == .resume ? .automatic : .paused }
}
enum RealtimeVoice { static var configuration: [String: Any] { [:] } }

final class CompanionProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let payload: String
        if request.url!.path.hasSuffix("phones") {
            payload = #"[{"id":"phone-a","name":"Fixture","connection_status":"online"}]"#
        } else {
            payload = #"{"phoneID":"phone-a","serverSessionID":"11111111-1111-4111-8111-111111111111","controlGeneration":0,"running":false,"paused":false,"messages":[{"id":"old","kind":"assistant","text":"Old history"}]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
