import CoreGraphics
import Foundation
import Testing

@testable import TaplyneServer

@Suite struct AutomationTests {
    let id = FakePhoneService.online

    private func automation(_ service: FakePhoneService, labels: [String] = ["Name", "Email"]) -> PhoneAutomation {
        PhoneAutomation(service: service) { image in
            ScreenDescription(frameID: UUID().uuidString, capturedAt: image.capturedAt, width: image.width, height: image.height,
                              elements: labels.enumerated().map { index, label in
                ScreenElement(id: "element-\(index)", text: label, confidence: 0.95,
                              bounds: CGRect(x: 100, y: 300 + index * 100, width: 150, height: 50))
            })
        }
    }

    @Test func consumedAndCrossPhoneReferencesRejectWithoutInput() async throws {
        let service = FakePhoneService(), automation = automation(service)
        let frame = try await automation.observe(phoneID: id).screen.frameID
        await #expect(throws: PhoneServiceError.self) {
            try await automation.act(phoneID: "another-phone", action: .tap(x: 100, y: 200), frameID: frame)
        }
        #expect(service.actions.isEmpty)
        _ = try await automation.act(phoneID: id, action: .tap(x: 100, y: 200), frameID: frame)
        await #expect(throws: PhoneServiceError.self) {
            try await automation.act(phoneID: id, action: .tap(x: 100, y: 200), frameID: frame)
        }
        #expect(service.actions.count == 1)
    }

    @Test func geometryAndControlChangesRejectInput() async throws {
        let service = FakePhoneService(), automation = automation(service)
        let frame = try await automation.observe(phoneID: id).screen.frameID
        service.setImage(FakePhoneService.makeImage(width: 2868, height: 1320))
        await #expect(throws: PhoneServiceError.self) {
            try await automation.act(phoneID: id, action: .tap(x: 20, y: 20), frameID: frame)
        }
        #expect(service.actions.isEmpty)
        let current = try await automation.observe(phoneID: id).screen.frameID
        _ = try await service.control(phoneID: id, command: .takeover)
        await #expect(throws: PhoneServiceError.self) {
            try await automation.act(phoneID: id, action: .tap(x: 20, y: 20), frameID: current)
        }
        _ = try await service.control(phoneID: id, command: .resume)
        await #expect(throws: PhoneServiceError.self) {
            try await automation.act(phoneID: id, action: .tap(x: 20, y: 20), frameID: current)
        }
        #expect(service.actions.isEmpty)
    }

    @Test func agedReferencesAndStaleCaptureReject() throws {
        let image = ScreenImage(image: FakePhoneService.makeImage(width: 200, height: 400), capturedAt: Date())
        let aged = ActionReference(image: image, control: PhoneControlState(), observedAt: Date().addingTimeInterval(-31))
        #expect(throws: PhoneServiceError.self) { try aged.validate(current: image, control: PhoneControlState()) }
        let current = ActionReference(image: image, control: PhoneControlState())
        let stale = ScreenImage(image: image.image, capturedAt: Date().addingTimeInterval(-2))
        #expect(throws: PhoneServiceError.self) { try current.validate(current: stale, control: PhoneControlState()) }
    }

    @Test func labelAmbiguityAndExactElementSelection() async throws {
        let service = FakePhoneService(), automation = automation(service, labels: ["Save", "Save"])
        let frame = try await automation.observe(phoneID: id)
        await #expect(throws: PhoneServiceError.self) {
            try await automation.tapLabel(phoneID: id, label: "save", frameID: frame.screen.frameID)
        }
        #expect(service.actions.isEmpty)
        _ = try await automation.tapLabel(phoneID: id, elementID: frame.screen.elements[1].id, frameID: frame.screen.frameID)
        #expect(service.actions == [.tap(x: 175, y: 425)])
    }

    @Test func missingFrameAndFailedExpectationDoNotReplay() async throws {
        let service = FakePhoneService(), automation = automation(service)
        await #expect(throws: PhoneServiceError.self) { try await automation.act(phoneID: id, action: .tap(x: 1, y: 1)) }
        let result = try await automation.act(phoneID: id, action: .home, expectation: ActionExpectation(textPresent: "Never present"))
        #expect(result.verification.status == .failed)
        #expect(service.actions == [.home])
        #expect(result.inputDelivered)
    }

    @Test func captureLossReportsDeliveredInput() async throws {
        let service = FakePhoneService(), automation = automation(service)
        service.captureFailsAfterInput = true
        do {
            _ = try await automation.act(phoneID: id, action: .home)
            Issue.record("Expected capture failure")
        } catch let failure as InputFailure { #expect(failure.delivery == .delivered); #expect(failure.completedSteps == 1) }
        #expect(service.actions == [.home])
    }

    @Test func scrollStopsAtEndAndVisibleItemDoesNotTap() async throws {
        let service = FakePhoneService(), automation = automation(service)
        let visible = try await automation.scrollTo(phoneID: id, label: "Name")
        #expect(visible.verification.status == .verified && !visible.inputDelivered)
        #expect(service.actions.isEmpty)
        let missing = try await automation.scrollTo(phoneID: id, label: "Absent", maxScrolls: 8)
        #expect(missing.verification.status == .failed)
        #expect(service.actions.count == 2)
        #expect(service.actions.allSatisfy { if case .flick = $0 { return true }; return false })
    }

    @Test func scrollingRespectsMaximumEvenWhenScreenChanges() async throws {
        let service = FakePhoneService()
        service.changeScreensAfterInput = true
        let automation = automation(service, labels: [])
        let result = try await automation.scrollTo(phoneID: id, label: "Absent", maxScrolls: 1)
        #expect(result.verification.status == .failed)
        #expect(service.actions.count == 1)
    }

    @Test func formStopsAtUncertainFieldAndDoesNotSubmit() async throws {
        let service = FakePhoneService(), automation = automation(service)
        let text = "English שלום 👨‍👩‍👧‍👦\nsecond line"
        let result = try await automation.fillForm(phoneID: id, fields: [FormField(label: "Name", text: text), FormField(label: "Email", text: "sample@example.invalid")])
        #expect(result.verification.status == .unverified)
        #expect(service.actions == [.tap(x: 175, y: 325)])
        service.textVerificationStatus = .verified
        let completed = try await automation.fillForm(phoneID: id, fields: [FormField(label: "Email", text: "")])
        #expect(completed.verification.status == .unverified)
        #expect(!service.actions.contains(.keypress(key: .enter, modifiers: [], repeatCount: 1)))
    }

    @Test func normalizedLabelsPreserveEmojiAndSupportHebrew() {
        #expect(ScreenDescription.normalized("\u{200F} שלום   עולם ") == "שלום עולם")
        #expect(ScreenDescription.normalized("Cafe\u{301}") == ScreenDescription.normalized("CAFÉ"))
        #expect(ScreenDescription.normalized("👨‍👩‍👧‍👦") == "👨‍👩‍👧‍👦")
    }

    @Test func verificationRequiresAConditionAndHonorsTextReadbackFailures() {
        let image = ScreenImage(image: FakePhoneService.makeImage(width: 200, height: 400), capturedAt: Date())
        let screen = ScreenDescription(frameID: "f", capturedAt: Date(), width: 200, height: 400,
                                       elements: [ScreenElement(text: "Done", confidence: 1, bounds: .zero)])
        let unverified = ActionVerification.evaluate(ActionExpectation(), before: image, after: image, description: screen, receipt: InputReceipt())
        #expect(unverified.status == .unverified)
        let verified = ActionVerification.evaluate(ActionExpectation(textPresent: "done", textAbsent: "waiting", screenChanged: false), before: image, after: image, description: screen, receipt: InputReceipt())
        #expect(verified.status == .verified)
        let failed = ActionVerification.evaluate(ActionExpectation(textPresent: "done"), before: image, after: image, description: screen,
                                                 receipt: InputReceipt(textVerification: Verification(.failed, method: "readback", detail: "mismatch")))
        #expect(failed.status == .failed)
    }

    @Test func requestValidationRejectsCoercedTypes() {
        #expect(throws: InvalidParams.self) { try AutomationRequest.parse("wait_for_text", ["text": "OK", "present": 1]) }
        #expect(throws: InvalidParams.self) { try AutomationRequest.parse("scroll_to_item", ["label": "OK", "max_scrolls": 1.5]) }
        #expect(throws: InvalidParams.self) { try AutomationRequest.expectation(["expect": ["text_present": ""]]) }
        #expect(throws: InvalidParams.self) { try AutomationRequest.parse("fill_field", ["text": "OK", "label": "Name"]) }
    }

    @Test @MainActor func pauseCancelsActiveAndQueuedInputAndResumeRejectsOldRevision() async throws {
        let queue = PhoneInputQueue()
        let signal = AsyncStream<Void>.makeStream()
        let active = Task { try await queue.enqueue(origin: .agent) {
            signal.continuation.yield(())
            try await Task.sleep(for: .seconds(30))
        } }
        for await _ in signal.stream { break }
        let queued = Task { try await queue.enqueue(origin: .agent) { 42 } }
        await Task.yield()
        let old = queue.state
        queue.control(.takeover)
        await #expect(throws: (any Error).self) { try await active.value }
        await #expect(throws: (any Error).self) { try await queued.value }
        queue.control(.resume)
        await #expect(throws: PhoneServiceError.self) { try await queue.enqueue(origin: .agent, expected: old) { 1 } }
        #expect(try await queue.enqueue(origin: .agent, expected: queue.state) { 9 } == 9)
    }
    @Test func missingHebrewModelsDoNotBlockEnglishAndAlreadyHeldConditionsAreUnverified() {
        let image = ScreenImage(image: FakePhoneService.makeImage(width: 200, height: 400), capturedAt: Date())
        let before = ScreenDescription(frameID: "before", capturedAt: Date(), width: 200, height: 400, elements: [])
        let after = ScreenDescription(frameID: "after", capturedAt: Date(), width: 200, height: 400,
            elements: [ScreenElement(text: "Done", confidence: 1, bounds: .zero)], warnings: ["Hebrew OCR is not installed."])
        let english = ActionVerification.evaluate(ActionExpectation(textPresent: "Done"), before: image, after: image,
            description: after, receipt: InputReceipt(), beforeDescription: before)
        #expect(english.status == .verified)
        let held = ActionVerification.evaluate(ActionExpectation(textPresent: "Done"), before: image, after: image,
            description: after, receipt: InputReceipt(), beforeDescription: after)
        #expect(held.status == .unverified && held.method == "already_satisfied")
        #expect(!after.canVerifyText("שלום"))
    }

    @Test func takeoverAfterDeliveryReportsCompletedInput() async throws {
        let service = FakePhoneService()
        service.pauseAfterInput = true
        let automation = automation(service)
        do { _ = try await automation.act(phoneID: id, action: .home); Issue.record("Expected takeover failure") }
        catch let failure as InputFailure { #expect(failure.delivery == .delivered && failure.completedSteps == 1) }
        #expect(service.actions == [.home])
    }

    @Test func errorsCarryDeliveryAndOperationBudgets() async throws {
        let service = FakePhoneService(); service.performDelay = .seconds(1)
        let controller = PhoneController(service: service, timeout: 0.01)
        let result = await controller.run(phoneID: id, serialized: true) { try await service.perform(phoneID: self.id, action: .home) }
        if case .failure(let failure) = result {
            #expect(failure.delivery?.delivery == .unknown)
            #expect(failure.delivery?.json["input_delivered"] as? String == "unknown")
        } else { Issue.record("Expected deadline failure") }
        #expect(AutomationRequest.form([FormField](repeating: FormField(label: "Name", text: "value"), count: 20)).deadlineBudget > 60)
        let tools = MCPTools(controller: PhoneController(service: FakePhoneService()))
        if case .failure = await tools.call("control_phone", ["phone_id": id, "command": "resume"]) {} else { Issue.record("Remote resume was permitted") }
    }

}
