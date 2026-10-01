import Foundation
import Testing

@testable import TaplyneServer

@Suite struct NavigationSettlingTests {
    let id = FakePhoneService.online

    private func automation(_ service: FakePhoneService) -> PhoneAutomation {
        PhoneAutomation(service: service) { image in
            ScreenDescription(frameID: UUID().uuidString, capturedAt: image.capturedAt,
                              width: image.width, height: image.height, elements: [])
        }
    }

    @Test func slowCapturesStillRequireThreeMatchingFreshFrames() async throws {
        let service = FakePhoneService()
        service.setImage(FakePhoneService.makeImage())
        service.screenshotDelay = .milliseconds(1600)
        let result = try await automation(service).settledNavigationScreen(id, generation: 0)
        #expect(result.verification.method == "observation")
        #expect(!result.inputDelivered)
        // Three matching captures, followed by the returned OCR observation.
        #expect(service.screenshotCount == 4)
        #expect(service.actions.isEmpty)
    }

    @Test func slowCapturesDoNotAcceptContinuouslyMovingLayout() async throws {
        let service = FakePhoneService()
        service.screenshotDelay = .milliseconds(1600)
        let a = FakePhoneService.makeImage(shade: 0.2)
        let b = FakePhoneService.makeImage(shade: 0.9)
        service.setImagesAfterInput((0..<20).map { $0.isMultiple(of: 2) ? a : b })
        try await service.perform(phoneID: id, action: .home)
        await #expect(throws: PhoneServiceError.failed("SCREEN_MOVING: The navigation transition did not settle. Observe before continuing.")) {
            try await automation(service).settledNavigationScreen(id, generation: 0)
        }
        #expect(service.actions == [.home])
    }

    @Test func repeatedCaptureTimestampNeverCountsAsStable() async throws {
        let service = FakePhoneService()
        service.setImage(FakePhoneService.makeImage())
        service.screenshotCapturedAt = Date()
        await #expect(throws: PhoneServiceError.failed("SCREEN_MOVING: The navigation transition did not settle. Observe before continuing.")) {
            try await automation(service).settledNavigationScreen(id, generation: 0)
        }
        #expect(service.actions.isEmpty)
    }

    @Test func manualTakeoverStopsNavigationBeforeMoreObservation() async throws {
        let service = FakePhoneService()
        _ = try await service.control(phoneID: id, command: .takeover)
        await #expect(throws: PhoneServiceError.failed("CONTROL_CHANGED: Navigation stopped for pause or manual takeover.")) {
            try await automation(service).settledNavigationScreen(id, generation: 0)
        }
        #expect(service.actions.isEmpty)
    }
}
