import Foundation

/// Authentication and dispatch for every route.
final class Router: Sendable {
    let configuration: ServerConfiguration
    let controller: PhoneController
    let rest: REST
    let mcp: MCPServer
    let agentCapabilities: AgentCapabilities
    let live: LiveView
    let conversations: ConversationAPI?

    init(configuration: ServerConfiguration, service: any PhoneService, conversations: (any ConversationService)? = nil) {
        self.conversations = conversations.map { ConversationAPI(service: $0) }
        self.configuration = configuration
        let controller = PhoneController(service: service)
        self.controller = controller
        self.rest = REST(controller: controller)
        self.mcp = MCPServer(controller: controller, version: configuration.version)
        self.live = LiveView(controller: controller)
        self.agentCapabilities = AgentCapabilities(service: service, version: configuration.version, keys: configuration.agentKeys)
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let parts = request.path.split(separator: "/").map(String.init)
        let first = parts.first

        if first == "companion" {
            guard let key = providedKey(request, allowQueryKey: false),
                  let phoneID = configuration.companionKeys.first(where: { Self.constantTimeEqual($0.value, key) })?.key else {
                return APIError(status: 401, code: "COMPANION_AUTH_REQUIRED", message: "Pair this device using its companion key from Taplyne Settings.").response
            }
            if parts == ["companion", "phones"], request.method == "GET" {
                return .json(await controller.service.listPhones().filter { $0.id == phoneID }.map(phoneJSON))
            }
            if parts == ["companion", "voice", phoneID], request.method == "POST", let conversations {
                do { return .data(try await conversations.service.voiceCredential(phoneID: phoneID), contentType: "application/json") }
                catch { return APIError(status: 409, code: "VOICE_UNAVAILABLE", message: "Live voice needs an OpenAI API key on the Mac. Wait before retrying.").response }
            }
            if parts.count == 3, parts[1] == "conversations", parts[2] == phoneID, let conversations {
                return await conversations.handle(request, phoneID: phoneID)
            }
            return APIError.notFound().response
        }
        if first == "mcp", let key = providedKey(request, allowQueryKey: false),
           let scoped = agentCapabilities.server(for: key) { return await scoped.handle(request) }
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
