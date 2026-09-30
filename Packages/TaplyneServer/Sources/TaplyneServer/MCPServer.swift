import Foundation

/// MCP over streamable HTTP: JSON responses only, no SSE.
final class MCPServer: Sendable {
    static let supported = ["2025-11-25", "2025-06-18", "2025-03-26"]
    let controller: PhoneController
    let version: String
    let tools: MCPTools

    init(controller: PhoneController, version: String) {
        self.controller = controller
        self.version = version
        self.tools = MCPTools(controller: controller)
    }

    static let instructions =
        "Controls physical iPhones. Call list_phones first to get phone ids and check who is online. "
        + "Use describe_screen or screenshot to get a frame_id before coordinate input. Each action returns fresh screen evidence and verification. "
        + "Coordinates are pixels in the referenced screenshot image. Prefer tap_label and scroll_to_item. Never replay uncertain input automatically. Pause or takeover cancels queued input; resume requires a fresh observation."

    func handle(_ r: HTTPRequest) async -> HTTPResponse {
        switch r.method {
        case "POST": break
        case "DELETE": return .empty(204)
        default:
            return HTTPResponse(status: 405, headers: [("Allow", "POST, DELETE")], body: .data(Data()))
        }
        guard let message = JSON.object(r.body) as? [String: Any] else {
            return rpcError(nil, -32700, "Parse error: the body must be one JSON-RPC message", status: 400)
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            // A client response or malformed message: acknowledge without a body.
            return id == nil || message["result"] != nil || message["error"] != nil
                ? .empty(202) : rpcError(id, -32600, "Invalid request")
        }
        guard let id else { return .empty(202) }  // notification
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let chosen = Self.supported.contains(asked) ? asked : Self.supported[0]
            var response = rpcResult(
                id,
                [
                    "protocolVersion": chosen,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "taplyne", "version": version],
                    "instructions": Self.instructions,
                ])
            response.headers.append(("Mcp-Session-Id", UUID().uuidString.lowercased()))
            return response
        case "ping": return rpcResult(id, [String: Any]())
        case "tools/list": return rpcResult(id, ["tools": MCPTools.definitions])
        case "tools/call":
            guard let name = params["name"] as? String, MCPTools.names.contains(name) else {
                return rpcError(id, -32602, "Unknown tool: \(params["name"] as? String ?? "(missing)")")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            switch await tools.call(name, arguments) {
            case .success(let result): return rpcResult(id, result)
            case .failure(let bad): return rpcError(id, -32602, bad.message)
            }
        default:
            return rpcError(id, -32601, "Method not found: \(method)")
        }
    }

    func rpcResult(_ id: Any?, _ result: Any) -> HTTPResponse {
        .json(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    func rpcError(_ id: Any?, _ code: Int, _ message: String, status: Int = 200) -> HTTPResponse {
        .json(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]], status: status)
    }
}
