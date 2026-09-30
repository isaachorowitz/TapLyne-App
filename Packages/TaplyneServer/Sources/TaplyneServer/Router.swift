import Foundation

/// Authentication and dispatch for every route.
final class Router: Sendable {
    let configuration: ServerConfiguration
    let controller: PhoneController
    let rest: REST
    let mcp: MCPServer
    let live: LiveView

    init(configuration: ServerConfiguration, service: any PhoneService) {
        self.configuration = configuration
        let controller = PhoneController(service: service)
        self.controller = controller
        self.rest = REST(controller: controller)
        self.mcp = MCPServer(controller: controller, version: configuration.version)
        self.live = LiveView(controller: controller)
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let parts = request.path.split(separator: "/").map(String.init)
        let first = parts.first

        if first == "v1" || first == "mcp" {
            if let failure = authenticate(request, allowQueryKey: false) { return failure.response }
            return first == "mcp" ? await mcp.handle(request) : await rest.handle(request, parts: Array(parts.dropFirst()))
        }
        if request.path == "/" {
            guard request.method == "GET" else { return methodNotAllowed() }
            if authenticate(request, allowQueryKey: true) != nil {
                return live.keyRequiredPage()
            }
            return await live.dashboard(key: providedKey(request, allowQueryKey: true) ?? "")
        }
        if first == "stream", parts.count == 2 {
            guard request.method == "GET" else { return methodNotAllowed() }
            if let failure = authenticate(request, allowQueryKey: true) { return failure.response }
            return await live.stream(phoneID: parts[1])
        }
        return APIError.notFound("No route for \(request.method) \(request.path)").response
    }

    private func methodNotAllowed() -> HTTPResponse {
        APIError(status: 405, code: "METHOD_NOT_ALLOWED", message: "Method not allowed").response
    }

    private func providedKey(_ request: HTTPRequest, allowQueryKey: Bool) -> String? {
        if let key = request.header("x-api-key"), !key.isEmpty { return key }
        if let auth = request.header("authorization"), auth.lowercased().hasPrefix("bearer ") {
            let token = auth.dropFirst(7).trimmingCharacters(in: .whitespaces)
            if !token.isEmpty { return token }
        }
        if allowQueryKey, let key = request.query["key"], !key.isEmpty { return key }
        return nil
    }

    private func authenticate(_ request: HTTPRequest, allowQueryKey: Bool) -> APIError? {
        guard let key = providedKey(request, allowQueryKey: allowQueryKey) else {
            return APIError(
                status: 401, code: "AUTH_REQUIRED",
                message: "Send your API key in the X-API-Key header or as a Bearer token")
        }
        guard Self.constantTimeEqual(key, configuration.apiKey) else {
            return APIError(status: 401, code: "INVALID_API_KEY", message: "The API key is not valid")
        }
        return nil
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) {
            diff |= Int(i < x.count ? x[i] : 0) ^ Int(i < y.count ? y[i] : 0)
        }
        return diff == 0
    }
}
