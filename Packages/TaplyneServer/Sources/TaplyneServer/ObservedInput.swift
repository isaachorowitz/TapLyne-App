import Foundation
import CoreGraphics

public struct InputReceipt: Sendable {
    public var textVerification: Verification?
    public init(textVerification: Verification? = nil) { self.textVerification = textVerification }
}

public struct ActionReference: @unchecked Sendable {
    public var image: ScreenImage
    public var control: PhoneControlState
    public var observedAt: Date

    public init(image: ScreenImage, control: PhoneControlState, observedAt: Date = Date()) {
        self.image = image; self.control = control; self.observedAt = observedAt
    }

    public func validate(current: ScreenImage, control currentControl: PhoneControlState, action: PhoneAction? = nil) throws {
        try validateState(current: current, control: currentControl)
        // Home is a global button. Animation or video content cannot change its
        // destination, and must not prevent leaving the current app.
        if action?.requiresFrameReference != false, ScreenComparison.changed(image.image, current.image) {
            throw PhoneServiceError.failed("STALE_FRAME: The observed screen is no longer current. Describe it again before acting.")
        }
        if let action, let point = action.startPoint, ScreenComparison.targetChanged(image.image, current.image, around: point) {
            throw PhoneServiceError.failed("STALE_FRAME: The target changed after observation. Describe it again before acting.")
        }
    }

    func validateState(current: ScreenImage, control currentControl: PhoneControlState) throws {
        guard currentControl.mode == .automatic,
              Date().timeIntervalSince(observedAt) <= 30,
              Date().timeIntervalSince(image.capturedAt) <= 30,
              Date().timeIntervalSince(current.capturedAt) <= 1,
              image.width == current.width, image.height == current.height,
              control == currentControl
        else { throw PhoneServiceError.failed("STALE_FRAME: The observed screen is no longer current. Describe it again before acting.") }
    }
}

public extension PhoneAction {
    var startPoint: CGPoint? {
        switch self {
        case let .tap(x, y), let .doubleTap(x, y), let .tripleTap(x, y), let .tapAndHold(x, y, _), let .flick(x, y, _): CGPoint(x: x, y: y)
        case let .drag(x, y, _, _, _), let .holdAndDrag(x, y, _, _, _, _): CGPoint(x: x, y: y)
        default: nil
        }
    }
    var requiresFrameReference: Bool {
        switch self {
        case .navigate(.home): false
        case .tap, .doubleTap, .tripleTap, .tapAndHold, .flick, .drag, .holdAndDrag, .navigate, .type, .setText, .keypress: true
        default: false
        }
    }
}

public extension PhoneService {
    func controlState(phoneID: String) async throws -> PhoneControlState { PhoneControlState() }
    func control(phoneID: String, command: PhoneControlCommand) async throws -> PhoneControlState {
        throw PhoneServiceError.failed("This phone service does not support pause or takeover.")
    }
    func performObserved(phoneID: String, action: PhoneAction, reference: ActionReference) async throws -> InputReceipt {
        try reference.validate(current: try await screenshot(phoneID: phoneID), control: try await controlState(phoneID: phoneID), action: action)
        try await perform(phoneID: phoneID, action: action)
        return InputReceipt()
    }
}

/// Delivery is unknown when the transport cannot confirm whether a report reached the phone.
public enum InputDelivery: String, Sendable { case notDelivered = "not_delivered", delivered, unknown }
public struct InputFailure: LocalizedError, Sendable {
    public var delivery: InputDelivery
    public var completedSteps: Int
    public var message: String
    public var errorDescription: String? { message }
    public init(_ error: Error, delivery: InputDelivery, completedSteps: Int = 0) {
        self.delivery = delivery; self.completedSteps = completedSteps
        if let failure = error as? InputFailure {
            self.delivery = completedSteps > 0 ? .delivered : failure.delivery
            self.completedSteps += failure.completedSteps; self.message = failure.message
        } else { self.message = jobErrorString(error) }
    }
    var json: [String: Any] {
        let value: Any = delivery == .unknown ? "unknown" : (delivery == .delivered) as Any
        return ["error": message, "input_delivered": value,
         "delivery": delivery.rawValue, "completed_steps": completedSteps,
         "verification": ["status": "unverified", "detail": "Observe the current screen before continuing. Do not replay input automatically."]]
    }
}
