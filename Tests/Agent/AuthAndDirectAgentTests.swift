import AppKit
import Foundation

@MainActor
enum AuthAndDirectAgentTests {
    static func run() async throws {
        try await accountIsolationAndSelection()
        try await keyValidation()
        budgetAndStreamingLifecycle()
        try streamParsingAndRecovery()
        print("PASS: isolated ChatGPT accounts, pinned run identity, BYOK validation, bounded context and transient streaming")
    }

    private static func accountIsolationAndSelection() async throws {
        let suite = "taplyne-auth-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = TestCredentialVault()
        let first = tokens(client: "client-a", subject: "subject-a", access: "access-a", email: "a@example.test")
        let second = tokens(client: "client-b", subject: "subject-b", access: "access-b", email: "b@example.test")
        let profiles = [ChatGPTAuth.profile(from: first), ChatGPTAuth.profile(from: second)]
        defaults.set(try JSONEncoder().encode(profiles), forKey: ChatGPTAuth.profilesDefaultsKey)
        defaults.set(profiles[0].id, forKey: ChatGPTAuth.activeProfileDefaultsKey)
        for (profile, token) in zip(profiles, [first, second]) {
            vault.values[ChatGPTAuth.credentialAccount(profile.id)] = String(decoding: try JSONEncoder().encode(token), as: UTF8.self)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentTestURLProtocol.self]
        AgentTestURLProtocol.handler = { request in
            precondition(request.url?.path == "/v1/models")
            let body = #"{"models":[{"slug":"eligible-model","display_name":"Eligible","visibility":"list"},{"slug":"hidden","visibility":"hide"}]}"#
            return (200, Data(body.utf8))
        }
        let auth = ChatGPTAuth(defaults: defaults, session: URLSession(configuration: configuration),
            credentialReader: { vault.values[$0] },
            credentialWriter: { value, account in vault.values[account] = value; return true },
            credentialDeleter: { vault.values[$0] = nil })
        precondition(auth.profiles.count == 2 && auth.activeProfileID == profiles[0].id)
        let run = try await auth.captureRun()
        precondition(run.profileID == profiles[0].id && run.accessToken == "access-a" && run.models.map(\.id) == ["eligible-model"])
        await auth.selectProfile(profiles[1].id)
        let activeToken = try await auth.accessToken()
        let pinnedToken = try await auth.accessToken(for: run.profileID)
        precondition(auth.activeProfileID == profiles[1].id && activeToken == "access-b")
        precondition(pinnedToken == "access-a", "A run must keep its original identity after an account switch")
    }

    private static func keyValidation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentTestURLProtocol.self]
        AgentTestURLProtocol.handler = { request in
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            return (200, Data(#"{"data":[{"id":"model-a"},{"id":"model-b"}]}"#.utf8))
        }
        let result = try await OpenAIKeyValidator.validate("  test-key  ", session: URLSession(configuration: configuration),
            endpoint: URL(string: "https://api.openai.com/v1/models")!)
        precondition(result.modelCount == 2)
        AgentTestURLProtocol.handler = { _ in (401, Data(#"{"error":{"message":"secret detail"}}"#.utf8)) }
        do {
            _ = try await OpenAIKeyValidator.validate("rejected", session: URLSession(configuration: configuration))
            preconditionFailure("Rejected BYOK key was accepted")
        } catch {
            precondition(error.localizedDescription.contains("rejected"))
            precondition(!error.localizedDescription.contains("secret detail"))
        }
    }

    private static func budgetAndStreamingLifecycle() {
        let history = (0..<40).map { ["role": "user", "content": String(repeating: "x", count: 2_000) + "\($0)"] }
        let bounded = DirectAgentBudget.history(history)
        precondition(bounded.count <= DirectAgentBudget.maxHistoryMessages)
        precondition(bounded.reduce(0) { $0 + ($1["content"]?.count ?? 0) } <= DirectAgentBudget.maxHistoryCharacters)
        precondition(bounded.last?["content"]?.hasSuffix("39") == true)
        let tool = DirectAgentBudget.toolOutput(String(repeating: "a", count: 50_000))
        precondition(tool.count < 50_000 && tool.contains("shortened locally"))
        let chat = AgentChat()
        var spoken: [String] = []
        chat.onAssistantText = { spoken.append($0) }
        chat.appendAssistantDelta("partial ")
        chat.appendAssistantDelta("reply")
        precondition(chat.entries.last?.text == "partial reply" && spoken.isEmpty)
        chat.cancelAssistantStream()
        precondition(chat.entries.isEmpty && spoken.isEmpty)
        chat.appendAssistantDelta("complete")
        chat.finishAssistantStream()
        precondition(chat.entries.last?.text == "complete" && spoken == ["complete"])
    }

    private static func streamParsingAndRecovery() throws {
        var parser = ResponseStreamParser(planUsage: true)
        let deltaEvents = try parser.consume(Data((#"data: {"type":"response.output_text.delta","delta":"hello"}"# + "\n\n").utf8))
        guard deltaEvents.count == 1, case let .delta(text) = deltaEvents[0] else { preconditionFailure("Missing stream delta") }
        precondition(text == "hello")
        let completedEvents = try parser.consume(Data((#"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"# + "\n\n").utf8))
        guard completedEvents.count == 1, case .completed = completedEvents[0] else { preconditionFailure("Missing terminal completion") }
        do {
            _ = try parser.consume(Data((#"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"# + "\n\n").utf8))
            preconditionFailure("Usage limit stream was accepted")
        } catch {
            precondition(error.localizedDescription.contains("shared plan limit"))
        }
        let byok = DirectAgentClient.httpFailure(status: 429, data: Data(), planUsage: false)
        precondition(byok.localizedDescription.contains("spend limit") && byok.localizedDescription.contains("no phone action"))

        var crlf = ResponseStreamParser(planUsage: false)
        let stream = """
        data: {"type":"response.output_text.delta","delta":"hello"}\r
        \r
        data: {"type":"response.completed","response":{"status":"completed","output":[]}}
        """
        let split = Data(stream.utf8).split(at: Data(stream.utf8).count - 1)
        let firstEvents = try crlf.consume(split.0)
        precondition(firstEvents.count == 1)
        guard case let .delta(crlfText) = firstEvents[0] else { preconditionFailure("CRLF delta was not framed") }
        precondition(crlfText == "hello")
        let trailingEvents = try crlf.consume(split.1)
        precondition(trailingEvents.isEmpty)
        let finalEvents = try crlf.finish()
        guard finalEvents.count == 1, case .completed = finalEvents[0] else {
            preconditionFailure("Terminal event at EOF was discarded")
        }
    }

    private static func tokens(client: String, subject: String, access: String, email: String) -> ChatGPTAuth.Tokens {
        ChatGPTAuth.Tokens(clientID: client, subject: subject, access: access, refresh: "refresh-\(subject)", identity: "identity-\(subject)",
            expires: Date().addingTimeInterval(3_600), earliestRefresh: nil,
            scopes: ["openid", ChatGPTAuth.requiredScope], email: email, displayName: nil)
    }
}

private extension Data {
    func split(at index: Int) -> (Data, Data) {
        (prefix(index), suffix(count - index))
    }
}

private final class TestCredentialVault { var values: [String: String] = [:] }

private final class AgentTestURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
