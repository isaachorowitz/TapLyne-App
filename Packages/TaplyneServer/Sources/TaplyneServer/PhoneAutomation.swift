import Foundation

/// The shared observe, act, verify contract used by MCP, REST and the Mac UI.
public final class PhoneAutomation: Sendable {
    public typealias Recognizer = @Sendable (ScreenImage) async throws -> ScreenDescription
    let service: any PhoneService
    private let observer = ScreenObserver()
    private let recognize: Recognizer

    public init(service: any PhoneService, recognize: @escaping Recognizer = { try await ScreenRecognition.describe($0) }) {
        self.service = service; self.recognize = recognize
    }

    public func observe(phoneID: String) async throws -> ObservedAction {
        try Task.checkCancellation()
        let state = try await service.controlState(phoneID: phoneID)
        let image = try await freshImage(phoneID: phoneID)
        let screen = ScreenTapTarget.annotate(try await recognize(image), image: image.image)
        guard state == (try await service.controlState(phoneID: phoneID)) else {
            throw PhoneServiceError.failed("CONTROL_CHANGED: Input occurred while describing the screen. Observe again.")
        }
        await observer.save(.init(phoneID: phoneID, screen: screen, reference: ActionReference(image: image, control: state)))
        return ObservedAction(screen: screen, image: image,
                              verification: Verification(.unverified, method: "observation", detail: "Current screen observation; no input delivered."), inputDelivered: false)
    }

    func observation(_ frameID: String, phoneID: String) async throws -> ScreenObserver.Observation {
        try await observer.reference(frameID, phoneID: phoneID)
    }

    public func act(phoneID: String, action: PhoneAction, frameID: String? = nil,
                    expectation: ActionExpectation = ActionExpectation()) async throws -> ObservedAction {
        try Task.checkCancellation()
        let observation: ScreenObserver.Observation
        if let frameID { observation = try await observer.reference(frameID, phoneID: phoneID) }
        else {
            guard !action.requiresFrameReference else {
                throw PhoneServiceError.invalidArgument("frame_id is required for coordinate input. Call describe_screen or screenshot first.")
            }
            let current = try await observe(phoneID: phoneID)
            observation = try await observer.reference(current.screen.frameID, phoneID: phoneID)
        }
        let receipt: InputReceipt
        do {
            receipt = try await service.performObserved(phoneID: phoneID, action: action, reference: observation.reference)
        } catch {
            await observer.invalidate(phoneID)
            throw error
        }
        await observer.invalidate(phoneID)
        do {
            let completed = Date()
            var result = try await observeAfter(phoneID, after: completed)
            try await checkGeneration(phoneID, observation.reference.control.generation)
            let deadline = Date().addingTimeInterval(3)
            repeat {
                result.verification = ActionVerification.evaluate(expectation, before: observation.reference.image,
                    after: result.image, description: result.screen, receipt: receipt, beforeDescription: observation.screen)
                if expectation.isEmpty || result.verification.status != .failed || Date() >= deadline { break }
                try await Task.sleep(for: .milliseconds(200))
                result = try await observeAfter(phoneID, after: result.image.capturedAt)
                try await checkGeneration(phoneID, observation.reference.control.generation)
            } while true
            result.inputDelivered = true; result.completedSteps = 1
            return result
        } catch {
            throw InputFailure(error, delivery: .delivered, completedSteps: 1)
        }
    }

    public func tapLabel(phoneID: String, label: String? = nil, elementID: String? = nil, frameID: String,
                         exact: Bool = true, expectation: ActionExpectation = ActionExpectation()) async throws -> ObservedAction {
        let observation = try await observer.reference(frameID, phoneID: phoneID)
        let element: ScreenElement
        if let elementID {
            guard let found = observation.screen.elements.first(where: { $0.id == elementID }), found.confidence >= 0.45 else {
                throw PhoneServiceError.invalidArgument("element_id must be a confident element from this frame.")
            }
            element = found
        } else if let label { element = try observation.screen.uniqueMatch(label, exact: exact) }
        else { throw PhoneServiceError.invalidArgument("Provide label or element_id.") }
        let target = (element.tapTarget ?? element.bounds).cgRect
        return try await act(phoneID: phoneID, action: .tap(x: Int(target.midX), y: Int(target.midY)),
                             frameID: frameID, expectation: expectation)
    }

    public func scrollTo(phoneID: String, label: String, direction: Direction = .up, maxScrolls: Int = 6,
                         exact: Bool = true) async throws -> ObservedAction {
        guard (1...12).contains(maxScrolls), !label.isEmpty else { throw PhoneServiceError.invalidArgument("Provide a label and max_scrolls between 1 and 12.") }
        let generation = try await service.controlState(phoneID: phoneID).generation
        var result = try await observe(phoneID: phoneID)
        var stagnant = 0
        var completed = 0
        do {
        for step in 0...maxScrolls {
            try await checkGeneration(phoneID, generation)
            let matches = result.screen.matches(label, exact: exact)
            if !matches.isEmpty {
                _ = try result.screen.uniqueMatch(label, exact: exact)
                result.verification = Verification(.verified, method: "label_visible", detail: "The requested item is visible. It has not been tapped.")
                result.completedSteps = completed; result.inputDelivered = completed > 0
                return result
            }
            if step == maxScrolls || stagnant >= 2 { break }
            let before = result
            result = try await act(phoneID: phoneID,
                                   action: .flick(x: result.screen.width / 2, y: Int(Double(result.screen.height) * 0.65), direction: direction),
                                   frameID: result.screen.frameID)
            completed += 1
            stagnant = ScreenComparison.changed(before.image.image, result.image.image) ? 0 : stagnant + 1
        }
        result.verification = Verification(.failed, method: "bounded_scroll", detail: "Item was not found before the scroll limit or end of content. No item was tapped.")
        result.completedSteps = completed
        return result
        } catch { throw InputFailure(error, delivery: completed > 0 ? .delivered : .notDelivered, completedSteps: completed) }
    }

    public func waitFor(phoneID: String, text: String, present: Bool = true, timeout: Double = 5) async throws -> ObservedAction {
        guard (0.1...20).contains(timeout), !text.isEmpty else { throw PhoneServiceError.invalidArgument("Provide text and a timeout between 0.1 and 20 seconds.") }
        let deadline = Date().addingTimeInterval(timeout)
        var result = try await observe(phoneID: phoneID)
        while true {
            try Task.checkCancellation()
            let found = ScreenDescription.normalized(result.screen.text).contains(ScreenDescription.normalized(text))
            if found == present && result.screen.canVerifyText(text) {
                result.verification = Verification(.verified, method: "wait_for_text", detail: "The requested text condition is visible.")
                return result
            }
            if Date() >= deadline { break }
            try await Task.sleep(for: .milliseconds(250))
            result = try await observe(phoneID: phoneID)
        }
        result.verification = Verification(.failed, method: "wait_for_text", detail: "The text condition was not established before the deadline.")
        return result
    }

    private func observeAfter(_ phoneID: String, after: Date) async throws -> ObservedAction {
        _ = try await freshImage(phoneID: phoneID, after: after)
        return try await observe(phoneID: phoneID)
    }

    private func freshImage(phoneID: String, after: Date = .distantPast) async throws -> ScreenImage {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            try Task.checkCancellation()
            let image = try await service.screenshot(phoneID: phoneID)
            if image.capturedAt > after && Date().timeIntervalSince(image.capturedAt) <= 1 { return image }
            try await Task.sleep(for: .milliseconds(40))
        } while Date() < deadline
        throw PhoneServiceError.failed("CAPTURE_STALE: No fresh frame arrived. Input will not be repeated.")
    }

    func checkGeneration(_ phoneID: String, _ generation: UInt64) async throws {
        try Task.checkCancellation()
        let state = try await service.controlState(phoneID: phoneID)
        guard state.generation == generation, state.mode == .automatic else {
            throw PhoneServiceError.failed("CONTROL_CHANGED: Navigation stopped for pause or manual takeover.")
        }
    }
}
