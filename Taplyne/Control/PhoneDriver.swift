import AppKit
import Foundation
import os
import TaplyneServer

/// Turns `PhoneAction`s into Bluetooth mouse and keyboard input for one phone.
///
/// iOS AssistiveTouch shows a pointer that a Bluetooth mouse drives. A mouse only
/// reports relative motion, so the driver keeps an estimate of where the pointer
/// is, re-anchors it by pinning it into the top-left corner, and converts screen
/// pixels to mouse units with the phone's calibrated `PointerProfile`.
@MainActor
final class PhoneDriver {
    let bluetooth: ClassicHIDTransport
    var address: String
    var profile: PointerProfile
    var screen: CGSize
    var isCalibrating = false
    var frameProvider: (() async throws -> ScreenImage)?

    private(set) var pointer: CGPoint?
    private var pointerRegion: CGRect?
    private var delivery: InputDelivery = .notDelivered
    private var referenceImage: ScreenImage?
    private let log = Logger(subsystem: "agency.ziplyne.taplyne", category: "driver")

    init(bluetooth: ClassicHIDTransport, address: String, profile: PointerProfile, screen: CGSize) {
        self.bluetooth = bluetooth
        self.address = address
        self.profile = profile
        self.screen = screen
    }

    // MARK: - Actions

    func perform(_ action: PhoneAction, referenceImage: ScreenImage? = nil) async throws -> InputReceipt {
        delivery = .notDelivered; self.referenceImage = action.requiresFrameReference ? referenceImage : nil
        defer { self.referenceImage = nil }
        do { return try await deliver(action) }
        catch { await releaseInput(); invalidatePointer(); throw InputFailure(error, delivery: delivery) }
    }

    func releaseInput() async {
        // A fresh task must deliver releases even when the action's task was cancelled.
        await Task { @MainActor in
            _ = await self.bluetooth.send(MouseReport().data, reportID: .mouse, address: self.address)
            _ = await self.bluetooth.send(KeyboardReport().data, reportID: .keyboard, address: self.address)
            _ = await self.bluetooth.send(ConsumerReport.zero.data, reportID: .consumerControl, address: self.address)
        }.value
    }

    func invalidatePointer() { pointer = nil; pointerRegion = nil }

    private func deliver(_ action: PhoneAction) async throws -> InputReceipt {
        try Task.checkCancellation()
        var receipt = InputReceipt()
        guard bluetooth.readyAddresses.contains(address) else {
            throw PhoneServiceError.phoneNotReady("Bluetooth is not connected to the iPhone")
        }
        switch action {
        case let .tap(x, y):
            try await moveTo(x, y)
            try await click(count: 1)
        case let .doubleTap(x, y):
            try await moveTo(x, y)
            try await click(count: 2)
        case let .tripleTap(x, y):
            try await moveTo(x, y)
            try await click(count: 3)
        case let .tapAndHold(x, y, duration):
            try await moveTo(x, y)
            try await mouse(MouseReport(buttons: .left))
            try await sleep(ms: duration)
            try await mouse(MouseReport())
        case let .flick(x, y, direction):
            try await flick(from: CGPoint(x: x, y: y), direction: direction)
        case let .drag(fx, fy, tx, ty, speed):
            try await drag(from: CGPoint(x: fx, y: fy), to: CGPoint(x: tx, y: ty), holdMs: 0, speed: speed)
        case let .holdAndDrag(fx, fy, tx, ty, hold, speed):
            try await drag(from: CGPoint(x: fx, y: fy), to: CGPoint(x: tx, y: ty), holdMs: hold, speed: speed)
        case let .type(text):
            receipt.textVerification = try await typeVerified(text, replace: false)
        case let .setText(text):
            receipt.textVerification = try await typeVerified(text, replace: true)
        case let .keypress(key, modifiers, count):
            for _ in 0 ..< max(1, count) {
                try await keyStroke(KeyMap.keycode(for: key), modifiers: KeyMap.modifiers(modifiers))
            }
        case .home:
            try await pressHome()
        case let .navigate(command):
            try await navigate(command)
        }
        // Observed actions wait for fresh, settled frames in PhoneAutomation.
        // Keep the fixed delay only when no screen feedback is available.
        if frameProvider == nil || isCalibrating { try await sleep(ms: profile.settleMs) }
        return receipt
    }

    // MARK: - Pointer

    /// Pins the pointer into the top-left corner so its position is known exactly.
    func anchor() async throws {
        for _ in 0 ..< profile.anchorReports {
            try await mouse(MouseReport(dX: -127, dY: -127))
        }
        try await sleep(ms: 200)
        pointer = profile.anchorPoint ?? .zero
        pointerRegion = pointer.map { CGRect(x: $0.x - 40, y: $0.y - 40, width: 80, height: 80) }
    }

    /// Moves the pointer to a screen pixel.
    func moveTo(_ x: Int, _ y: Int) async throws {
        let target = clamped(CGPoint(x: x, y: y))
        if isCalibrating {
            if pointer == nil || profile.anchorEveryMove { try await anchor() }
            try await glide(to: target, buttons: []); return
        }
        guard let frameProvider else { throw PhoneServiceError.failed("Pointer feedback is unavailable. Reconnect capture before clicking.") }
        let baseline = try await frameProvider()
        let oldPointer = pointer
        var oldRegion = pointerRegion
        if let referenceImage {
            try ensureStable(referenceImage, baseline, target: target, ignoring: [])
        }
        // A successful aim records the actual pointer. Reuse it until a gesture,
        // takeover, geometry change or failed feedback invalidates tracking.
        if pointer == nil { try await anchor() }
        var before = try await frameProvider()
        var baselinePointer = oldPointer
        if let motion = PointerLocator.motion(before: baseline.image, after: before.image, origin: pointer ?? .zero, maxBlobSize: 320, expectedTarget: oldPointer) {
            baselinePointer = motion.end.center // Reverse movement: the distant blob was the old pointer.
            oldRegion = motion.end.bounds.insetBy(dx: -16, dy: -16)
        }
        try ensureStable(baseline, before, target: target, ignoring: [baselinePointer, pointer].compactMap { $0 }, regions: [oldRegion, pointerRegion].compactMap { $0 })
        for _ in 0..<3 {
            // Separate the old and new circles so their outlines can be measured independently.
            if hypot(target.x - (pointer?.x ?? 0), target.y - (pointer?.y ?? 0)) < 160 {
                let probe = clamped(CGPoint(x: target.x + (target.x < screen.width / 2 ? 200 : -200), y: target.y))
                before = try await aimLeg(to: probe, before: before)
            }
            let start = pointer ?? .zero
            let requested = hypot(target.x - start.x, target.y - start.y)
            let after = try await aimLeg(to: target, before: before)
            guard let actual = pointer else { throw PhoneServiceError.failed("Pointer position was lost.") }
            let error = hypot(actual.x - target.x, actual.y - target.y)
            if error <= max(18, min(30, profile.verifiedErrorPx ?? 18)) {
                let final = try await frameProvider()
                try ensureStable(baseline, final, target: target, ignoring: [baselinePointer, actual].compactMap { $0 }, regions: [oldRegion, pointerRegion].compactMap { $0 })
                try ensureStable(after, final, target: target, ignoring: [actual], regions: [pointerRegion].compactMap { $0 })
                return
            }
            let traveled = hypot(actual.x - start.x, actual.y - start.y)
            if requested > 100, traveled > 30 {
                profile.gain = min(30, max(0.2, profile.gain * traveled / requested))
            }
            before = after
        }
        pointer = nil
        throw PhoneServiceError.failed("POINTER_UNCERTAIN: Pointer could not be aimed within the calibrated tolerance. No click was sent. Recalibrate or take over manually.")
    }

    func validateTextTarget(_ baseline: ScreenImage?) async throws {
        guard !isCalibrating else { return }
        guard let baseline, let current = try await frameProvider?() else {
            throw PhoneServiceError.failed("CAPTURE_STALE: No current field frame is available. Nothing was typed.")
        }
        guard Date().timeIntervalSince(current.capturedAt) <= 1,
              !ScreenComparison.changed(baseline.image, current.image) else {
            throw PhoneServiceError.failed("STALE_FRAME: The focused field changed before typing. Nothing was typed.")
        }
    }

    func textBaseline() async throws -> ScreenImage? {
        if let referenceImage { return referenceImage }
        return try await frameProvider?()
    }

    private func ensureStable(_ before: ScreenImage, _ after: ScreenImage, target: CGPoint, ignoring points: [CGPoint], regions: [CGRect] = []) throws {
        guard Date().timeIntervalSince(after.capturedAt) <= 1,
              ScreenComparison.stableForInput(before.image, after.image, ignoring: points, ignoringRegions: regions),
              !ScreenComparison.targetChanged(before.image, after.image, around: target, ignoring: points, ignoringRegions: regions) else {
            throw PhoneServiceError.failed("STALE_FRAME: Screen or target changed while aiming. No click was sent.")
        }
    }

    private func aimLeg(to target: CGPoint, before: ScreenImage) async throws -> ScreenImage {
        let origin = pointer ?? .zero
        try await glide(to: target, buttons: [])
        // USB capture can lag HID motion, and an iOS hover continues growing
        // after the cursor arrives. Observe that one move until its shape settles.
        // This never resends motion or a click while waiting for feedback.
        let deadline = Date().addingTimeInterval(1.2)
        var previous: PointerLocator.Blob?
        var previousCapture = before.capturedAt
        repeat {
            try Task.checkCancellation()
            if let after = try await frameProvider?(), after.capturedAt > previousCapture,
               after.width == before.width, after.height == before.height,
               let motion = PointerLocator.motion(before: before.image, after: after.image, origin: origin, maxBlobSize: 320, expectedTarget: target),
               ScreenComparison.stableForInput(before.image, after.image, ignoring: [motion.start.center, motion.end.center],
                   ignoringRegions: [motion.start.bounds, motion.end.bounds].map { $0.insetBy(dx: -16, dy: -16) }) {
                if let previous,
                   hypot(previous.center.x - motion.end.center.x, previous.center.y - motion.end.center.y) < 10,
                   abs(previous.bounds.width - motion.end.bounds.width) <= 12,
                   abs(previous.bounds.height - motion.end.bounds.height) <= 12 {
                    pointer = motion.end.center
                    pointerRegion = motion.end.bounds.insetBy(dx: -16, dy: -16)
                    return after
                }
                previous = motion.end
                previousCapture = after.capturedAt
            } else { previous = nil }
            try await sleep(ms: 80)
        } while Date() < deadline
        invalidatePointer()
        throw PhoneServiceError.failed("POINTER_UNCERTAIN: Screen changed or pointer could not be located. No click was sent. Enable AssistiveTouch on the iPhone, then recalibrate on a still Home Screen.")
    }

    /// Moves by a mouse-unit vector in equal-length steps. Used by calibration.
    func moveUnits(_ ux: Int, _ uy: Int, buttons: MouseButtons = [], stepUnits: Int? = nil) async throws {
        let step = Double(stepUnits ?? profile.stepUnits)
        let length = hypot(Double(ux), Double(uy))
        guard length > 0 else { return }
        let count = Int((length / step).rounded(.up))
        var sentX = 0, sentY = 0
        for i in 1 ... count {
            // Error diffusion: each report carries the rounding the previous ones left over.
            let wantX = Int((Double(ux) * Double(i) / Double(count)).rounded())
            let wantY = Int((Double(uy) * Double(i) / Double(count)).rounded())
            try await mouse(MouseReport(buttons: buttons, dX: Int8(clamping: wantX - sentX), dY: Int8(clamping: wantY - sentY)))
            sentX = wantX
            sentY = wantY
            if profile.intervalMs > 0 { try await sleep(ms: profile.intervalMs) }
        }
    }

    /// Moves in a straight line with every report the same length, which keeps iOS
    /// pointer acceleration constant so the calibrated gain holds.
    private func glide(to target: CGPoint, buttons: MouseButtons, stepUnits: Int? = nil) async throws {
        let start = pointer ?? .zero
        let dx = target.x - start.x, dy = target.y - start.y
        let distance = hypot(dx, dy)
        guard distance >= 1 else { return }
        // Every glide travels `offset` pixels beyond gain * units (acceleration ramp).
        let units = max(0, distance - profile.offset) / profile.gain
        let ux = Int((dx / distance * units).rounded())
        let uy = Int((dy / distance * units).rounded())
        try await moveUnits(ux, uy, buttons: buttons, stepUnits: stepUnits)
        pointer = target
    }

    private func click(count: Int) async throws {
        for i in 0 ..< count {
            try await mouse(MouseReport(buttons: .left))
            try await sleep(ms: profile.clickHoldMs)
            try await mouse(MouseReport())
            if i < count - 1 { try await sleep(ms: profile.multiClickGapMs) }
        }
    }

    private func flick(from point: CGPoint, direction: Direction) async throws {
        try await moveTo(Int(point.x), Int(point.y))
        var target = point
        switch direction {
        case .up: target.y -= screen.height * 0.3
        case .down: target.y += screen.height * 0.3
        case .left: target.x -= screen.width * 0.6
        case .right: target.x += screen.width * 0.6
        }
        try await mouse(MouseReport(buttons: .left))
        try await sleep(ms: 20)
        try await glide(to: clamped(target), buttons: .left, stepUnits: profile.flickStepUnits)
        try await mouse(MouseReport())
        // Fast moves accelerate unpredictably, so the next move re-anchors.
        pointer = nil
    }

    func drag(from: CGPoint, to: CGPoint, holdMs: Int, speed: Speed) async throws {
        try await moveTo(Int(from.x), Int(from.y))
        try await mouse(MouseReport(buttons: .left))
        try await sleep(ms: max(80, holdMs))
        let saved = profile.intervalMs
        profile.intervalMs = switch speed {
        case .slow: saved + 24
        case .medium: saved + 8
        case .fast: saved
        }
        defer { profile.intervalMs = saved }
        try await glide(to: clamped(to), buttons: .left)
        // Hold still before lifting so the release carries no fling.
        try await sleep(ms: 200)
        try await mouse(MouseReport())
    }

    // MARK: - Live touch (manual control)

    func touchDown(_ x: Int, _ y: Int) async throws {
        try await moveTo(x, y)
        try await mouse(MouseReport(buttons: .left))
    }

    func touchMove(_ x: Int, _ y: Int) async throws {
        try await glide(to: clamped(CGPoint(x: x, y: y)), buttons: .left)
    }

    func touchUp() async throws {
        try await mouse(MouseReport())
    }

    // MARK: - Keyboard

    func keyStroke(_ key: Keycode, modifiers: KeyboardModifiers = []) async throws {
        if !modifiers.isEmpty {
            try await keyboard(KeyboardReport(modifiers: modifiers))
        }
        try await keyboard(KeyboardReport(modifiers: modifiers, keys: [key]))
        try await sleep(ms: profile.keyMs)
        try await keyboard(KeyboardReport(modifiers: modifiers))
        if !modifiers.isEmpty {
            try await keyboard(KeyboardReport())
        }
        try await sleep(ms: profile.keyMs)
    }

    func pressHome() async throws {
        try await consumer(ConsumerReport(key: .menu))
        try await sleep(ms: 60)
        try await consumer(.zero)
    }

    // MARK: - Transport

    private func mouse(_ report: MouseReport) async throws {
        try Task.checkCancellation()
        let semantic = !report.buttons.isEmpty
        if semantic, delivery == .notDelivered { delivery = .unknown }
        guard await bluetooth.send(report.data, reportID: .mouse, address: address) else { throw Self.disconnected }
        if semantic { delivery = .delivered }
    }

    private func keyboard(_ report: KeyboardReport) async throws {
        try Task.checkCancellation()
        let semantic = !report.keys.isEmpty || !report.modifiers.isEmpty
        if semantic, delivery == .notDelivered { delivery = .unknown }
        guard await bluetooth.send(report.data, reportID: .keyboard, address: address) else { throw Self.disconnected }
        if semantic { delivery = .delivered }
    }

    private func consumer(_ report: ConsumerReport) async throws {
        try Task.checkCancellation()
        let semantic = report.data != ConsumerReport.zero.data
        if semantic, delivery == .notDelivered { delivery = .unknown }
        guard await bluetooth.send(report.data, reportID: .consumerControl, address: address) else { throw Self.disconnected }
        if semantic { delivery = .delivered }
    }

    private static let disconnected = PhoneServiceError.phoneNotReady("Bluetooth dropped while sending input")

    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(p.x, screen.width - 1)), y: max(0, min(p.y, screen.height - 1)))
    }

    func sleep(ms: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
    }
}

/// How one phone's pointer responds to mouse input. Calibrated per phone.
struct PointerProfile: Codable, Equatable {
    var anchorPoint: CGPoint?
    /// Screen pixels moved per mouse unit when every report is `stepUnits` long.
    var gain: CGFloat = 3
    /// Pixels a glide travels beyond `gain * units`, from the fit's intercept.
    var offset: CGFloat = 0
    var stepUnits = 8
    var flickStepUnits = 40
    var intervalMs = 0
    var anchorReports = 45
    var anchorEveryMove = true
    var clickHoldMs = 50
    var multiClickGapMs = 70
    var keyMs = 10
    var settleMs = 250
    var clipboardSyncMs = 1200
    var pasteNonASCII = true
    /// Measured landing error after calibration, in pixels.
    var verifiedErrorPx: CGFloat?
    var calibratedAt: Date?
}
