import Foundation

@testable import TaplyneServer

struct Reply {
    var status: Int
    var data: Data
    var response: HTTPURLResponse
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
    var array: [[String: Any]] { (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? [] }
    var detail: [String: Any] { json["detail"] as? [String: Any] ?? [:] }
}

final class Harness: @unchecked Sendable {
    let service = FakePhoneService()
    let server: TaplyneHTTPServer
    let key = APIKeyGenerator.generate()
    let session = URLSession(configuration: .ephemeral)

    init(conversations: (any ConversationService)? = nil) throws {
        server = TaplyneHTTPServer(
            configuration: ServerConfiguration(host: "127.0.0.1", port: 0, apiKey: key, version: "9.9.9", companionKeys: ["phone-a": "companion-test-only"]),
            service: service, conversations: conversations)
        try server.start()
    }

    deinit { server.stop() }

    var base: String { "http://127.0.0.1:\(server.port)" }

    func request(
        _ method: String = "GET", _ path: String, body: Any? = nil, rawBody: String? = nil,
        auth: String? = "key", headers: [String: String] = [:]
    ) async throws -> Reply {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = method
        switch auth {
        case "key": req.setValue(key, forHTTPHeaderField: "X-API-Key")
        case "bearer": req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .some(let other): req.setValue(other, forHTTPHeaderField: "X-API-Key")
        case nil: break
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let rawBody {
            req.httpBody = Data(rawBody.utf8)
        }
        let (data, response) = try await session.data(for: req)
        let http = response as! HTTPURLResponse
        return Reply(status: http.statusCode, data: data, response: http)
    }

    func rpc(_ method: String, _ params: [String: Any] = [:], id: Int = 1) async throws -> Reply {
        try await request("POST", "/mcp", body: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }
}
