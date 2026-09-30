import Foundation
import TaplyneServer

/// The app's side of the server contract: answers REST and MCP requests from the
/// phones the registry knows about.
@MainActor
final class AppPhoneService: PhoneService {
    private let registry: PhoneRegistry

    init(registry: PhoneRegistry) {
        self.registry = registry
    }

    func listPhones() async -> [PhoneRecord] {
        registry.phones.map(\.record)
    }

    func rename(phoneID: String, displayName: String?) async throws -> PhoneRecord {
        let phone = try find(phoneID)
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        phone.config.displayName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        return phone.record
    }

    func apps(phoneID: String, refresh: Bool) async throws -> AppList {
        let phone = try find(phoneID)
        if !refresh, let cached = phone.config.apps {
            return AppList(apps: cached, updatedAt: phone.config.appsUpdatedAt, source: "database")
        }
        guard phone.plugged else { throw PhoneServiceError.phoneNotReady(Phone.Readiness.unplugged.reason ?? "") }
        do {
            let apps = try await registry.tool.apps(udid: phone.udid).map { AppEntry(name: $0.name, bundleID: $0.bundleID) }
            phone.config.apps = apps
            phone.config.appsUpdatedAt = Date()
            return AppList(apps: apps, updatedAt: nil, source: "device")
        } catch {
            throw PhoneServiceError.failed(error.localizedDescription)
        }
    }

    func screenshot(phoneID: String) async throws -> ScreenImage {
        let phone = try find(phoneID)
        guard let stream = phone.stream else {
            throw PhoneServiceError.phoneNotReady(phone.readiness.reason ?? "The screen is not available.")
        }
        if let image = stream.latestImage() { return image }
        if let image = await stream.nextImage(after: .distantPast, timeout: 5) { return image }
        throw PhoneServiceError.timeout
    }

    func liveFrames(phoneID: String) async throws -> AsyncStream<ScreenImage> {
        let phone = try find(phoneID)
        guard let stream = phone.stream else {
            throw PhoneServiceError.phoneNotReady(phone.readiness.reason ?? "The screen is not available.")
        }
        return stream.frames(maxFPS: 10)
    }

    func controlState(phoneID: String) async throws -> PhoneControlState { try find(phoneID).controlState }

    func control(phoneID: String, command: PhoneControlCommand) async throws -> PhoneControlState {
        try find(phoneID).control(command)
    }

    func perform(phoneID: String, action: PhoneAction) async throws {
        guard !action.requiresFrameReference else {
            throw PhoneServiceError.invalidArgument("Coordinate input requires an observed screen reference.")
        }
        let phone = try find(phoneID)
        _ = try await Self.perform(action, on: phone, registry: registry, byAgent: true)
    }

    func performObserved(phoneID: String, action: PhoneAction, reference: ActionReference) async throws -> InputReceipt {
        let phone = try find(phoneID)
        return try await Self.perform(action, on: phone, registry: registry, byAgent: true, reference: reference)
    }

    /// The one input queue is shared by the server, manual controls and embedded agent.
    @discardableResult static func perform(_ action: PhoneAction, on phone: Phone, registry: PhoneRegistry,
                                           byAgent: Bool = false, reference: ActionReference? = nil, manualImage: ScreenImage? = nil) async throws -> InputReceipt {
        let allowedWithoutCalibration: Bool
        switch action {
        case .home, .type, .setText, .keypress: allowedWithoutCalibration = true
        default: allowedWithoutCalibration = false
        }
        guard phone.readiness == .ready || (phone.readiness == .needsCalibration && allowedWithoutCalibration),
              let driver = registry.driver(for: phone) else {
            throw PhoneServiceError.phoneNotReady(phone.readiness.reason ?? "The iPhone is not ready.")
        }
        return try await phone.enqueue(origin: byAgent ? .agent : .manual, expected: reference?.control) {
            try Task.checkCancellation()
            if let manualImage {
                guard let current = phone.stream?.latestImage(), current.width == manualImage.width,
                      current.height == manualImage.height, Date().timeIntervalSince(manualImage.capturedAt) <= 5,
                      Date().timeIntervalSince(current.capturedAt) <= 1,
                      !ScreenComparison.changed(manualImage.image, current.image) else {
                    throw PhoneServiceError.failed("The screen changed during your gesture. Try again on the current screen.")
                }
            }
            if let reference {
                guard let current = phone.stream?.latestImage() else { throw PhoneServiceError.timeout }
                // The queue already checked control before incrementing its input revision.
                try reference.validate(current: current, control: reference.control, action: action)
            }
            phone.activity = action.summary
            phone.lastAction = ActionEvent(action: action, byAgent: byAgent)
            defer { phone.activity = nil }
            do {
                let receipt = try await driver.perform(action, referenceImage: reference?.image ?? manualImage)
                phone.lastError = nil
                phone.lastVerification = receipt.textVerification
                return receipt
            } catch {
                phone.lastError = (error as? PhoneServiceError).map(\.message) ?? error.localizedDescription
                throw error
            }
        }
    }

    private func find(_ id: String) throws -> Phone {
        guard let phone = registry.phone(id) else { throw PhoneServiceError.phoneNotFound(id) }
        return phone
    }
}

extension PhoneServiceError {
    var message: String {
        switch self {
        case let .phoneNotFound(id): "No phone with ID \(id)."
        case let .phoneNotReady(reason): reason
        case let .invalidArgument(detail): detail
        case .timeout: "The iPhone did not respond in time."
        case let .failed(detail): detail
        }
    }
}

extension PhoneAction {
    var summary: String {
        switch self {
        case let .tap(x, y): "Tap \(x), \(y)"
        case let .doubleTap(x, y): "Double tap \(x), \(y)"
        case let .tripleTap(x, y): "Triple tap \(x), \(y)"
        case let .tapAndHold(x, y, _): "Hold \(x), \(y)"
        case let .flick(_, _, direction): "Flick \(direction.rawValue)"
        case .drag: "Drag"
        case .holdAndDrag: "Hold and drag"
        case let .setText(text): "Replace field with \(text.count) characters"
        case let .type(text): "Type \(text.count) characters"
        case let .keypress(key, _, _): "Press \(key.rawValue)"
        case .home: "Home"
        case let .navigate(command): command.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
