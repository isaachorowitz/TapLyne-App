import Foundation
import Testing

@testable import TaplyneServer

@Suite struct RESTTests {
    let h: Harness
    let id = FakePhoneService.online

    init() throws { h = try Harness() }

    @Test func conversationAuthenticationValidationAndUnicode() async throws {
        let conversations = FakeConversations()
        let h = try Harness(conversations: conversations)
        let path = "/companion/conversations/phone-a"
        #expect(try await h.request("GET", path, auth: nil).status == 401)
        #expect(try await h.request("POST", path, body: ["action": "send", "text": "hi"], auth: "companion-test-only").status == 400)
        #expect(try await h.request("POST", path, body: ["id": UUID().uuidString, "action": "send", "text": "  "], auth: "companion-test-only").status == 400)
        #expect(try await h.request("POST", path, body: ["id": UUID().uuidString, "action": "send", "text": String(repeating: "x", count: 16001)], auth: "companion-test-only").status == 400)
        #expect(try await h.request("DELETE", path, auth: "companion-test-only").status == 405)
        let reply = try await h.request("POST", path, body: ["id": UUID().uuidString, "action": "send", "text": "שלום 👋", "clientID": UUID().uuidString, "sequence": 1, "controlGeneration": 0, "serverSessionID": UUID().uuidString, "issuedAt": Date().timeIntervalSinceReferenceDate], auth: "companion-test-only")
        #expect(reply.status == 200)
        let decoded = try JSONDecoder().decode(ConversationSnapshot.self, from: reply.data)
        #expect(decoded.phoneID == "phone-a")
        #expect(decoded.messages.last?.text == "שלום 👋")
        #expect(try await h.request("GET", path).status == 401)
        #expect(try await h.request("POST", "/companion/conversations/phone-b", body: ["id": UUID().uuidString, "action": "resume"], auth: "companion-test-only").status == 404)
        #expect(try await h.request("POST", "/v1/conversations/phone-a", body: ["id": UUID().uuidString, "action": "resume"]).status == 404)
        #expect(await conversations.count == 1)
    }

    @Test func deviceCapabilitiesAreIsolatedAndRevoked() async throws {
        let h = try Harness(conversations: FakeConversations())
        h.server.registerAgent(phoneID: id, key: "device-agent-a")
        func rpc(_ name: String, _ args: [String: Any] = [:], key: String = "device-agent-a") async throws -> Reply {
            try await h.request("POST", "/mcp", body: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]], auth: key)
        }
        let phones = try await rpc("list_phones")
        let serialized = String(decoding: phones.data, as: UTF8.self)
        #expect(serialized.contains(id))
        #expect(!serialized.contains(FakePhoneService.offline))
        let denied = try await rpc("get_phone_status", ["phone_id": FakePhoneService.offline])
        #expect((denied.json["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(try await h.request("GET", "/v1/phones", auth: "device-agent-a").status == 401)
        #expect(try await h.request("GET", "/companion/phones", auth: "device-agent-a").status == 401)
        h.server.registerAgent(phoneID: id, key: "device-agent-new")
        #expect(try await rpc("list_phones").status == 401)
        #expect(try await rpc("list_phones", key: "device-agent-new").status == 200)
        #expect(try await h.request("POST", "/companion/voice/phone-a", auth: nil).status == 401)
        #expect(try await h.request("POST", "/companion/voice/phone-a").status == 401)
        #expect(try await h.request("POST", "/companion/voice/phone-b", auth: "companion-test-only").status == 404)
        #expect(try await h.request("POST", "/companion/voice/phone-a", auth: "companion-test-only").status == 409)
    }

    @Test func voiceLeaseRevocationWinsOverDelayedSendAndHeartbeat() {
        let start = Date(timeIntervalSince1970: 100)
        let old = UUID(), fresh = UUID()
        var book = ConversationLeaseBook()
        book.revoke(old, phoneID: "a")
        let leaseResult1 = book.grant(old, phoneID: "a", now: start); #expect(!leaseResult1)
        let leaseResult2 = book.grant(fresh, phoneID: "a", now: start); #expect(leaseResult2)
        let leaseResult3 = book.renew(old, phoneID: "a", now: start); #expect(!leaseResult3)
        let leaseResult4 = book.renew(fresh, phoneID: "b", now: start); #expect(!leaseResult4)
        let leaseResult5 = book.renew(fresh, phoneID: "a", now: start.addingTimeInterval(5)); #expect(leaseResult5)
        #expect(!book.expired(fresh, phoneID: "a", now: start.addingTimeInterval(12)))
        #expect(book.expired(fresh, phoneID: "a", now: start.addingTimeInterval(15)))
        let leaseResult6 = book.renew(fresh, phoneID: "a", now: start.addingTimeInterval(15)); #expect(!leaseResult6)
        book.revoke(old, phoneID: "a")
        #expect(book.currentID(phoneID: "a") == fresh)
    }

    @Test func apiKeyFormat() {
        let key = APIKeyGenerator.generate()
        #expect(key.hasPrefix("tl_") && key.count == 43)
        #expect(key.dropFirst(3).allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(key != APIKeyGenerator.generate())
    }

    @Test func authFailures() async throws {
        let missing = try await h.request("GET", "/v1/phones", auth: nil)
        #expect(missing.status == 401)
        #expect(missing.detail["error"] as? String == "AUTH_REQUIRED")
        #expect(missing.detail["context"] is [String: Any])
        let wrong = try await h.request("GET", "/v1/phones", auth: "tl_wrong")
        #expect(wrong.status == 401)
        #expect(wrong.detail["error"] as? String == "INVALID_API_KEY")
        let mcp = try await h.request("POST", "/mcp", auth: nil)
        #expect(mcp.status == 401)
        let bearer = try await h.request("GET", "/v1/phones", auth: "bearer")
        #expect(bearer.status == 200)
        #expect(Router.constantTimeEqual("abc", "abc") && !Router.constantTimeEqual("abc", "abd") && !Router.constantTimeEqual("abc", "abcd"))
    }

    @Test func listStatusRename() async throws {
        let list = try await h.request("GET", "/v1/phones").array
        #expect(list.count == 2)
        let p = list[0]
        #expect(p["id"] as? String == id)
        #expect(p["activation_state"] as? String == "active")
        #expect(p["connection_status"] as? String == "online")
        #expect(p["width"] as? Int == 1320 && p["height"] as? Int == 2868)
        #expect(p["display_name"] is NSNull)
        #expect(p["model"] as? String == "iPhone 17 Pro Max")
        #expect((p["created_at"] as? String)?.hasSuffix("Z") == true)
        #expect(p["connected_mac_id"] as? String == macIdentifier)
        #expect(list[1]["status_reason"] as? String == "Not plugged in to this Mac")
        #expect(list[1]["width"] is NSNull)

        let status = try await h.request("GET", "/v1/phones/\(id)/status").json
        #expect(status["phone_id"] as? String == id && status["phone_name"] as? String == "Test iPhone")

        let renamed = try await h.request("PATCH", "/v1/phones/\(id)/settings", body: ["display_name": "Desk phone"])
        #expect(renamed.json["display_name"] as? String == "Desk phone")
        let status2 = try await h.request("GET", "/v1/phones/\(id)/status").json
        #expect(status2["phone_name"] as? String == "Desk phone")
        let cleared = try await h.request("PATCH", "/v1/phones/\(id)/settings", body: ["display_name": "  "])
        #expect(cleared.json["display_name"] is NSNull)
        let missing = try await h.request("PATCH", "/v1/phones/\(id)/settings", body: [String: String]())
        #expect(missing.status == 400)
    }

    @Test func appsAndScreenshot() async throws {
        let apps = try await h.request("GET", "/v1/phones/\(id)/apps").json
        #expect(apps["app_count"] as? Int == 1 && apps["source"] as? String == "database" && apps["updated_at"] != nil)
        let fresh = try await h.request("POST", "/v1/phones/\(id)/apps/refresh").json
        #expect(fresh["updated_at"] == nil && fresh["source"] as? String == "device")

        let png = try await h.request("GET", "/v1/phones/\(id)/screenshot")
        #expect(png.response.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(png.response.value(forHTTPHeaderField: "X-Taplyne-Frame-Id") != nil)
        #expect(png.data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))

        let async = try await h.request("GET", "/v1/phones/\(id)/screenshot?async=true").json
        let jobID = try #require(async["job_id"] as? String)
        var download = try await h.request("GET", "/v1/jobs/\(jobID)/download")
        for _ in 0..<50 where download.status != 200 {
            try await Task.sleep(for: .milliseconds(50))
            download = try await h.request("GET", "/v1/jobs/\(jobID)/download")
        }
        #expect(download.status == 200 && download.data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        let missing = try await h.request("GET", "/v1/jobs/nope/download")
        #expect(missing.status == 404)
    }

    private func frameID() async throws -> String {
        let response = try await h.request("GET", "/v1/phones/\(id)/describe")
        return try #require((response.json["screen"] as? [String: Any])?["frame_id"] as? String)
    }

    @Test func syncActionJob() async throws {
        let r = try await h.request("POST", "/v1/phones/\(id)/tap", body: ["x": 100, "y": 200, "frame_id": try await frameID()])
        #expect(r.status == 200)
        let job = r.json
        #expect(job["status"] as? String == "completed")
        #expect(((job["result"] as? [String: Any])?["verification"] as? [String: Any])?["status"] as? String == "unverified")
        let jobID = try #require(job["id"] as? String)
        #expect(jobID == jobID.lowercased() && UUID(uuidString: jobID) != nil)
        #expect(job["completed_at"] as? String != nil)
        #expect(h.service.actions == [.tap(x: 100, y: 200)])

        let again = try await h.request("GET", "/v1/jobs/\(jobID)").json
        #expect(again["status"] as? String == "completed")
        #expect(try await h.request("GET", "/v1/jobs/unknown").status == 404)

        _ = try await h.request("POST", "/v1/phones/\(id)/keypress", body: ["key": "backspace", "repeat": 5, "modifiers": ["shift"], "frame_id": try await frameID()])
        _ = try await h.request("POST", "/v1/phones/\(id)/type", body: ["text": "héllo 你好 🙂", "frame_id": try await frameID()])
        _ = try await h.request("POST", "/v1/phones/\(id)/home")
        _ = try await h.request("POST", "/v1/phones/\(id)/drag", body: ["from_x": 1, "from_y": 2, "to_x": 3, "to_y": 4, "frame_id": try await frameID()])
        #expect(
            h.service.actions.dropFirst() == [
                .keypress(key: .backspace, modifiers: [.shift], repeatCount: 5), .type(text: "héllo 你好 🙂"), .home,
                .drag(fromX: 1, fromY: 2, toX: 3, toY: 4, speed: .medium),
            ])
    }

    @Test func failedActionStillReturns200() async throws {
        h.service.failNextPerform = .failed("Bluetooth dropped")
        let r = try await h.request("POST", "/v1/phones/\(id)/tap", body: ["x": 1, "y": 1, "frame_id": try await frameID()])
        #expect(r.status == 200 && r.json["status"] as? String == "failed")
        #expect((r.json["result"] as? [String: Any])?["error"] as? String == "Bluetooth dropped")
        h.service.failNextPerform = .phoneNotReady("Locked")
        let r2 = try await h.request("POST", "/v1/phones/\(id)/home")
        #expect((r2.json["result"] as? [String: Any])?["error"] as? String == "PHONE_NOT_READY: Locked")
    }

    @Test func asyncActionJob() async throws {
        h.service.performDelay = .milliseconds(200)
        let r = try await h.request("POST", "/v1/phones/\(id)/double-tap?async=true", body: ["x": 5, "y": 6, "frame_id": try await frameID()])
        let jobID = try #require(r.json["job_id"] as? String)
        #expect(r.json.count == 1)
        let early = try await h.request("GET", "/v1/jobs/\(jobID)").json["status"] as? String
        #expect(early == "pending" || early == "running")
        var status = early
        for _ in 0..<50 where status != "completed" {
            try await Task.sleep(for: .milliseconds(50))
            status = try await h.request("GET", "/v1/jobs/\(jobID)").json["status"] as? String
        }
        #expect(status == "completed")
        #expect(h.service.actions == [.doubleTap(x: 5, y: 6)])
    }

    @Test func validation() async throws {
        let base = "/v1/phones/\(id)"
        func detail(_ path: String, _ body: Any?) async throws -> (Int, String, String) {
            let r = try await h.request("POST", path, body: body)
            return (r.status, r.detail["error"] as? String ?? "", r.detail["message"] as? String ?? "")
        }
        let unknown = try await detail("/v1/phones/nope/tap", ["x": 1, "y": 1])
        #expect(unknown.0 == 404 && unknown.1 == "PHONE_NOT_FOUND")
        let offline = try await detail("/v1/phones/\(FakePhoneService.offline)/tap", ["x": 1, "y": 1])
        #expect(offline.0 == 409 && offline.1 == "PHONE_NOT_READY" && offline.2.contains("Not plugged in"))
        let outside = try await detail("\(base)/tap", ["x": 1320, "y": 1])
        #expect(outside.0 == 400 && outside.1 == "INVALID_ARGUMENT" && outside.2.contains("x"))
        let negative = try await detail("\(base)/tap", ["x": 1, "y": -1])
        #expect(negative.0 == 400 && negative.2.contains("y"))
        let missing = try await detail("\(base)/tap", ["x": 1])
        #expect(missing.0 == 400 && missing.2.contains("y"))
        let noBody = try await detail("\(base)/tap", nil)
        #expect(noBody.0 == 400)
        let enumBad = try await detail("\(base)/flick", ["x": 1, "y": 1, "direction": "sideways"])
        #expect(enumBad.0 == 400 && enumBad.2.contains("direction"))
        let dur = try await detail("\(base)/tap-and-hold", ["x": 1, "y": 1, "duration_ms": 20000])
        #expect(dur.0 == 400 && dur.2.contains("duration_ms"))
        let rep = try await detail("\(base)/keypress", ["key": "enter", "repeat": 51])
        #expect(rep.0 == 400 && rep.2.contains("repeat"))
        let key = try await detail("\(base)/keypress", ["key": "f13"])
        #expect(key.0 == 400 && key.2.contains("key"))
        let long = try await detail("\(base)/type", ["text": String(repeating: "a", count: 1001)])
        #expect(long.0 == 400 && long.2.contains("text"))
        let ok = try await detail("\(base)/type", ["text": String(repeating: "é", count: 1000), "frame_id": try await frameID()])
        #expect(ok.0 == 200)
        let badJSON = try await h.request("POST", "\(base)/tap", rawBody: "{nope")
        #expect(badJSON.status == 400)
        #expect(try await h.request("GET", "/v1/nothing").status == 404)
        #expect(try await h.request("DELETE", "/v1/phones").status == 405)
        #expect(h.service.actions.count == 1)
    }

    @Test func actionsAreSerializedPerPhone() async throws {
        h.service.performDelay = .milliseconds(60)
        let id = self.id
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    (try? await self.h.request("POST", "/v1/phones/\(id)/home").status) ?? 0
                }
            }
            for await status in group { #expect(status == 200) }
        }
        #expect(h.service.actions.count == 5)
        #expect(h.service.maxConcurrentActions == 1)
    }

    @Test func requestParserRules() {
        var chunked = Data("POST /v1/phones/x/type HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        guard case .failure(let status, _) = HTTPParser.parse(&chunked) else { Issue.record("expected failure"); return }
        #expect(status == 411)
        var big = Data("POST / HTTP/1.1\r\nContent-Length: 20000000\r\n\r\n".utf8)
        guard case .failure(let s2, _) = HTTPParser.parse(&big) else { Issue.record("expected failure"); return }
        #expect(s2 == 413)
        var two = Data("GET /a?x=1 HTTP/1.1\r\nX-API-KEY: k\r\n\r\nGET /b HTTP/1.1\r\n\r\n".utf8)
        guard case .request(let first) = HTTPParser.parse(&two) else { Issue.record("expected request"); return }
        #expect(first.path == "/a" && first.query["x"] == "1" && first.header("x-api-key") == "k")
        guard case .request(let second) = HTTPParser.parse(&two) else { Issue.record("expected request"); return }
        #expect(second.path == "/b")
    }
}

private actor FakeConversations: ConversationService {
    var count = 0
    var messages: [ConversationMessage] = []
    func snapshot(phoneID: String) -> ConversationSnapshot {
        .init(phoneID: phoneID, running: false, paused: false, messages: messages)
    }
    func command(phoneID: String, command: ConversationCommand) -> ConversationSnapshot {
        count += 1
        messages.append(.init(id: command.id.uuidString, kind: "user", text: command.text ?? ""))
        return snapshot(phoneID: phoneID)
    }
}
