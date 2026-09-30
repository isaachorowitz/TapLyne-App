import Foundation

/// Validates REST action bodies into `PhoneAction`s.
enum ActionParser {
    static let names: Set<String> = [
        "tap", "double-tap", "triple-tap", "tap-and-hold", "flick", "drag", "hold-and-drag",
        "type", "keypress", "home",
    ]
    static let maxTextLength = 1000

    static func body(_ r: HTTPRequest) throws(APIError) -> [String: Any] {
        if r.body.isEmpty { return [:] }
        guard let object = JSON.object(r.body) as? [String: Any] else {
            throw .invalid("body", "must be a JSON object")
        }
        return object
    }

    static func parse(name: String, body: [String: Any], phone: PhoneRecord) throws(APIError) -> PhoneAction {
        switch name {
        case "tap": return .tap(x: try x(body, "x", phone), y: try y(body, "y", phone))
        case "double-tap": return .doubleTap(x: try x(body, "x", phone), y: try y(body, "y", phone))
        case "triple-tap": return .tripleTap(x: try x(body, "x", phone), y: try y(body, "y", phone))
        case "tap-and-hold":
            return .tapAndHold(
                x: try x(body, "x", phone), y: try y(body, "y", phone),
                durationMs: try int(body, "duration_ms", default: 1000, range: 1...10000))
        case "flick":
            return .flick(
                x: try x(body, "x", phone), y: try y(body, "y", phone),
                direction: try enumValue(body, "direction", default: nil))
        case "drag":
            return .drag(
                fromX: try x(body, "from_x", phone), fromY: try y(body, "from_y", phone),
                toX: try x(body, "to_x", phone), toY: try y(body, "to_y", phone),
                speed: try enumValue(body, "speed", default: Speed.medium))
        case "hold-and-drag":
            return .holdAndDrag(
                fromX: try x(body, "from_x", phone), fromY: try y(body, "from_y", phone),
                toX: try x(body, "to_x", phone), toY: try y(body, "to_y", phone),
                holdDurationMs: try int(body, "hold_duration_ms", default: 500, range: 1...10000),
                speed: try enumValue(body, "speed", default: Speed.medium))
        case "type":
            guard let text = body["text"] as? String, !text.isEmpty else {
                throw .invalid("text", "is required and must be a non-empty string")
            }
            guard text.count <= maxTextLength else {
                throw .invalid("text", "must be at most \(maxTextLength) characters")
            }
            return .type(text: text)
        case "keypress":
            let key: KeyName = try enumValue(body, "key", default: nil)
            var modifiers: [Modifier] = []
            if let raw = body["modifiers"], !(raw is NSNull) {
                guard let list = raw as? [Any] else { throw .invalid("modifiers", "must be an array") }
                for item in list {
                    guard let s = item as? String, let m = Modifier(rawValue: s) else {
                        throw .invalid("modifiers", "must contain only \(Modifier.allCases.map(\.rawValue).joined(separator: ", "))")
                    }
                    modifiers.append(m)
                }
            }
            return .keypress(key: key, modifiers: modifiers, repeatCount: try int(body, "repeat", default: 1, range: 1...50))
        default:
            return .home
        }
    }

    private static func number(_ body: [String: Any], _ field: String) throws(APIError) -> Int? {
        guard let raw = body[field], !(raw is NSNull) else { return nil }
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
            n.doubleValue == n.doubleValue.rounded(), abs(n.doubleValue) < 1e9
        else { throw .invalid(field, "must be an integer") }
        return n.intValue
    }

    private static func int(_ body: [String: Any], _ field: String, default def: Int, range: ClosedRange<Int>) throws(APIError) -> Int {
        guard let n = try number(body, field) else { return def }
        guard range.contains(n) else { throw .invalid(field, "must be between \(range.lowerBound) and \(range.upperBound)") }
        return n
    }

    private static func x(_ body: [String: Any], _ field: String, _ phone: PhoneRecord) throws(APIError) -> Int {
        try coordinate(body, field, limit: phone.width)
    }

    private static func y(_ body: [String: Any], _ field: String, _ phone: PhoneRecord) throws(APIError) -> Int {
        try coordinate(body, field, limit: phone.height)
    }

    private static func coordinate(_ body: [String: Any], _ field: String, limit: Int?) throws(APIError) -> Int {
        guard let n = try number(body, field) else { throw .invalid(field, "is required") }
        guard n >= 0 else { throw .invalid(field, "must not be negative") }
        if let limit, n >= limit { throw .invalid(field, "must be less than the screen size (\(limit))") }
        return n
    }

    private static func enumValue<E: RawRepresentable & CaseIterable>(
        _ body: [String: Any], _ field: String, default def: E?
    ) throws(APIError) -> E where E.RawValue == String {
        guard let raw = body[field], !(raw is NSNull) else {
            if let def { return def }
            throw .invalid(field, "is required")
        }
        guard let s = raw as? String, let value = E(rawValue: s) else {
            throw .invalid(field, "must be one of \(E.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return value
    }
}
