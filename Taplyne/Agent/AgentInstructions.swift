import Foundation

@MainActor
extension AgentChat {
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
