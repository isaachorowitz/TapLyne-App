import AppKit
import Foundation
import TaplyneServer

@main struct AgentChatTests {
    @MainActor static func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(condition(), "Agent state did not settle")
    }

    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/agent-tests/fixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = directory.appendingPathComponent("fake-claude.py")
        try """
        #!/usr/bin/python3
        import json,signal,sys,time
        signal.signal(signal.SIGTERM,lambda *_:sys.exit(143))
        if '--resume' in sys.argv:
            prompt=sys.argv[sys.argv.index('-p')+1]
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
        print("PASS: real string tool errors, single pause notification, intentional exit 143, immediate resume, stop and local error text")
    }
}
