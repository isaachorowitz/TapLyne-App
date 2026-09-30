import AppKit
import Foundation
import os
import TaplyneServer

/// The built-in agent: Claude Code in headless mode, connected only to Taplyne's
/// own MCP server, with no file or shell tools. It uses the Claude login already
/// on this Mac, so there is no API key to manage.
@MainActor
final class AgentChat: ObservableObject {
    struct Entry: Identifiable {
        enum Kind { case user, assistant, tool, image, status, error }
        let id = UUID()
        let kind: Kind
        var text: String
        var image: NSImage?
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var running = false
    @Published private(set) var paused = false
    var phoneID: () -> String? = { nil }
    private(set) var activePhoneID: String?
    var prepareInput: (String?) -> Bool = { _ in true }
    var onResumeReady: (String?) -> Void = { _ in }
    var cancelInput: (String?, PhoneControlCommand) -> Void = { _, _ in }
    private var pendingResume = false
    private var stopping = false

    var mcpURL: () -> URL? = { nil }
    var apiKey: () -> String = { "" }
    var phoneContext: () -> String = { "" }
    var model: () -> String? = { nil }

    private var sessionID: UUID?
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

    func reset() {
        stop()
        entries.removeAll()
        sessionID = nil
    }

    func stop() {
        guard running || paused else { return }
        stopping = true
        defer { stopping = false }
        paused = false
        pendingResume = false
        if running { cancelInput(activePhoneID, .stop) }
        process?.terminate()
        append(.status, "Stopped. You can continue in this conversation.")
    }

    func pauseForControlChange() {
        guard running, !stopping else { return }
        paused = true
        process?.terminate()
        append(.status, "Paused for manual control. Resume will inspect the current screen before continuing.")
    }

    func resume() {
        guard paused else { return }
        if process?.isRunning == true { pendingResume = true; return }
        onResumeReady(activePhoneID)
        paused = false
        pendingResume = false
        send("Continue the previous request from the current screen. Describe the phone again; all previous frame references and coordinates are invalid. Check what is already complete before taking more input, and never repeat a possibly completed send, purchase or submission.")
    }

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !running else { return }
        guard let claude = Self.claudeExecutable else {
            append(.error, "Claude Code is not installed. Install it from claude.ai/code, then try again.")
            return
        }
        guard let url = mcpURL() else {
            append(.error, "Taplyne's server is not running. Turn it on in Settings.")
            return
        }
        activePhoneID = phoneID()
        guard prepareInput(activePhoneID) else {
            append(.error, "Automation is paused or under manual control. Press Resume on the phone before starting the agent.")
            return
        }
        paused = false
        append(.user, prompt)

        let configURL = Self.workDirectory.appendingPathComponent("mcp.json")
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

        var arguments = [
            "-p", prompt,
            "--output-format", "stream-json", "--verbose",
            "--strict-mcp-config", "--mcp-config", configURL.path,
            "--allowedTools", "mcp__taplyne",
            "--tools", "",
            "--setting-sources", "project,local",
            "--append-system-prompt", Self.instructions + "\n\n" + phoneContext()
        ]
        if let model = model(), !model.isEmpty { arguments += ["--model", model] }
        if let sessionID {
            arguments += ["--resume", sessionID.uuidString.lowercased()]
        } else {
            let id = UUID()
            sessionID = id
            arguments += ["--session-id", id.uuidString.lowercased()]
        }

        let process = Process()
        process.executableURL = claude
        process.arguments = arguments
        process.currentDirectoryURL = Self.workDirectory
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
                self.running = false
                self.process = nil
                if status != 0, reason == .exit {
                    let tail = errorText.value.split(separator: "\n").suffix(3).joined(separator: "\n")
                    self.append(.error, tail.isEmpty ? "Claude Code exited with status \(status)." : tail)
                }
                if self.pendingResume { self.resume() }
            }
        }
        do {
            try process.run()
            self.process = process
            running = true
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
                    let text = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
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

    private func content(of event: [String: Any]) -> [[String: Any]] {
        ((event["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
    }

    private func append(_ kind: Entry.Kind, _ text: String, image: NSImage? = nil) {
        entries.append(Entry(kind: kind, text: text, image: image))
    }

    static func describeTool(_ name: String, _ input: [String: Any]) -> String {
        let tool = name.replacingOccurrences(of: "mcp__taplyne__", with: "")
        func n(_ key: String) -> String { (input[key] as? NSNumber)?.stringValue ?? "?" }
        switch tool {
        case "tap", "double_tap", "triple_tap": return "\(tool.replacingOccurrences(of: "_", with: " ").capitalized) at \(n("x")), \(n("y"))"
        case "long_press": return "Long press at \(n("x")), \(n("y"))"
        case "flick": return "Flick \(input["direction"] as? String ?? "") from \(n("x")), \(n("y"))"
        case "drag", "hold_and_drag": return "\(tool == "drag" ? "Drag" : "Hold and drag") \(n("from_x")), \(n("from_y")) → \(n("to_x")), \(n("to_y"))"
        case "type_text": return "Type \((input["text"] as? String ?? "").count) characters"
        case "press_key": return "Press \(input["key"] as? String ?? "")"
        case "press_home": return "Home"
        case "screenshot": return "Screenshot"
        case "describe_screen": return "Describe screen"
        case "tap_label": return "Tap label \(input["label"] as? String ?? "selected element")"
        case "scroll_to_item": return "Scroll to \(input["label"] as? String ?? "item")"
        case "fill_field": return "Fill field"
        case "fill_form": return "Fill form"
        case "navigate": return "Navigate \(input["command"] as? String ?? "")"
        case "open_app": return "Open \(input["name"] as? String ?? "app")"
        case "wait_for_text": return "Wait for text"
        case "list_phones": return "List phones"
        case "list_apps": return "List apps"
        default: return tool
        }
    }

    static let instructions = """
    You are Taplyne's built-in agent. You operate a real, physical iPhone through the taplyne MCP tools.
    Work in a loop: describe_screen, decide one next action, act with the current frame_id, then inspect its returned screenshot and verification.
    Coordinates are pixels in the most recent screenshot image. Aim for the center of what you tap.
    describe_screen provides local OCR labels and bounds, not a native accessibility tree. Prefer tap_label, scroll_to_item and wait_for_text. Duplicate labels require element_id. Coordinates require the current frame_id and cannot be reused after input.
    Supply expect.text_present, expect.text_absent or expect.screen_changed to verify an intended result. A changed screen alone does not prove the task succeeded. Failed or unverified input must not be replayed automatically.
    Use fill_field or fill_form for replacement text and exact Unicode readback. Universal Clipboard needs Handoff and the same Apple Account. If readback is unavailable, inspect the field and ask for help instead of pasting again. Never submit a form implicitly.
    Use navigate and open_app for navigation. A back gesture can fail in an app; inspect its result.
    On pause, takeover, stale frames or changed control, stop input. Resume begins with describe_screen and checks what is already done.
    The small gray circle that appears after a tap is the AssistiveTouch pointer; ignore it.
    To open an app: press_home, look for its icon, or flick left to the App Library and search for it.
    Text: tap the field, type_text, and inspect exact fragment readback and the returned screen. fill_field verifies a whole replacement value.
    Safety: stop before sending a message, posting, purchasing, deleting, or submitting anything unless the user explicitly asked for that exact action. Never type a password the user did not give you. If a task needs the user (Face ID, a passcode, a decision), say so and stop.
    Keep replies short: say what you did and what you saw.
    """
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
