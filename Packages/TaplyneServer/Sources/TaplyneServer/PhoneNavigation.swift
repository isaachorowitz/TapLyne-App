import Foundation

public enum NavigationCommand: String, Codable, Sendable, CaseIterable {
    case home, back
    case appSwitcher = "app_switcher"
    case dismissKeyboard = "dismiss_keyboard"
    case notifications
    case controlCenter = "control_center"
}

public struct FormField: Sendable {
    public var label: String
    public var text: String
    public init(label: String, text: String) { self.label = label; self.text = text }
}

public extension PhoneAutomation {
    func navigate(phoneID: String, command: NavigationCommand, expectation: ActionExpectation = ActionExpectation()) async throws -> ObservedAction {
        let screen = try await observe(phoneID: phoneID)
        return try await act(phoneID: phoneID, action: .navigate(command), frameID: screen.screen.frameID, expectation: expectation)
    }

    /// OCR labels do not prove native focus. Require visible evidence in the intended row before writing.
    func fillField(phoneID: String, text: String, label: String? = nil, elementID: String? = nil,
                   frameID: String) async throws -> ObservedAction {
        guard label != nil || elementID != nil else {
            return try await act(phoneID: phoneID, action: .setText(text: text), frameID: frameID)
        }
        let before = try await observation(frameID, phoneID: phoneID)
        let target: ScreenElement
        if let elementID {
            guard let element = before.screen.elements.first(where: { $0.id == elementID }) else {
                throw PhoneServiceError.invalidArgument("element_id does not belong to frame_id")
            }
            target = element
        } else { target = try before.screen.uniqueMatch(label!) }
        var result = try await tapLabel(phoneID: phoneID, label: label, elementID: elementID, frameID: frameID)
        do {
            let row = target.bounds.cgRect.insetBy(dx: -20, dy: -35)
            let focusRegion = CGRect(x: 0, y: row.minY, width: CGFloat(before.screen.width), height: row.height)
            let sameLabel = result.screen.matches(target.text).filter { abs($0.bounds.y - target.bounds.y) < 15 }
            let neighbours = before.screen.elements.filter {
                $0.id != target.id && abs($0.bounds.y - target.bounds.y) < 35
            }
            // Two labels sharing a row are ambiguous; a stable label and a visible field change
            // outside the AssistiveTouch circle are needed. A keyboard appearing alone is insufficient.
            guard sameLabel.count == 1, neighbours.isEmpty,
                  ScreenComparison.regionChanged(before.reference.image.image, result.image.image,
                      region: focusRegion, ignoring: [CGPoint(x: row.midX, y: row.midY)]) else {
                result.verification = Verification(.unverified, method: "field_focus", detail: "The intended field's focus could not be established. No text was pasted. Focus it manually, describe the screen, then call fill_field with only text and frame_id.")
                return result
            }
            let typed = try await act(phoneID: phoneID, action: .setText(text: text), frameID: result.screen.frameID)
            result = typed; result.completedSteps = 2
            let visibleValue = !text.isEmpty && result.screen.elements.contains {
                abs($0.bounds.y - target.bounds.y) < 60 && ScreenDescription.normalized($0.text).contains(ScreenDescription.normalized(text))
            }
            if result.verification.status == .verified && !visibleValue {
                result.verification = Verification(.unverified, method: "field_row", detail: "Clipboard readback matched, but the value could not be located in the intended row. Inspect the field before continuing.")
            }
            return result
        } catch { throw InputFailure(error, delivery: .delivered, completedSteps: 1) }
    }

    /// Resolve each label on the latest screen, stop on uncertainty, and never submit the form.
    func fillForm(phoneID: String, fields: [FormField]) async throws -> ObservedAction {
        guard !fields.isEmpty, fields.count <= 20,
              fields.allSatisfy({ !$0.label.isEmpty && $0.label.count <= 200 && $0.text.count <= 1000 }) else {
            throw PhoneServiceError.invalidArgument("Provide 1 to 20 fields with a label and at most 1000 characters per value.")
        }
        let generation = try await service.controlState(phoneID: phoneID).generation
        var result = try await observe(phoneID: phoneID)
        var completed = 0
        do {
            for field in fields {
                try await checkGeneration(phoneID, generation)
                result = try await fillField(phoneID: phoneID, text: field.text, label: field.label, frameID: result.screen.frameID)
                guard result.verification.status == .verified else { result.completedSteps += completed; return result }
                completed += result.completedSteps
            }
            result.completedSteps = completed
            // A final observation must still contain each requested value near its own label.
            let stillVisible = fields.allSatisfy { field in
                guard let label = try? result.screen.uniqueMatch(field.label), !field.text.isEmpty else { return false }
                return result.screen.elements.contains { abs($0.bounds.y - label.bounds.y) < 60 &&
                    ScreenDescription.normalized($0.text).contains(ScreenDescription.normalized(field.text)) }
            }
            result.verification = Verification(stillVisible ? .verified : .unverified, method: "form_field_readback",
                detail: stillVisible ? "Each field matched exact readback and its value remains visible near its label. The form was not submitted." : "Field readbacks matched, but final values are not all visible. Inspect the form; it was not submitted.")
            return result
        } catch { throw InputFailure(error, delivery: completed > 0 ? .delivered : .notDelivered, completedSteps: completed) }
    }

    /// Opens an app through the visible Home Screen or Spotlight, preserving the USB + HID transport.
    func openApp(phoneID: String, name: String, expectation: ActionExpectation = ActionExpectation()) async throws -> ObservedAction {
        guard !name.isEmpty, name.count <= 100 else { throw PhoneServiceError.invalidArgument("App name must be 1 to 100 characters.") }
        let generation = try await service.controlState(phoneID: phoneID).generation
        var completed = 0
        do {
        var result = try await navigate(phoneID: phoneID, command: .home)
        completed += 1
        result = try await settledNavigationScreen(phoneID, generation: generation)
        try await checkGeneration(phoneID, generation)
        if result.screen.matches(name).count == 1 {
            return try await tapLabel(phoneID: phoneID, label: name, frameID: result.screen.frameID, expectation: expectation)
        }
        let searches = result.screen.elements.filter {
            ["q search", "search"].contains(ScreenDescription.normalized($0.text)) &&
                $0.bounds.y > Double(result.screen.height) * 0.7
        }
        if searches.count == 1 {
            result = try await tapLabel(phoneID: phoneID, elementID: searches[0].id, frameID: result.screen.frameID)
        } else {
            result = try await act(phoneID: phoneID,
                               action: .flick(x: result.screen.width / 2, y: result.screen.height / 3, direction: .down),
                               frameID: result.screen.frameID)
        }
        completed += 1
        result = try await settledNavigationScreen(phoneID, generation: generation)
        try await checkGeneration(phoneID, generation)
        result = try await act(phoneID: phoneID, action: .setText(text: name), frameID: result.screen.frameID,
                               expectation: ActionExpectation(textPresent: name, screenChanged: true))
        completed += 1
        guard result.verification.status == .verified else { result.completedSteps = completed; return result }
        result = try await settledNavigationScreen(phoneID, generation: generation)
        try await checkGeneration(phoneID, generation)
        // Duplicate app names or search echoes deliberately require an explicit element choice.
        // Spotlight echoes the query at the top. Only a unique app result below
        // that search field can be selected automatically.
        let apps = result.screen.matches(name).filter { $0.bounds.y > Double(result.screen.height) * 0.15 }
        guard apps.count == 1 else {
            result.verification = Verification(.unverified, method: "app_result", detail: "The search did not identify one app result. Inspect the screen and choose an element; no result was tapped.")
            result.completedSteps = completed
            return result
        }
        var opened = try await tapLabel(phoneID: phoneID, elementID: apps[0].id, frameID: result.screen.frameID, expectation: expectation)
        opened.completedSteps += completed
        return opened
        } catch { throw InputFailure(error, delivery: completed > 0 ? .delivered : .notDelivered, completedSteps: completed) }
    }

    private func settledNavigationScreen(_ phoneID: String, generation: UInt64) async throws -> ObservedAction {
        let deadline = Date().addingTimeInterval(3)
        var previous = try await service.screenshot(phoneID: phoneID)
        var stable = 0
        repeat {
            try await Task.sleep(for: .milliseconds(200))
            try await checkGeneration(phoneID, generation)
            let current = try await service.screenshot(phoneID: phoneID)
            guard current.capturedAt > previous.capturedAt, Date().timeIntervalSince(current.capturedAt) <= 1 else { continue }
            stable = ScreenComparison.changed(previous.image, current.image) ? 0 : stable + 1
            if stable >= 2 { return try await observe(phoneID: phoneID) }
            previous = current
        } while Date() < deadline
        throw PhoneServiceError.failed("SCREEN_MOVING: The navigation transition did not settle. Observe before continuing.")
    }
}
