import CoreGraphics
import Foundation

@testable import TaplyneServer

final class FakePhoneService: PhoneService, @unchecked Sendable {
    static let online = "phone-online"
    static let offline = "phone-offline"

    private let lock = NSLock()
    private var phones: [PhoneRecord]
    private var _actions: [PhoneAction] = []
    private var _running = 0
    private var _maxRunning = 0
    private var _liveStopped = false
    private var _state = PhoneControlState()
    private var _image: CGImage?
    private var _afterInputImages: [CGImage] = []
    var textVerificationStatus: VerificationStatus = .unverified
    var pauseAfterInput = false
    var captureFailsAfterInput = false
    var changeScreensAfterInput = false
    var performDelay: Duration = .zero
    var failNextPerform: PhoneServiceError?

    init() {
        phones = [
            PhoneRecord(
                id: Self.online, name: "Test iPhone", connectionStatus: .online, width: 1320, height: 2868,
                model: "iPhone 17 Pro Max", createdAt: Date(timeIntervalSince1970: 1_780_000_000)),
            PhoneRecord(
                id: Self.offline, name: "Old iPhone", connectionStatus: .offline,
                statusReason: "Not plugged in to this Mac", createdAt: Date(timeIntervalSince1970: 1_770_000_000)),
        ]
    }

    var actions: [PhoneAction] { lock.withLock { _actions } }
    var maxConcurrentActions: Int { lock.withLock { _maxRunning } }
    var liveStopped: Bool { lock.withLock { _liveStopped } }

    func listPhones() async -> [PhoneRecord] { lock.withLock { phones } }

    func rename(phoneID: String, displayName: String?) async throws -> PhoneRecord {
        try lock.withLock {
            guard let i = phones.firstIndex(where: { $0.id == phoneID }) else { throw PhoneServiceError.phoneNotFound(phoneID) }
            phones[i].displayName = displayName
            return phones[i]
        }
    }

    func apps(phoneID: String, refresh: Bool) async throws -> AppList {
        AppList(
            apps: [AppEntry(name: "Safari", bundleID: "com.apple.mobilesafari")],
            updatedAt: refresh ? nil : Date(timeIntervalSince1970: 1_780_000_000), source: refresh ? "device" : "database")
    }

    static func makeImage(width: Int = 1320, height: Int = 2868, shade: CGFloat = 0.2) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: shade, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func screenshot(phoneID: String) async throws -> ScreenImage {
        if captureFailsAfterInput && !actions.isEmpty { throw PhoneServiceError.timeout }
        let image = lock.withLock { () -> CGImage? in
            if !_actions.isEmpty && !_afterInputImages.isEmpty { _image = _afterInputImages.removeFirst() }
            return _image
        }
        return ScreenImage(image: image ?? Self.makeImage(), capturedAt: Date())
    }

    func setImagesAfterInput(_ images: [CGImage]) { lock.withLock { _afterInputImages = images } }

    func setImage(_ image: CGImage) { lock.withLock { _image = image } }

    func controlState(phoneID: String) async throws -> PhoneControlState { lock.withLock { _state } }

    func control(phoneID: String, command: PhoneControlCommand) async throws -> PhoneControlState {
        lock.withLock {
            _state.generation += 1; _state.revision += 1
            _state.mode = command == .resume ? .automatic : command == .takeover ? .manual : .paused
            return _state
        }
    }

    func performObserved(phoneID: String, action: PhoneAction, reference: ActionReference) async throws -> InputReceipt {
        try reference.validate(current: try await screenshot(phoneID: phoneID), control: try await controlState(phoneID: phoneID), action: action)
        try await perform(phoneID: phoneID, action: action)
        let text: Bool
        switch action { case .setText, .type: text = true; default: text = false }
        return InputReceipt(textVerification: text ? Verification(textVerificationStatus, method: "test_readback", detail: "Simulated text readback") : nil)
    }

    func liveFrames(phoneID: String) async throws -> AsyncStream<ScreenImage> {
        let image = Self.makeImage(width: 660, height: 1434)
        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    continuation.yield(ScreenImage(image: image, capturedAt: Date()))
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.lock.withLock { self?._liveStopped = true }
            }
        }
    }

    func perform(phoneID: String, action: PhoneAction) async throws {
        lock.withLock {
            _running += 1
            _maxRunning = max(_maxRunning, _running)
        }
        defer { lock.withLock { _running -= 1 } }
        if performDelay != .zero { try await Task.sleep(for: performDelay) }
        let failure = lock.withLock { () -> PhoneServiceError? in
            defer { failNextPerform = nil }
            return failNextPerform
        }
        if let failure { throw failure }
        lock.withLock {
            _actions.append(action); _state.revision += 1
            if pauseAfterInput { _state.generation += 1; _state.mode = .manual }
            if changeScreensAfterInput { _image = Self.makeImage(shade: _actions.count.isMultiple(of: 2) ? 0.2 : 0.9) }
        }
    }
}
