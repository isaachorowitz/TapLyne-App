import CoreGraphics
import Foundation
import Testing
@testable import TaplyneServer

@Suite struct ActionTimingTests {
    let id = FakePhoneService.online

    @Test func resultWaitsForLayoutAndNeverRepeatsInput() async throws {
        let service = FakePhoneService()
        let final = FakePhoneService.makeImage(shade: 0.9)
        service.setImagesAfterInput([FakePhoneService.makeImage(shade: 0.5), FakePhoneService.makeImage(shade: 0.7), final])
        let automation = PhoneAutomation(service: service) { image in
            ScreenDescription(frameID: UUID().uuidString, capturedAt: image.capturedAt, width: image.width, height: image.height, elements: [])
        }
        let result = try await automation.act(phoneID: id, action: .home)
        #expect(!ScreenComparison.changed(result.image.image, final))
        #expect(service.actions == [.home])
    }

    @Test func continuouslyMovingScreenIsUnverifiedWithoutRepeatingInput() async throws {
        let service = FakePhoneService()
        let a = FakePhoneService.makeImage(shade: 0.2), b = FakePhoneService.makeImage(shade: 0.9)
        service.setImagesAfterInput((0..<200).map { $0.isMultiple(of: 2) ? a : b })
        let automation = PhoneAutomation(service: service) { image in
            ScreenDescription(frameID: UUID().uuidString, capturedAt: image.capturedAt, width: image.width, height: image.height, elements: [])
        }
        let result = try await automation.act(phoneID: id, action: .home)
        #expect(result.verification.status == .unverified)
        #expect(result.verification.method == "screen_moving")
        #expect(result.inputDelivered)
        #expect(service.actions == [.home])
    }

    @Test func movedLabelRefreshesButOldCoordinateRemainsBlocked() async throws {
        let service = FakePhoneService()
        let oldImage = FakePhoneService.makeImage(shade: 0.2)
        let newImage = FakePhoneService.makeImage(shade: 0.9)
        service.setImage(oldImage)
        let automation = PhoneAutomation(service: service) { image in
            let moved = ScreenComparison.changed(image.image, oldImage)
            return Self.screen(image, names: ["Settings", "General", "Privacy", "Battery", "About"], moved: moved)
        }
        let old = try await automation.observe(phoneID: id)
        service.setImage(newImage)
        await #expect(throws: PhoneServiceError.self) {
            try await automation.act(phoneID: id, action: .tap(x: 175, y: 325), frameID: old.screen.frameID)
        }
        // A rejection consumes that reference; obtain another old observation
        // to test label recovery without reviving a consumed frame.
        service.setImage(oldImage)
        let frame = try await automation.observe(phoneID: id)
        service.setImage(newImage)
        _ = try await automation.tapLabel(phoneID: id, label: "Settings", frameID: frame.screen.frameID)
        #expect(service.actions == [.tap(x: 175, y: 425)])
    }

    @Test func repeatedLabelOnDifferentPageCannotRefresh() async throws {
        let service = FakePhoneService()
        let oldImage = FakePhoneService.makeImage(shade: 0.2)
        service.setImage(oldImage)
        let automation = PhoneAutomation(service: service) { image in
            let changed = ScreenComparison.changed(image.image, oldImage)
            return Self.screen(image, names: changed ? ["Save", "Account", "Password", "Email", "Cancel"] :
                ["Save", "Photo", "Camera", "Album", "Library"], moved: changed)
        }
        let frame = try await automation.observe(phoneID: id)
        service.setImage(FakePhoneService.makeImage(shade: 0.9))
        await #expect(throws: PhoneServiceError.self) {
            try await automation.tapLabel(phoneID: id, label: "Save", frameID: frame.screen.frameID)
        }
        #expect(service.actions.isEmpty)
    }

    private static func screen(_ image: ScreenImage, names: [String], moved: Bool) -> ScreenDescription {
        ScreenDescription(frameID: UUID().uuidString, capturedAt: image.capturedAt, width: image.width, height: image.height,
            elements: names.enumerated().map { i, name in
                ScreenElement(text: name, confidence: 1, bounds: CGRect(x: 100, y: 300 + i * 100 + (moved ? 100 : 0), width: 150, height: 50))
            })
    }
}
