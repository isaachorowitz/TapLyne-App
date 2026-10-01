import AppKit
import Foundation
import CryptoKit
import os
import TaplyneServer

/// The built-in agent: Claude Code in headless mode, connected only to Taplyne's
/// own MCP server, with no file or shell tools. It uses the Claude login already
/// on this Mac, so there is no API key to manage.
@MainActor
final class AgentChat: ObservableObject {
    struct Entry: Identifiable {
        enum Kind: String { case user, assistant, tool, image, status, error }
        var id = UUID()
        let kind: Kind
        var text: String
        var image: NSImage?
    }

    @Published private(set) var entries: [Entry] = []
    @Published var running = false
    @Published var paused = false
    var phoneID: () -> String? = { nil }
    var activePhoneID: String?
    var prepareInput: (String?) -> Bool = { _ in true }
    var onResumeReady: (String?) -> Void = { _ in }
    var cancelInput: (String?, PhoneControlCommand) -> Void = { _, _ in }
    private var pendingResume = false
    private var stopping = false
    private var expectedTerminations: Set<ObjectIdentifier> = []

    var mcpURL: () -> URL? = { nil }
    var apiKey: () -> String = { "" }
    var phoneContext: () -> String = { "" }
    var model: () -> String? = { nil }
    var executableURL: () -> URL? = { AgentChat.claudeExecutable }
    var workDirectoryOverride: URL?

    var store = ConversationStore.standard
    private(set) var deviceID: String?
    private var historyAvailable = true
    private var commands: [ConversationStore.AcceptedCommand] = []
    @Published private(set) var workflows: [ConversationStore.Workflow] = []
    @Published private(set) var workflowRuns: [ConversationStore.WorkflowRun] = []
    private var activeWorkflow: UUID?
    var onAssistantText: (String) -> Void = { _ in }
    var provider: () -> String = { "claude" }
    var providerKey: () -> String = { "" }
    var directTask: Task<Void, Never>?
    private var streamingAssistantID: UUID?
    var voiceLeaseID: UUID?
    private var pendingVoiceLeaseID: UUID?
    var pendingPrompt: String?
    var sessionID: UUID?
    private var process: Process?
    private var lineBuffer = Data()
    private let log = Logger(subsystem: "agency.ziplyne.taplyne", category: "agent")

    static var claudeExecutable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    private static var workDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Taplyne/agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func selectDevice(_ id: String) {
        guard deviceID != id, !running, !paused else { return }
        persist()
        deviceID = id
        let saved: ConversationStore.Snapshot
        do { saved = try store.load(id); historyAvailable = true }
        catch {
            historyAvailable = false
            entries = [Entry(kind: .error, text: "Saved history could not be decrypted or read. It has been preserved. Start a new conversation only if you want to replace it.")]
            sessionID = nil; workflows = []; workflowRuns = []; commands = []
            return
        }
        commands = saved.commands ?? []
        entries = saved.messages.compactMap { message in
            guard let kind = Entry.Kind(rawValue: message.kind) else { return nil }
            return Entry(id: message.id, kind: kind, text: message.text)
        }
        sessionID = saved.sessionID
        workflows = saved.workflows
        workflowRuns = (saved.workflowRuns ?? []).map { run in
            var run = run
            if run.status == "Running" { run.status = "Interrupted"; run.result = "The app closed during this run. Inspect the device before continuing." }
            return run
        }
        if saved.wasRunning { append(.status, "The previous run was interrupted. Inspect the device before continuing; no action has been replayed.") }
    }

    func runWorkflow(_ workflow: ConversationStore.Workflow, values: [String: String]) throws {
        guard !running, !paused else { throw ConversationStore.Workflow.WorkflowFailure() }
        let prompt = try workflow.rendered(values)
        let run = ConversationStore.WorkflowRun(workflowID: workflow.id, name: workflow.name, status: "Running", result: "")
        workflowRuns.append(run); workflowRuns = Array(workflowRuns.suffix(100)); activeWorkflow = run.id
        send(prompt)
        if !running { finishWorkflow() }
    }

    func finishWorkflow() {
        guard let id = activeWorkflow, let index = workflowRuns.firstIndex(where: { $0.id == id }) else { return }
        workflowRuns[index].status = paused ? "Paused" : "Finished"
        workflowRuns[index].result = String((entries.last(where: { [.assistant, .error, .status].contains($0.kind) })?.text ?? "Inspect the device to verify the result.").prefix(4000))
        activeWorkflow = nil
        persist()
    }

    func saveWorkflow(name: String, prompt: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty, prompt.count <= 16000, workflows.count < 100 else { return }
        workflows.append(.init(name: String(name.prefix(100)), prompt: prompt))
        persist()
    }

    func deleteWorkflow(_ id: UUID) { workflows.removeAll { $0.id == id }; persist() }

    private func snapshot() -> ConversationStore.Snapshot {
        ConversationStore.Snapshot(messages: entries.filter { $0.kind != .image && $0.id != streamingAssistantID }.suffix(1000).map {
            .init(id: $0.id, kind: $0.kind.rawValue, text: $0.text)
        }, sessionID: sessionID, wasRunning: running, workflows: workflows, workflowRuns: workflowRuns, commands: commands)
    }

    func persist() {
        guard let deviceID, historyAvailable else { return }
        do { try store.save(snapshot(), deviceID: deviceID) }
        catch { log.error("Conversation could not be saved") }
    }

    /// Persist acceptance before executing. The latest 1,000 command IDs survive restarts.
    func accept(_ command: ConversationCommand) throws -> Bool {
        guard let deviceID, historyAvailable else { throw PhoneServiceError.failed("Conversation storage is unavailable.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = Data(SHA256.hash(data: try encoder.encode(command)))
        if let previous = commands.first(where: { $0.id == command.id }) {
            guard previous.fingerprint == fingerprint else { throw PhoneServiceError.invalidArgument("A command ID cannot be reused with different content.") }
            return false
        }
        let previous = commands
        commands.append(.init(id: command.id, fingerprint: fingerprint))
        if commands.count > 1000 { commands.removeFirst(commands.count - 1000) }
        do { try store.save(snapshot(), deviceID: deviceID) }
        catch { commands = previous; throw error }
        return true
    }

    /// Interrupt first, cancel queued input, then restart from fresh screen evidence.
    func steer(_ text: String, leaseID: UUID? = nil) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= 16000 else { return }
        guard running || paused else { send(prompt, leaseID: leaseID); return }
        voiceLeaseID = leaseID; pendingVoiceLeaseID = leaseID
        pendingPrompt = prompt
        cancelInput(activePhoneID, .pause)
        paused = true
        terminateForControlChange()
        if !running { continuePending() }
    }

    func continuePending() {
        guard let prompt = pendingPrompt else { return }
        pendingPrompt = nil
        let lease = pendingVoiceLeaseID; pendingVoiceLeaseID = nil
        onResumeReady(activePhoneID)
        paused = false
        send("The user changed the task. Inspect the current screen; all previous coordinates are invalid. Check completed actions and never repeat an uncertain send or submission. New instruction: " + prompt, leaseID: lease)
    }

    func reset() {
        stop()
        historyAvailable = true
        entries.removeAll()
        sessionID = nil
        persist()
    }

    func stop() {
        guard running || paused else { return }
        stopping = true
        defer { stopping = false }
        paused = false
        pendingResume = false
        pendingPrompt = nil
        if running { cancelInput(activePhoneID, .stop) }
        terminateForControlChange()
        append(.status, "Stopped. You can continue in this conversation.")
    }

    func pauseForControlChange() {
        guard running, !stopping, !paused else { return }
        paused = true
        terminateForControlChange()
        append(.status, "Paused for manual control. Resume will inspect the current screen before continuing.")
    }

    private func terminateForControlChange() {
        directTask?.cancel()
        guard let process, process.isRunning else { return }
        expectedTerminations.insert(ObjectIdentifier(process))
        process.terminate()
    }

    func finishPendingResume() { if pendingResume { resume() } }

    func resume() {
        guard paused else { return }
        if running { pendingResume = true; return }
        onResumeReady(activePhoneID)
        paused = false
        pendingResume = false
        send("Continue the previous request from the current screen. Describe the phone again; all previous frame references and coordinates are invalid. Check what is already complete before taking more input, and never repeat a possibly completed send, purchase or submission.")
    }

    func send(_ text: String, leaseID: UUID? = nil) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= 16000, !running, historyAvailable else { return }
        voiceLeaseID = leaseID
        if provider() == "openai" || provider() == "chatgpt" { sendDirect(prompt); return }
        guard let claude = executableURL() else {
            append(.error, "Claude Code is not installed. Install it from claude.ai/code, then try again.")
            return
        }
        guard let url = mcpURL() else {
            append(.error, "Taplyne's server is not running. Turn it on in Settings.")
            return
        }
        activePhoneID = deviceID ?? phoneID()
        guard prepareInput(activePhoneID) else {
            append(.error, "Automation is paused or under manual control. Press Resume on the phone before starting the agent.")
            return
        }
        paused = false
        append(.user, prompt)

        let scope = SHA256.hash(data: Data((deviceID ?? "unselected").utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = workDirectoryOverride ?? Self.workDirectory.appendingPathComponent(scope, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { append(.error, "Could not create the agent workspace."); return }
        let configURL = directory.appendingPathComponent("mcp.json")
        let config: [String: Any] = ["mcpServers": ["taplyne": [
            "type": "http", "url": url.absoluteString, "headers": ["X-API-Key": apiKey()]
        ]]]
        do {
            let data = try JSONSerialization.data(withJSONObject: config)
            try data.write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        } catch {
            append(.error, "Could not write the agent's MCP config: \(error.localizedDescription)")
            return
        }

        let context = entries.filter { $0.kind == .user || $0.kind == .assistant }.dropLast().suffix(30)
            .map { "\($0.kind.rawValue): \($0.text)" }.joined(separator: "\n")
        let effectivePrompt = context.isEmpty ? prompt : "Previous conversation for context only:\n" + context + "\n\nCurrent request:\n" + prompt
        var arguments = [
            "-p", effectivePrompt, "--no-session-persistence",
            "--output-format", "stream-json", "--verbose",
            "--strict-mcp-config", "--mcp-config", configURL.path,
            "--allowedTools", "mcp__taplyne",
            "--tools", "",
            "--setting-sources", "project,local",
            "--append-system-prompt", Self.instructions + "\n\n" + phoneContext()
        ]
        if let model = model(), !model.isEmpty { arguments += ["--model", model] }


        let process = Process()
        process.executableURL = claude
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        lineBuffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.consume(chunk) }
        }
        let errorText = LockedText()
        err.fileHandleForReading.readabilityHandler = { handle in
            errorText.append(handle.availableData)
        }
        process.terminationHandler = { [weak self] finished in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            Task { @MainActor in
                guard let self, self.process === finished else { return }
                let expected = self.expectedTerminations.remove(ObjectIdentifier(finished)) != nil
                self.running = false
                self.process = nil
                if status != 0, reason == .exit, !expected {
                    let tail = errorText.value.split(separator: "\n").suffix(3).joined(separator: "\n")
                    self.append(.error, tail.isEmpty ? "Claude Code exited with status \(status)." : tail)
                }
                self.finishWorkflow()
                self.persist()
                if self.pendingPrompt != nil { self.continuePending() }
                else if self.pendingResume { self.resume() }
            }
        }
        do {
            try process.run()
            self.process = process
            running = true
            persist()
        } catch {
            append(.error, "Could not start Claude Code: \(error.localizedDescription)")
        }
    }

    // MARK: - Stream parsing

    private func consume(_ chunk: Data) {
        lineBuffer.append(chunk)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex ..< newline]
            lineBuffer = Data(lineBuffer[lineBuffer.index(after: newline)...])
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(event)
        }
    }

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "assistant":
            for block in content(of: event) {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty { append(.assistant, text) }
                case "tool_use":
                    append(.tool, Self.describeTool(block["name"] as? String ?? "", block["input"] as? [String: Any] ?? [:]))
                default:
                    break
                }
            }
        case "user":
            for block in content(of: event) where block["type"] as? String == "tool_result" {
                let parts = block["content"] as? [[String: Any]] ?? []
                if block["is_error"] as? Bool == true {
                    let text = Self.toolResultText(block)
                    append(.error, text.isEmpty ? "The action failed." : text)
                }
                for part in parts where part["type"] as? String == "image" {
                    if let source = part["source"] as? [String: Any],
                       let base64 = source["data"] as? String,
                       let data = Data(base64Encoded: base64),
                       let image = NSImage(data: data) {
                        append(.image, "", image: image)
                    }
                }
            }
        case "result":
            if event["is_error"] as? Bool == true {
                append(.error, event["result"] as? String ?? "The agent stopped with an error.")
            }
        default:
            break
        }
    }

    static func toolResultText(_ block: [String: Any]) -> String {
        if let text = block["content"] as? String { return text }
        return (block["content"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }.joined(separator: " ")
    }

    private func content(of event: [String: Any]) -> [[String: Any]] {
        ((event["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
    }

    func append(_ kind: Entry.Kind, _ text: String, image: NSImage? = nil) {
        entries.append(Entry(kind: kind, text: text, image: image))
        persist()
        if kind == .assistant { onAssistantText(text) }
    }

    /// Streaming prose is visible immediately, but remains transient until the
    /// Responses API sends response.completed. Cancelled text is neither saved
    /// nor spoken as a completed assistant reply.
    func appendAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let id = streamingAssistantID, let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].text += delta
        } else {
            let entry = Entry(kind: .assistant, text: delta)
            streamingAssistantID = entry.id
            entries.append(entry)
        }
    }

    func finishAssistantStream() {
        guard let id = streamingAssistantID else { return }
        streamingAssistantID = nil
        guard let text = entries.first(where: { $0.id == id })?.text, !text.isEmpty else {
            entries.removeAll { $0.id == id }
            return
        }
        persist()
        onAssistantText(text)
    }

    func cancelAssistantStream() {
        guard let id = streamingAssistantID else { return }
        streamingAssistantID = nil
        entries.removeAll { $0.id == id }
    }


}

/// Collects a child's stderr from the pipe's reader thread.
private final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var value: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

#if DEBUG
extension AgentChat {
    /// Fills the thread with a sample run for UI review.
    func seedPreview(running: Bool) {
        let shot = NSImage(size: NSSize(width: 330, height: 717), flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.17, green: 0.23, blue: 0.40, alpha: 1),
                                NSColor(red: 0.69, green: 0.34, blue: 0.48, alpha: 1)])?.draw(in: rect, angle: -70)
            return true
        }
        entries = [
            Entry(kind: .user, text: "Open X and scroll my feed"),
            Entry(kind: .tool, text: "Home"),
            Entry(kind: .tool, text: "Screenshot"),
            Entry(kind: .image, text: "", image: shot),
            Entry(kind: .tool, text: "Tap at 379, 486"),
            Entry(kind: .assistant, text: "X is open on your **For You** feed. Scrolling now."),
            Entry(kind: .tool, text: "Flick up from 310, 900"),
            Entry(kind: .tool, text: "Screenshot"),
            Entry(kind: .image, text: "", image: shot),
        ]
        self.running = running
    }
}
#endif
