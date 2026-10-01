import AppKit
import Foundation
import TaplyneServer

@MainActor
extension AgentChat {
    func sendDirect(_ prompt: String) {
        guard let url = mcpURL(), let phone = deviceID ?? phoneID(), prepareInput(phone) else {
            append(.error, "Select a ready device and resume its controls before starting.")
            return
        }
        let usesPlan = provider() == "chatgpt"
        let byok = providerKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard usesPlan || !byok.isEmpty else {
            append(.error, "Add your OpenAI API key in Settings. Taplyne never bundles or shares a key.")
            return
        }
        activePhoneID = phone
        paused = false
        let history = DirectAgentBudget.history(entries.filter { $0.kind == .user || $0.kind == .assistant }.map {
            ["role": $0.kind == .user ? "user" : "assistant", "content": $0.text]
        })
        append(.user, prompt)
        running = true
        persist()
        let localKey = apiKey()
        let requestedModel = model()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let instructions = Self.instructions + "\nOperate ONLY phone_id \(phone).\n" + phoneContext()
        directTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.cancelAssistantStream()
                self.running = false
                self.directTask = nil
                self.finishWorkflow()
                self.persist()
                if self.pendingPrompt != nil { self.continuePending() }
                else if self.paused { self.finishPendingResume() }
            }
            do {
                let credential: () async throws -> String
                let selectedModel: String
                if usesPlan {
                    let run = try await ChatGPTAuth.shared.captureRun()
                    let allowed = Set(run.models.map(\.id))
                    selectedModel = allowed.contains(requestedModel) ? requestedModel : (run.models.first?.id ?? "")
                    let profileID = run.profileID
                    credential = { try await ChatGPTAuth.shared.accessToken(for: profileID) }
                } else {
                    selectedModel = requestedModel.isEmpty ? "gpt-5.4" : requestedModel
                    credential = { byok }
                }
                guard !selectedModel.isEmpty else { throw DirectAgentClient.Failure("Choose an eligible model in Settings.") }
                let client = DirectAgentClient(credential: credential, mcpURL: url, mcpKey: localKey, planUsage: usesPlan)
                try await client.run(prompt: prompt, history: history, model: selectedModel, instructions: instructions, phoneID: phone) {
                    [weak self] kind, text, image in self?.append(kind, text, image: image)
                } stream: { [weak self] event in
                    switch event {
                    case let .delta(text): self?.appendAssistantDelta(text)
                    case .completed: self?.finishAssistantStream()
                    case .cancelled: self?.cancelAssistantStream()
                    }
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                self.append(.error, error.localizedDescription)
            }
        }
    }
}

enum DirectAgentStreamEvent { case delta(String), completed, cancelled }

struct DirectAgentBudget {
    static let maxHistoryMessages = 24
    static let maxHistoryCharacters = 32_000
    static let maxToolOutputCharacters = 24_000
    static let maxContextCharacters = 2_000_000
    static let maxContextScreenshots = 2
    static let maxScreenshotBytes = 600_000
    static let maxTurns = 40
    static let byokMaxOutputTokens = 4_096

    static func history(_ messages: [[String: String]]) -> [[String: String]] {
        var result: [[String: String]] = []
        var characters = 0
        for message in messages.suffix(maxHistoryMessages).reversed() {
            let text = message["content"] ?? ""
            if !result.isEmpty && characters + text.count > maxHistoryCharacters { break }
            let remaining = max(0, maxHistoryCharacters - characters)
            var copy = message
            copy["content"] = String(text.suffix(remaining))
            result.append(copy)
            characters += copy["content"]?.count ?? 0
        }
        return result.reversed()
    }

    static func toolOutput(_ text: String) -> String {
        guard text.count > maxToolOutputCharacters else { return text }
        let half = maxToolOutputCharacters / 2
        return String(text.prefix(half)) + "\n… output shortened locally …\n" + String(text.suffix(half))
    }

    static func input(history: [[[String: Any]]], anchor: [String: Any], turns: [[[String: Any]]]) -> [[String: Any]] {
        var keptTurns: [[[String: Any]]] = []
        var characters = serializedCount([anchor])
        var screenshots = 0
        for original in turns.reversed() {
            var group = original
            for index in group.indices.reversed() where isImage(group[index]) {
                if screenshots < maxContextScreenshots { screenshots += 1 }
                else { group.remove(at: index) }
            }
            guard !group.isEmpty else { continue }
            let count = serializedCount(group)
            if !keptTurns.isEmpty && characters + count > maxContextCharacters { break }
            keptTurns.append(group)
            characters += count
        }
        var keptHistory: [[[String: Any]]] = []
        for group in history.reversed() {
            let count = serializedCount(group)
            if characters + count > maxContextCharacters { break }
            keptHistory.append(group)
            characters += count
        }
        return keptHistory.reversed().flatMap { $0 } + [anchor] + keptTurns.reversed().flatMap { $0 }
    }

    static func boundedImage(_ data: Data, mime: String) -> (data: Data, mime: String)? {
        guard ["image/png", "image/jpeg"].contains(mime) else { return nil }
        if data.count <= maxScreenshotBytes { return (data, mime) }
        guard let source = NSImage(data: data), source.size.width > 0, source.size.height > 0 else { return nil }
        let scale = min(1, 1280 / max(source.size.width, source.size.height))
        let target = NSSize(width: max(1, source.size.width * scale), height: max(1, source.size.height * scale))
        let resized = NSImage(size: target)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        for quality in [0.7, 0.5, 0.35] {
            if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpeg.count <= maxScreenshotBytes {
                return (jpeg, "image/jpeg")
            }
        }
        return nil
    }

    private static func serializedCount(_ value: Any) -> Int {
        (try? JSONSerialization.data(withJSONObject: value).count) ?? maxContextCharacters
    }
    private static func isImage(_ item: [String: Any]) -> Bool {
        guard let content = item["content"] as? [[String: Any]] else { return false }
        return content.contains { $0["type"] as? String == "input_image" }
    }
}

@MainActor
struct DirectAgentClient {
    var credential: () async throws -> String
    var mcpURL: URL
    var mcpKey: String
    var session: URLSession = PrivateHTTPClient.session
    var planUsage = false
    var endpoint = URL(string: "https://api.openai.com/v1/responses")!

    func run(
        prompt: String,
        history: [[String: String]],
        model: String,
        instructions: String,
        phoneID: String,
        emit: (AgentChat.Entry.Kind, String, NSImage?) -> Void,
        stream: (DirectAgentStreamEvent) -> Void
    ) async throws {
        let catalogue = try await mcp("tools/list", [:])
        let definitions = catalogue["tools"] as? [[String: Any]] ?? []
        let names = Set(definitions.compactMap { $0["name"] as? String })
        let functions = definitions.map { tool -> [String: Any] in
            ["type": "function", "name": tool["name"] ?? "", "description": tool["description"] ?? "",
             "parameters": tool["inputSchema"] ?? [:], "strict": false]
        }
        let anchor: [String: Any] = ["role": "user", "content": prompt]
        let historyGroups: [[[String: Any]]] = history.map { [$0] }
        var turnGroups: [[[String: Any]]] = []
        for _ in 0..<DirectAgentBudget.maxTurns {
            try Task.checkCancellation()
            var payload: [String: Any] = [
                "model": model,
                "instructions": instructions,
                "input": DirectAgentBudget.input(history: historyGroups, anchor: anchor, turns: turnGroups),
                "tools": planUsage ? [["type": "namespace", "name": "taplyne", "description": "Control only the selected phone.", "tools": functions]] : functions,
                "parallel_tool_calls": false,
                "store": false,
                "stream": true,
                "include": ["reasoning.encrypted_content"]
            ]
            if !planUsage { payload["max_output_tokens"] = DirectAgentBudget.byokMaxOutputTokens }
            let token = try await credential()
            let result = try await response(payload, key: token, stream: stream)
            let response = result.response
            guard response["status"] as? String == "completed", let output = response["output"] as? [[String: Any]] else {
                throw Failure("The model did not finish this turn. Inspect the device before continuing; no action was retried.")
            }
            var turn = output
            let calls = output.filter { $0["type"] as? String == "function_call" }
            if !result.streamedText {
                for message in output where message["type"] as? String == "message" {
                    for part in message["content"] as? [[String: Any]] ?? [] {
                        if let text = part["text"] as? String, !text.isEmpty { emit(.assistant, text, nil) }
                        if let refusal = part["refusal"] as? String, !refusal.isEmpty { emit(.assistant, refusal, nil) }
                    }
                }
            }
            if calls.isEmpty { return }
            for call in calls {
                try Task.checkCancellation()
                guard let rawName = call["name"] as? String,
                      let name = normalized(rawName, allowed: names),
                      let callID = call["call_id"] as? String,
                      let raw = call["arguments"] as? String,
                      var arguments = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                    throw Failure("The model returned an invalid tool call. No phone input was sent.")
                }
                if name != "list_phones" { arguments["phone_id"] = phoneID }
                emit(.tool, AgentChat.describeTool(name, arguments), nil)
                let value = try await mcp("tools/call", ["name": name, "arguments": arguments])
                let parts = value["content"] as? [[String: Any]] ?? []
                let text = DirectAgentBudget.toolOutput(parts.compactMap { $0["text"] as? String }.joined(separator: "\n"))
                turn.append(["type": "function_call_output", "call_id": callID, "output": text])
                if value["isError"] as? Bool == true { emit(.error, text.isEmpty ? "The phone action failed." : text, nil) }
                for part in parts where part["type"] as? String == "image" {
                    guard let encoded = part["data"] as? String, let mime = part["mimeType"] as? String,
                          let bytes = Data(base64Encoded: encoded) else { continue }
                    if let image = NSImage(data: bytes) { emit(.image, "", image) }
                    guard let bounded = DirectAgentBudget.boundedImage(bytes, mime: mime) else {
                        turn.append(["role": "user", "content": "A screenshot was returned but exceeded Taplyne's local image budget. Capture a new screen before using coordinates."])
                        continue
                    }
                    turn.append(["role": "user", "content": [["type": "input_image",
                        "image_url": "data:\(bounded.mime);base64,\(bounded.data.base64EncodedString())"]]])
                }
            }
            turnGroups.append(turn)
        }
        throw Failure("The run reached its local turn limit. Review progress before continuing; Taplyne did not replay any action.")
    }

    private func normalized(_ raw: String, allowed: Set<String>) -> String? {
        if allowed.contains(raw) { return raw }
        if raw.hasPrefix("taplyne."), let last = raw.split(separator: ".").last, allowed.contains(String(last)) { return String(last) }
        return nil
    }

    private func response(
        _ payload: [String: Any], key: String, stream notify: (DirectAgentStreamEvent) -> Void
    ) async throws -> (response: [String: Any], streamedText: Bool) {
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (bytes, urlResponse) = try await session.bytes(for: request)
        guard let http = urlResponse as? HTTPURLResponse else { throw Failure("OpenAI returned an invalid network response.") }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                if data.count >= 65_536 { break }
                data.append(byte)
            }
            throw Self.httpFailure(status: http.statusCode, data: data, planUsage: planUsage)
        }
        var parser = ResponseStreamParser(planUsage: planUsage)
        var streamed = false
        func handle(_ event: ResponseStreamEvent) -> [String: Any]? {
            switch event {
            case let .delta(text):
                streamed = true
                notify(.delta(text))
                return nil
            case let .completed(response):
                if streamed { notify(.completed) }
                return response
            }
        }
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                for event in try parser.consume(byte) {
                    if let response = handle(event) { return (response, streamed) }
                }
            }
            for event in try parser.finish() {
                if let response = handle(event) { return (response, streamed) }
            }
            throw Failure("OpenAI disconnected before completing the turn. Inspect the device before continuing; no action was retried.")
        } catch {
            if streamed { notify(.cancelled) }
            throw error
        }
    }

    private func mcp(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let value = try await post(mcpURL, key: mcpKey, payload: ["jsonrpc": "2.0", "id": UUID().uuidString,
            "method": method, "params": params])
        guard let result = value["result"] as? [String: Any] else { throw Failure("Taplyne rejected the phone tool request. Inspect the device before retrying.") }
        return result
    }
    private func post(_ url: URL, key: String, payload: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure("Taplyne's local phone service rejected the request. Inspect the device before retrying; no action was replayed.")
        }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure("The local phone service returned an invalid response.") }
        return value
    }

    static func httpFailure(status: Int, data: Data, planUsage: Bool) -> Failure {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let nested = object?["error"] as? [String: Any]
        let code = nested?["code"] as? String
        switch code {
        case "subscription_sharing_user_not_eligible":
            return Failure("ChatGPT plan usage is unavailable for this account or workspace. Choose another account or use your own OpenAI API key.")
        case "subscription_sharing_usage_limit_exceeded":
            return Failure("This ChatGPT account reached an app or shared plan limit. Review ChatGPT Settings → Usage, then resume later. No phone action was retried.")
        case "subscription_sharing_usage_unavailable":
            return Failure("ChatGPT could not check plan usage. Resume later after inspecting the device; no phone action was retried.")
        case "subscription_sharing_unsupported_capability":
            return Failure("The selected ChatGPT model does not support part of this request. Choose another eligible model; no phone action was retried.")
        case "subscription_sharing_route_not_supported":
            return Failure("ChatGPT plan routing rejected this request. Reconnect the account or use your own API key.")
        default: break
        }
        switch status {
        case 401:
            return Failure(planUsage ? "The selected ChatGPT session expired or was revoked. Reconnect that account in Settings." : "OpenAI rejected your API key. Validate or replace it in Settings.")
        case 403:
            return Failure(planUsage ? "ChatGPT plan usage is unavailable for the selected account, workspace, or region." : "OpenAI denied this request. Check the key's project permissions and selected model.")
        case 429:
            return Failure(planUsage ? "The selected ChatGPT account reached a usage limit. Review ChatGPT Settings → Usage before resuming." : "The OpenAI project reached a rate, token, or spend limit. Review project limits before resuming; no phone action was retried.")
        case 500...599:
            return Failure("OpenAI is temporarily unavailable. Inspect the device before resuming; no phone action was retried.")
        default:
            let detail = nested?["message"] as? String ?? object?["detail"] as? String
            return Failure(detail.map { "OpenAI rejected the request (HTTP \(status)): \(String($0.prefix(500)))" }
                ?? "OpenAI rejected the request (HTTP \(status)). No phone action was retried.")
        }
    }

    struct Failure: LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

enum ResponseStreamEvent { case delta(String), completed([String: Any]) }

@MainActor
struct ResponseStreamParser {
    private static let maximumEventBytes = 16_000_000
    private var line = Data()
    private var dataLines: [String] = []
    private var dataBytes = 0
    private var pendingCarriageReturn = false
    let planUsage: Bool
    init(planUsage: Bool = true) { self.planUsage = planUsage }

    mutating func consume(_ byte: UInt8) throws -> [ResponseStreamEvent] {
        var events: [ResponseStreamEvent] = []
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            events += try finishLine()
            if byte == 0x0A { return events }
        }
        switch byte {
        case 0x0A:
            events += try finishLine()
        case 0x0D:
            pendingCarriageReturn = true
        default:
            line.append(byte)
            guard line.count <= Self.maximumEventBytes else { throw tooLarge() }
        }
        return events
    }

    mutating func consume(_ bytes: Data) throws -> [ResponseStreamEvent] {
        var events: [ResponseStreamEvent] = []
        for byte in bytes { events += try consume(byte) }
        return events
    }

    mutating func finish() throws -> [ResponseStreamEvent] {
        var events: [ResponseStreamEvent] = []
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            events += try finishLine()
        } else if !line.isEmpty {
            events += try finishLine()
        }
        if !dataLines.isEmpty, let event = try finishEvent() { events.append(event) }
        return events
    }

    private mutating func finishLine() throws -> [ResponseStreamEvent] {
        guard let value = String(data: line, encoding: .utf8) else {
            throw DirectAgentClient.Failure("OpenAI returned an invalid streaming response.")
        }
        line.removeAll(keepingCapacity: true)
        guard !value.isEmpty else {
            guard let event = try finishEvent() else { return [] }
            return [event]
        }
        guard value.hasPrefix("data:") else { return [] }
        var data = value.dropFirst(5)
        if data.first == " " { data = data.dropFirst() }
        let string = String(data)
        dataBytes += string.utf8.count + 1
        guard dataBytes <= Self.maximumEventBytes else { throw tooLarge() }
        dataLines.append(string)
        return []
    }

    private mutating func finishEvent() throws -> ResponseStreamEvent? {
        guard !dataLines.isEmpty else { return nil }
        let data = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        dataBytes = 0
        if data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return nil }
        guard let event = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
            throw DirectAgentClient.Failure("OpenAI returned an invalid streaming response.")
        }
        switch event["type"] as? String {
        case "response.output_text.delta":
            guard let delta = event["delta"] as? String else { throw DirectAgentClient.Failure("OpenAI returned an invalid text update.") }
            return .delta(delta)
        case "response.completed":
            guard let response = event["response"] as? [String: Any], response["status"] as? String == "completed" else {
                throw DirectAgentClient.Failure("OpenAI ended the response without completing it. No phone action was retried.")
            }
            return .completed(response)
        case "response.failed", "response.incomplete", "error":
            let response = event["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any] ?? event["error"] as? [String: Any]
            let code = error?["code"] as? String
            let body = try? JSONSerialization.data(withJSONObject: ["error": error ?? [:]])
            throw DirectAgentClient.httpFailure(status: code?.contains("limit") == true ? 429 : 400, data: body ?? Data(), planUsage: planUsage)
        default:
            return nil
        }
    }

    private func tooLarge() -> DirectAgentClient.Failure {
        DirectAgentClient.Failure("OpenAI's response exceeded Taplyne's local limit.")
    }
}
