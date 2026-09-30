import Foundation
import ImageIO
import Testing

@testable import TaplyneServer

@Suite struct MCPAndStreamTests {
    let h: Harness
    let id = FakePhoneService.online

    init() throws { h = try Harness() }

    private func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        try await h.rpc("tools/call", ["name": name, "arguments": args]).json
    }

    @Test func initializeAndList() async throws {
        let r = try await h.rpc("initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "t", "version": "1"]])
        #expect(r.status == 200)
        let result = try #require(r.json["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "taplyne")
        #expect((result["serverInfo"] as? [String: Any])?["version"] as? String == "9.9.9")
        #expect(((result["capabilities"] as? [String: Any])?["tools"] as? [String: Any])?["listChanged"] as? Bool == false)
        #expect((result["instructions"] as? String)?.contains("list_phones") == true)
        #expect(r.response.value(forHTTPHeaderField: "Mcp-Session-Id") != nil)
        let odd = try await h.rpc("initialize", ["protocolVersion": "1999-01-01"])
        #expect(((odd.json["result"] as? [String: Any])?["protocolVersion"] as? String) == "2025-11-25")

        let note = try await h.request("POST", "/mcp", body: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(note.status == 202 && note.data.isEmpty)
        #expect(try await h.request("GET", "/mcp").status == 405)
        #expect(try await h.request("DELETE", "/mcp").status == 204)
        #expect(((try await h.rpc("ping")).json["result"] as? [String: Any])?.isEmpty == true)
        #expect(((try await h.rpc("nope")).json["error"] as? [String: Any])?["code"] as? Int == -32601)

        let list = try await h.rpc("tools/list").json
        let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        let expected: Set<String> = [
            "list_phones", "get_phone_status", "screenshot", "tap", "double_tap", "triple_tap", "long_press", "flick", "drag",
            "hold_and_drag", "type_text", "press_key", "press_home", "list_apps",
            "describe_screen", "tap_label", "scroll_to_item", "wait_for_text", "fill_field", "fill_form", "navigate", "open_app", "control_phone",
        ]
        #expect(names == expected)
        for t in tools {
            #expect((t["description"] as? String)?.isEmpty == false)
            #expect((t["inputSchema"] as? [String: Any])?["type"] as? String == "object")
        }
    }

    @Test func screenshotAndCoordinateConversion() async throws {
        let shot = try await call("screenshot", ["phone_id": id])
        let content = try #require((shot["result"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "image" && content[0]["mimeType"] as? String == "image/jpeg")
        let data = try #require(Data(base64Encoded: content[0]["data"] as? String ?? ""))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let w = props[kCGImagePropertyPixelWidth] as? Int, ht = props[kCGImagePropertyPixelHeight] as? Int
        // 1320x2868 fitted to a 1344 long edge: 1320 * 1344 / 2868 = 618.58, rounded to 619.
        #expect(w == 619 && ht == 1344)
        let metadata = try #require((shot["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        let screen = try #require(metadata["screen"] as? [String: Any])
        let frame = try #require(screen["frame_id"] as? String)
        #expect(screen["width"] as? Int == 619 && screen["height"] as? Int == 1344)
        let tap = try await call("tap", ["phone_id": id, "frame_id": frame, "x": 100, "y": 200])
        let result = try #require((tap["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        #expect(result["input_delivered"] as? Bool == true)
        #expect((result["verification"] as? [String: Any])?["status"] as? String == "unverified")
        let current = try #require((result["screen"] as? [String: Any])?["frame_id"] as? String)
        _ = try await call("long_press", ["phone_id": id, "frame_id": current, "x": 10, "y": 20, "duration": 2000])
        let outside = try await call("tap", ["phone_id": id, "frame_id": current, "x": 5000, "y": 5000])
        #expect((outside["result"] as? [String: Any])?["isError"] as? Bool == true)
        let fresh = try await call("describe_screen", ["phone_id": id])
        let freshFrame = try #require(((fresh["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["screen"] as? [String: Any])["frame_id"] as? String
        _ = try await call("drag", ["phone_id": id, "frame_id": try #require(freshFrame), "from_x": 1, "from_y": 2, "to_x": 3, "to_y": 4, "speed": "fast"])
        let px = { (v: Double) in Int((v * 1320 / 619).rounded()) }
        let py = { (v: Double) in Int((v * 2868 / 1344).rounded()) }
        #expect(h.service.actions == [
            .tap(x: px(100), y: py(200)), .tapAndHold(x: px(10), y: py(20), durationMs: 2000),
            .drag(fromX: px(1), fromY: py(2), toX: px(3), toY: py(4), speed: .fast),
        ])
        let stale = try await call("tap", ["phone_id": id, "frame_id": frame, "x": 1, "y": 1])
        #expect((stale["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(h.service.actions.count == 3)
    }

    @Test func toolErrors() async throws {
        let offline = try await call("tap", ["phone_id": FakePhoneService.offline, "x": 1, "y": 1])
        let r = try #require(offline["result"] as? [String: Any])
        #expect(r["isError"] as? Bool == true)
        let text = (r["content"] as? [[String: Any]])?[0]["text"] as? String ?? ""
        #expect(text.contains("Not plugged in"))
        let missing = try await call("tap", ["phone_id": "zzz", "x": 1, "y": 1])
        #expect((missing["result"] as? [String: Any])?["isError"] as? Bool == true)
        let unknownTool = try await call("teleport", [:])
        #expect((unknownTool["error"] as? [String: Any])?["code"] as? Int == -32602)
        let badParams = try await call("tap", ["phone_id": id, "x": "left", "y": 1])
        #expect((badParams["error"] as? [String: Any])?["code"] as? Int == -32602)
        let phones = try await call("list_phones", [:])
        let listText = ((phones["result"] as? [String: Any])?["content"] as? [[String: Any]])?[0]["text"] as? String ?? ""
        #expect(listText.contains("619x1344") && listText.contains(id))
    }

    @Test func mjpegHeadersAndDisconnect() async throws {
        var request = URLRequest(url: URL(string: "\(h.base)/stream/\(id)?key=\(h.key)")!)
        request.timeoutInterval = 10
        let (bytes, response) = try await h.session.bytes(for: request)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "multipart/x-mixed-replace; boundary=taplyneframe")
        var head = Data()
        for try await byte in bytes {
            head.append(byte)
            if head.count >= 16 { break }
        }
        // Foundation strips the multipart framing and delivers each part's body: a JPEG.
        #expect(head.prefix(2) == Data([0xFF, 0xD8]))
        // Leaving the loop cancels the request; the frame iteration must end.
        for _ in 0..<100 where !h.service.liveStopped { try await Task.sleep(for: .milliseconds(50)) }
        #expect(h.service.liveStopped)
    }

    @Test func streamAndDashboardAuth() async throws {
        #expect(try await h.request("GET", "/stream/\(id)", auth: nil).status == 401)
        #expect(try await h.request("GET", "/stream/nope?key=\(h.key)", auth: nil).status == 404)
        let noKey = try await h.request("GET", "/", auth: nil)
        #expect(noKey.status == 401 && String(decoding: noKey.data, as: UTF8.self).contains("?key="))
        let page = try await h.request("GET", "/?key=\(h.key)", auth: nil)
        let html = String(decoding: page.data, as: UTF8.self)
        #expect(page.status == 200 && html.contains("Test iPhone") && html.contains("/stream/\(id)?key=\(h.key)"))
        #expect(html.contains("prefers-color-scheme") && !html.contains("http://") && !html.contains("https://"))
        #expect(!html.contains("/stream/\(FakePhoneService.offline)"))
    }
}
