import Foundation

enum ToolCatalogue {
    nonisolated(unsafe) static let definitions: [[String: Any]] = {
        let phone: (String, [String: Any]) = ("phone_id", ["type": "string", "description": "Phone id from list_phones."])
        let frame: (String, [String: Any]) = ("frame_id", ["type": "string", "description": "Current frame_id from describe_screen, screenshot, or the last action. Consumed by input."])
        let expect: (String, [String: Any]) = ("expect", ["type": "object", "additionalProperties": false,
            "properties": ["text_present": ["type": "string", "minLength": 1], "text_absent": ["type": "string", "minLength": 1], "screen_changed": ["type": "boolean"]]])
        func string(_ name: String, _ description: String, limit: Int = 200) -> (String, [String: Any]) {
            (name, ["type": "string", "minLength": 1, "maxLength": limit, "description": description])
        }
        func choice(_ name: String, _ values: [String]) -> (String, [String: Any]) { (name, ["type": "string", "enum": values]) }
        func integer(_ name: String, _ min: Int, _ max: Int) -> (String, [String: Any]) { (name, ["type": "integer", "minimum": min, "maximum": max]) }
        func px(_ name: String) -> (String, [String: Any]) { (name, ["type": "number", "minimum": 0, "description": "Pixels in the referenced screenshot, top-left origin."]) }
        func tool(_ name: String, _ description: String, _ props: [(String, [String: Any])], _ required: [String]) -> [String: Any] {
            ["name": name, "description": description, "inputSchema": ["type": "object", "properties": Dictionary(uniqueKeysWithValues: props), "required": required, "additionalProperties": false]]
        }
        let point = [phone, frame, px("x"), px("y"), expect]
        let drag = [phone, frame, px("from_x"), px("from_y"), px("to_x"), px("to_y"), choice("speed", Speed.allCases.map(\.rawValue)), expect]
        let label = string("label", "Visible text or field placeholder. Duplicate matches require element_id.")
        let exact: (String, [String: Any]) = ("exact", ["type": "boolean", "description": "Exact label match, default true."])
        let text = string("text", "Complete Unicode text. Pasted once without Enter or implicit submission.", limit: 1000)
        return [
            tool("list_phones", "List phones, ids, sizes and readiness. Call first.", [], []),
            tool("get_phone_status", "Get readiness and pause/manual control state.", [phone], ["phone_id"]),
            tool("screenshot", "Observe the screen and return an image, frame_id, local OCR elements and warnings. Coordinates use this image's pixels.", [phone], ["phone_id"]),
            tool("describe_screen", "Describe visible English and Hebrew text using local OCR. This is not the native accessibility tree. Returns screenshot and frame_id.", [phone], ["phone_id"]),
            tool("tap", "Tap a point in the current referenced image. Returns fresh evidence and verification; supply expect for the intended result.", point, ["phone_id", "frame_id", "x", "y"]),
            tool("double_tap", "Double tap a referenced point.", point, ["phone_id", "frame_id", "x", "y"]),
            tool("triple_tap", "Triple tap a referenced point.", point, ["phone_id", "frame_id", "x", "y"]),
            tool("long_press", "Hold a referenced point. Default duration 1000 milliseconds.", point + [integer("duration", 1, 10000)], ["phone_id", "frame_id", "x", "y"]),
            tool("flick", "Swipe from a referenced point. Direction describes finger motion.", point + [choice("direction", Direction.allCases.map(\.rawValue))], ["phone_id", "frame_id", "x", "y", "direction"]),
            tool("drag", "Drag between referenced points. Default speed medium.", drag, ["phone_id", "frame_id", "from_x", "from_y", "to_x", "to_y"]),
            tool("hold_and_drag", "Hold then drag between referenced points. Default hold 500 milliseconds.", drag + [integer("hold_duration_ms", 1, 10000)], ["phone_id", "frame_id", "from_x", "from_y", "to_x", "to_y"]),
            tool("type_text", "Insert Unicode in the focused field. Uses Universal Clipboard and exact fragment readback when available. Requires Handoff and the same Apple Account. Never repeats an uncertain paste.", [phone, frame, text, expect], ["phone_id", "frame_id", "text"]),
            tool("press_key", "Press a key; Enter can submit, so use only with explicit user intent.", [phone, frame, choice("key", KeyName.allCases.map(\.rawValue)), ("modifiers", ["type": "array", "items": ["type": "string", "enum": Modifier.allCases.map(\.rawValue)]]), integer("repeat", 1, 50), expect], ["phone_id", "frame_id", "key"]),
            tool("press_home", "Go Home and return fresh evidence. Supply expect to verify the resulting screen.", [phone, expect], ["phone_id"]),
            tool("list_apps", "List installed app names and bundle ids.", [phone, ("refresh", ["type": "boolean"])], ["phone_id"]),
            tool("tap_label", "Tap one uniquely matched visible label, or a specific element_id from the current frame. Rejects ambiguity.", [phone, frame, label, string("element_id", "Element id from this frame."), exact, expect], ["phone_id", "frame_id"]),
            tool("scroll_to_item", "Scroll until a unique label is visible, with a bounded limit and no tap. Default finger direction up, maximum 6 scrolls.", [phone, label, exact, choice("direction", Direction.allCases.map(\.rawValue)), integer("max_scrolls", 1, 12)], ["phone_id", "label"]),
            tool("wait_for_text", "Wait for a visible text condition without input. Default timeout 5 seconds, present true.", [phone, text, ("present", ["type": "boolean"]), ("timeout", ["type": "number", "minimum": 0.1, "maximum": 20])], ["phone_id", "text"]),
            tool("fill_field", "Replace a focused field, or tap its label/element first. Exact Unicode readback is required for verified status. Does not submit.", [phone, frame, label, string("element_id", "Field element id from this frame."), ("text", ["type": "string", "maxLength": 1000])], ["phone_id", "frame_id", "text"]),
            tool("fill_form", "Fill 1 to 20 uniquely labelled visible fields. Stops at the first uncertain readback. Never submits.", [phone, ("fields", ["type": "array", "minItems": 1, "maxItems": 20, "items": ["type": "object", "additionalProperties": false, "required": ["label", "text"], "properties": ["label": ["type": "string", "minLength": 1, "maxLength": 200], "text": ["type": "string", "maxLength": 1000]]]])], ["phone_id", "fields"]),
            tool("navigate", "Home, back gesture, app switcher, dismiss keyboard, notifications or Control Center. Results vary by app; supply expect to verify.", [phone, choice("command", NavigationCommand.allCases.map(\.rawValue)), expect], ["phone_id", "command"]),
            tool("open_app", "Open an app by its visible name on Home or Spotlight. Rejects duplicate labels and stops when text entry is uncertain. Supply expect for app-specific confirmation.", [phone, string("name", "Installed app display name.", limit: 100), expect], ["phone_id", "name"]),
            tool("control_phone", "Pause or stop automatic input. Only the person at the Mac can resume or leave manual takeover.", [phone, choice("command", ["pause", "stop"])], ["phone_id", "command"]),
        ]
    }()
}
