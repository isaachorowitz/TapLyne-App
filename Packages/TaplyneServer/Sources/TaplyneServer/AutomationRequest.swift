import CoreFoundation
import Foundation

/// Validated, Sendable requests shared by the REST and MCP boundaries.
enum AutomationRequest: Sendable {
    case tap(label: String?, element: String?, frame: String, exact: Bool, expect: ActionExpectation)
    case scroll(label: String, direction: Direction, count: Int, exact: Bool)
    case wait(text: String, present: Bool, timeout: Double)
    case field(text: String, label: String?, element: String?, frame: String?)
    case form([FormField])
    case navigate(NavigationCommand, ActionExpectation)
    case open(String, ActionExpectation)

    var deadlineBudget: Double {
        switch self {
        case let .form(fields): return Double(fields.count) * 25 + 10
        case let .scroll(_, _, count, _): return Double(count) * 15 + 10
        case .open: return 90
        default: return 60
        }
    }

    static let names: Set<String> = ["tap_label", "scroll_to_item", "wait_for_text", "fill_field", "fill_form", "navigate", "open_app"]

    static func parse(_ name: String, _ args: [String: Any]) throws -> AutomationRequest {
        switch name {
        case "tap_label":
            let label = try optionalString(args, "label"), element = try optionalString(args, "element_id")
            guard (label == nil) != (element == nil) else { throw InvalidParams(message: "Provide exactly one of label or element_id.") }
            return .tap(label: label, element: element, frame: try string(args, "frame_id"), exact: try bool(args, "exact", true), expect: try expectation(args))
        case "scroll_to_item":
            return .scroll(label: try string(args, "label"), direction: try choice(args, "direction", .up), count: try integer(args, "max_scrolls", 6, 1...12), exact: try bool(args, "exact", true))
        case "wait_for_text":
            let timeout = try number(args, "timeout", 5)
            guard (0.1...20).contains(timeout) else { throw InvalidParams(message: "timeout must be between 0.1 and 20 seconds.") }
            return .wait(text: try string(args, "text", max: 1000), present: try bool(args, "present", true), timeout: timeout)
        case "fill_field":
            let label = try optionalString(args, "label"), element = try optionalString(args, "element_id")
            let frame = try optionalString(args, "frame_id")
            guard label == nil || element == nil else { throw InvalidParams(message: "Provide label or element_id, not both.") }
            guard frame != nil else { throw InvalidParams(message: "frame_id is required for field replacement.") }
            return .field(text: try string(args, "text", max: 1000, allowEmpty: true), label: label, element: element, frame: frame)
        case "fill_form":
            guard let raw = args["fields"] as? [[String: Any]], (1...20).contains(raw.count) else {
                throw InvalidParams(message: "fields must contain 1 to 20 objects with label and text.")
            }
            return .form(try raw.map { field in
                guard Set(field.keys).isSubset(of: ["label", "text"]) else { throw InvalidParams(message: "Field keys must be label and text.") }
                return FormField(label: try string(field, "label"), text: try string(field, "text", max: 1000, allowEmpty: true))
            })
        case "navigate": return .navigate(try choice(args, "command", nil), try expectation(args))
        case "open_app": return .open(try string(args, "name", max: 100), try expectation(args))
        default: throw InvalidParams(message: "Unknown automation operation.")
        }
    }

    func run(_ automation: PhoneAutomation, phoneID: String) async throws -> ObservedAction {
        guard let phone = await automation.service.listPhones().first(where: { $0.id == phoneID }) else {
            throw PhoneServiceError.phoneNotFound(phoneID)
        }
        if case .wait = self {} else if phone.connectionStatus != .online {
            throw PhoneServiceError.phoneNotReady(phone.statusReason ?? "Phone is not online.")
        }
        switch self {
        case let .tap(label, element, frame, exact, expect):
            return try await automation.tapLabel(phoneID: phoneID, label: label, elementID: element, frameID: frame, exact: exact, expectation: expect)
        case let .scroll(label, direction, count, exact):
            return try await automation.scrollTo(phoneID: phoneID, label: label, direction: direction, maxScrolls: count, exact: exact)
        case let .wait(text, present, timeout):
            return try await automation.waitFor(phoneID: phoneID, text: text, present: present, timeout: timeout)
        case let .field(text, label, element, frame):
            guard let frame else { throw PhoneServiceError.invalidArgument("frame_id is required") }
            return try await automation.fillField(phoneID: phoneID, text: text, label: label, elementID: element, frameID: frame)
        case let .form(fields): return try await automation.fillForm(phoneID: phoneID, fields: fields)
        case let .navigate(command, expect): return try await automation.navigate(phoneID: phoneID, command: command, expectation: expect)
        case let .open(name, expect): return try await automation.openApp(phoneID: phoneID, name: name, expectation: expect)
        }
    }

    static func expectation(_ args: [String: Any]) throws -> ActionExpectation {
        guard let raw = args["expect"] else { return ActionExpectation() }
        guard let value = raw as? [String: Any], !value.isEmpty,
              Set(value.keys).isSubset(of: ["text_present", "text_absent", "screen_changed"]) else {
            throw InvalidParams(message: "expect must contain text_present, text_absent or screen_changed.")
        }
        let changed = value["screen_changed"] == nil ? nil : try bool(value, "screen_changed", false)
        return ActionExpectation(textPresent: try optionalString(value, "text_present"), textAbsent: try optionalString(value, "text_absent"), screenChanged: changed)
    }

    static func optionalString(_ args: [String: Any], _ key: String) throws -> String? {
        guard args[key] != nil else { return nil }
        return try string(args, key)
    }

    static func string(_ args: [String: Any], _ key: String, max: Int = 200, allowEmpty: Bool = false) throws -> String {
        guard let text = args[key] as? String, text.count <= max, allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InvalidParams(message: "\(key) must be a \(allowEmpty ? "" : "non-empty ")string of at most \(max) characters.")
        }
        return text
    }

    static func bool(_ args: [String: Any], _ key: String, _ fallback: Bool) throws -> Bool {
        guard let raw = args[key] else { return fallback }
        guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw InvalidParams(message: "\(key) must be a boolean.") }
        return n.boolValue
    }

    static func number(_ args: [String: Any], _ key: String, _ fallback: Double) throws -> Double {
        guard let raw = args[key] else { return fallback }
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw InvalidParams(message: "\(key) must be a number.") }
        return n.doubleValue
    }

    static func integer(_ args: [String: Any], _ key: String, _ fallback: Int, _ range: ClosedRange<Int>) throws -> Int {
        let value = try number(args, key, Double(fallback))
        guard value.rounded() == value, value >= Double(range.lowerBound), value <= Double(range.upperBound) else { throw InvalidParams(message: "\(key) must be an integer in \(range).") }
        return Int(value)
    }

    static func choice<E: RawRepresentable & CaseIterable>(_ args: [String: Any], _ key: String, _ fallback: E?) throws -> E where E.RawValue == String {
        if args[key] == nil, let fallback { return fallback }
        guard let raw = args[key] as? String, let value = E(rawValue: raw) else { throw InvalidParams(message: "\(key) must be one of \(E.allCases.map(\.rawValue).joined(separator: ", ")).") }
        return value
    }
}
