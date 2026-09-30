import Foundation

struct InvalidParams: Error { var message: String }

/// The MCP tool catalogue and its execution.
final class MCPTools: Sendable {
    let controller: PhoneController
    static let maxImageEdge = 1344

    init(controller: PhoneController) { self.controller = controller }

    nonisolated(unsafe) static let definitions = ToolCatalogue.definitions
    static let names: Set<String> = Set(definitions.compactMap { $0["name"] as? String })

    // MARK: Execution

    /// Failure means invalid params (-32602); tool problems come back as a result with `isError`.
    func call(_ name: String, _ args: [String: Any]) async -> Result<[String: Any], InvalidParams> {
        do {
            if name == "list_phones" { return .success(text(await listPhones())) }
            let id = try string(args, "phone_id")
            switch name {
            case "get_phone_status": return .success(await guarded { try await self.status(id) })
            case "screenshot", "describe_screen": return .success(await guarded { try await self.screenshot(id) })
            case "control_phone":
                let command: PhoneControlCommand = try enumValue(args, "command", nil)
                guard command == .pause || command == .stop else { throw InvalidParams(message: "Only the person at the Mac can resume or take over. Remote control supports pause and stop.") }
                return .success(await guarded {
                    let state = try await self.controller.service.control(phoneID: id, command: command)
                    return self.text(JSON.string(state.json))
                })
            case "tap_label", "scroll_to_item", "wait_for_text", "fill_field", "fill_form", "navigate", "open_app":
                let command = try AutomationRequest.parse(name, args)
                return .success(await guarded {
                    let result = await self.controller.run(phoneID: id, serialized: name != "wait_for_text", deadline: command.deadlineBudget) {
                        try await command.run(self.controller.automation, phoneID: id)
                    }
                    return try self.observed(result.get())
                })
            case "list_apps":
                let refresh = try optionalBool(args, "refresh") ?? false
                return .success(await guarded { try await self.apps(id, refresh: refresh) })
            default:
                let request = try parse(name, args)
                let frame = try AutomationRequest.optionalString(args, "frame_id")
                let expectation = try AutomationRequest.expectation(args)
                return .success(await guarded { try await self.act(id, request, frameID: frame, expectation: expectation) })
            }
        } catch let e as InvalidParams {
            return .failure(e)
        } catch {
            return .failure(InvalidParams(message: "\(error)"))
        }
    }

    private struct Request: Sendable {
        var build: @Sendable (_ scaleX: Double, _ scaleY: Double, _ width: Int, _ height: Int) throws -> PhoneAction
    }

    private func parse(_ name: String, _ a: [String: Any]) throws -> Request {
        switch name {
        case "tap", "double_tap", "triple_tap", "long_press":
            let x = try number(a, "x"), y = try number(a, "y")
            let duration = try optionalInt(a, "duration", 1...10000) ?? 1000
            return Request { sx, sy, w, h in
                let px = try Self.native(x, sx, w), py = try Self.native(y, sy, h)
                switch name {
                case "tap": return .tap(x: px, y: py)
                case "double_tap": return .doubleTap(x: px, y: py)
                case "triple_tap": return .tripleTap(x: px, y: py)
                default: return .tapAndHold(x: px, y: py, durationMs: duration)
                }
            }
        case "flick":
            let x = try number(a, "x"), y = try number(a, "y")
            let d: Direction = try enumValue(a, "direction", nil)
            return Request { sx, sy, w, h in .flick(x: try Self.native(x, sx, w), y: try Self.native(y, sy, h), direction: d) }
        case "drag", "hold_and_drag":
            let fx = try number(a, "from_x"), fy = try number(a, "from_y")
            let tx = try number(a, "to_x"), ty = try number(a, "to_y")
            let speed: Speed = try enumValue(a, "speed", .medium)
            let hold = try optionalInt(a, "hold_duration_ms", 1...10000) ?? 500
            return Request { sx, sy, w, h in
                let (a1, b1, a2, b2) = (try Self.native(fx, sx, w), try Self.native(fy, sy, h), try Self.native(tx, sx, w), try Self.native(ty, sy, h))
                return name == "drag"
                    ? .drag(fromX: a1, fromY: b1, toX: a2, toY: b2, speed: speed)
                    : .holdAndDrag(fromX: a1, fromY: b1, toX: a2, toY: b2, holdDurationMs: hold, speed: speed)
            }
        case "type_text":
            let text = try string(a, "text")
            guard !text.isEmpty, text.count <= 1000 else { throw InvalidParams(message: "text must be 1 to 1000 characters") }
            return Request { _, _, _, _ in .type(text: text) }
        case "press_key":
            let key: KeyName = try enumValue(a, "key", nil)
            var mods: [Modifier] = []
            if let raw = a["modifiers"], !(raw is NSNull) {
                guard let list = raw as? [Any] else { throw InvalidParams(message: "modifiers must be an array") }
                for item in list {
                    guard let s = item as? String, let m = Modifier(rawValue: s) else {
                        throw InvalidParams(message: "modifiers must contain only \(Modifier.allCases.map(\.rawValue).joined(separator: ", "))")
                    }
                    mods.append(m)
                }
            }
            let count = try optionalInt(a, "repeat", 1...50) ?? 1
            let finalMods = mods
            return Request { _, _, _, _ in .keypress(key: key, modifiers: finalMods, repeatCount: count) }
        case "press_home": return Request { _, _, _, _ in .home }
        default: throw InvalidParams(message: "Unknown tool: \(name)")
        }
    }

    /// Screenshot-image pixels to native pixels; reject coordinates outside the referenced image.
    static func native(_ v: Double, _ scale: Double, _ limit: Int) throws -> Int {
        guard v.isFinite, v >= 0, v * scale < Double(limit), v * scale < 1e8 else {
            throw PhoneServiceError.invalidArgument("Coordinates must lie inside the referenced screenshot.")
        }
        return min(Int((v * scale).rounded()), limit - 1)
    }

    /// Native long edge divided by the long edge of the image the agent sees.
    static func scale(width: Int, height: Int) -> Double {
        let long = max(width, height)
        return Double(long) / Double(min(long, maxImageEdge))
    }

    private struct ToolFailure: Error { var message: String }

    private func guarded(_ body: @escaping () async throws -> [String: Any]) async -> [String: Any] {
        do { return try await body() } catch {
            var out = text(Self.plain(error), isError: true)
            let delivery = (error as? InputFailure) ?? (error as? JobFailure)?.delivery
            out["structuredContent"] = delivery?.json ?? InputFailure(error, delivery: .notDelivered).json
            return out
        }
    }

    static func plain(_ error: Error) -> String {
        if let f = error as? InputFailure { return "\(f.message) Delivery: \(f.delivery.rawValue). Observe before continuing; do not replay input." }
        if let f = error as? JobFailure, let delivery = f.delivery { return plain(delivery) }
        if let f = error as? ToolFailure { return f.message }
        if let f = error as? JobFailure, let e = f.underlying { return plain(e) }
        if let f = error as? JobFailure { return f.message }
        guard let e = error as? PhoneServiceError else { return "\(error)" }
        switch e {
        case .phoneNotFound(let id): return "No phone with id \(id). Call list_phones to see valid ids."
        case .phoneNotReady(let r): return "The phone is not ready: \(r)"
        case .invalidArgument(let m): return "Invalid argument: \(m)"
        case .timeout: return "The phone did not respond in time. Observe its current state before any further input."
        case .failed(let m): return m
        }
    }

    private func text(_ s: String, isError: Bool = false) -> [String: Any] {
        var out: [String: Any] = ["content": [["type": "text", "text": s]]]
        if isError { out["isError"] = true }
        return out
    }

    private func phoneLine(_ p: PhoneRecord) -> [String: Any] {
        var d: [String: Any] = ["id": p.id, "name": p.displayName ?? p.name, "connection_status": p.connectionStatus.rawValue]
        if let w = p.width, let h = p.height {
            d["width"] = w; d["height"] = h
            let fit = ImageEncoding.fittedSize(width: w, height: h, maxLongEdge: Self.maxImageEdge)
            d["screenshot_size"] = "\(fit.width)x\(fit.height)"
        }
        if let r = p.statusReason { d["status_reason"] = r }
        if let m = p.model { d["model"] = m }
        return d
    }

    private func listPhones() async -> String {
        let phones = await controller.service.listPhones()
        return String(data: JSON.data(phones.map(phoneLine)), encoding: .utf8) ?? "[]"
    }

    private func status(_ id: String) async throws -> [String: Any] {
        let p = try await lookup(id)
        var json = phoneLine(p)
        json["control"] = try await controller.service.controlState(phoneID: id).json
        return text(JSON.string(json))
    }

    private func lookup(_ id: String) async throws -> PhoneRecord {
        guard let p = await controller.service.listPhones().first(where: { $0.id == id }) else {
            throw PhoneServiceError.phoneNotFound(id)
        }
        return p
    }

    private func screenshot(_ id: String) async throws -> [String: Any] {
        _ = try await lookup(id)
        let result = await controller.run(phoneID: id, serialized: false) {
            try await self.controller.automation.observe(phoneID: id)
        }
        return try observed(result.get())
    }

    private func observed(_ result: ObservedAction) throws -> [String: Any] {
        guard let jpeg = ImageEncoding.jpegFitting(result.image.image, maxLongEdge: Self.maxImageEdge, quality: 0.8) else {
            throw InputFailure(PhoneServiceError.failed("Could not encode the screen evidence."), delivery: result.inputDelivered ? .delivered : .notDelivered, completedSteps: result.completedSteps)
        }
        let json = result.json(maxEdge: Self.maxImageEdge)
        var out: [String: Any] = [
            "content": [["type": "image", "data": jpeg.data.base64EncodedString(), "mimeType": "image/jpeg"],
                        ["type": "text", "text": JSON.string(json)]],
            "structuredContent": json,
        ]
        if result.verification.status == .failed { out["isError"] = true }
        return out
    }

    private func apps(_ id: String, refresh: Bool) async throws -> [String: Any] {
        _ = try await lookup(id)
        let list = try await controller.service.apps(phoneID: id, refresh: refresh)
        return text(String(data: JSON.data(list.apps.map { ["name": $0.name, "bundle_id": $0.bundleID] }), encoding: .utf8) ?? "[]")
    }

    private func act(_ id: String, _ request: Request, frameID: String?, expectation: ActionExpectation) async throws -> [String: Any] {
        let phone = try await lookup(id)
        guard phone.connectionStatus == .online else {
            throw PhoneServiceError.phoneNotReady(phone.statusReason ?? "Phone is \(phone.connectionStatus.rawValue)")
        }
        let automation = controller.automation
        let result = await controller.run(phoneID: id, serialized: true) {
            let w: Int, h: Int
            if let frameID {
                let reference = try await automation.observation(frameID, phoneID: id)
                w = reference.screen.width; h = reference.screen.height
            } else {
                w = phone.width ?? 0; h = phone.height ?? 0
            }
            guard w > 0, h > 0 else { throw PhoneServiceError.failed("Screen size is not available.") }
            let fit = ImageEncoding.fittedSize(width: w, height: h, maxLongEdge: Self.maxImageEdge)
            let action = try request.build(Double(w) / Double(fit.width), Double(h) / Double(fit.height), w, h)
            return try await automation.act(phoneID: id, action: action, frameID: frameID, expectation: expectation)
        }
        return try observed(result.get())
    }

    // MARK: Argument helpers

    private func string(_ a: [String: Any], _ k: String) throws -> String {
        guard let s = a[k] as? String else { throw InvalidParams(message: "\(k) is required and must be a string") }
        return s
    }

    private func number(_ a: [String: Any], _ k: String) throws -> Double {
        guard let n = a[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, abs(n.doubleValue) < 1e8 else {
            throw InvalidParams(message: "\(k) is required and must be a number")
        }
        return n.doubleValue
    }

    private func optionalInt(_ a: [String: Any], _ k: String, _ range: ClosedRange<Int>) throws -> Int? {
        guard let raw = a[k], !(raw is NSNull) else { return nil }
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded(),
            range.contains(n.intValue)
        else { throw InvalidParams(message: "\(k) must be an integer between \(range.lowerBound) and \(range.upperBound)") }
        return n.intValue
    }

    private func optionalBool(_ a: [String: Any], _ k: String) throws -> Bool? {
        guard let raw = a[k], !(raw is NSNull) else { return nil }
        guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw InvalidParams(message: "\(k) must be a boolean") }
        return n.boolValue
    }

    private func enumValue<E: RawRepresentable & CaseIterable>(_ a: [String: Any], _ k: String, _ def: E?) throws -> E where E.RawValue == String {
        guard let raw = a[k], !(raw is NSNull) else {
            if let def { return def }
            throw InvalidParams(message: "\(k) is required")
        }
        guard let s = raw as? String, let v = E(rawValue: s) else {
            throw InvalidParams(message: "\(k) must be one of \(E.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return v
    }
}
