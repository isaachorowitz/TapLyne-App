import CoreGraphics
import Foundation
import os
import ImageIO

/// Measures how far the AssistiveTouch pointer moves per mouse unit on this phone.
///
/// It pins the pointer into the corner, moves it by known amounts, finds it on
/// screen by frame differencing, and fits gain and corner offset. Then it aims at
/// three targets and reports the landing error. It runs on the Home Screen
/// because a still screen makes the pointer the only thing that moves.
@MainActor
struct PointerCalibrator {
    struct Result {
        var profile: PointerProfile
        var samples: [(units: Double, pixels: Double)]
        var errors: [CGFloat]
    }

    enum Failure: LocalizedError {
        case pointerNotFound(String)
        case inconsistent(String)

        var errorDescription: String? {
            switch self {
            case let .pointerNotFound(detail): "Could not find the pointer on screen (\(detail)). Keep the iPhone unlocked on the Home Screen and try again."
            case let .inconsistent(detail): "The pointer moved inconsistently (\(detail)). Try again with the iPhone still."
            }
        }
    }

    let driver: PhoneDriver
    let stream: ScreenStream
    var progress: (String) -> Void = { _ in }
    private let log = Logger(subsystem: "agency.ziplyne.taplyne", category: "calibrate")

    func run() async throws -> Result {
        let original = driver.profile
        driver.isCalibrating = true
        defer { driver.isCalibrating = false; driver.profile = original }
        var profile = driver.profile
        profile.anchorEveryMove = true
        profile.intervalMs = 0
        driver.profile = profile
        let screen = driver.screen

        progress("Going to the Home Screen")
        try await driver.pressHome()
        await sleep(ms: 1400)

        // Vertical moves along the empty left margin avoid icons and the Dynamic Island.
        progress("Measuring pointer speed")
        let probeUnits = 48
        let probe = try await measure(units: probeUnits)
        profile.anchorPoint = probe.anchor
        driver.profile = profile
        let roughGain = probe.displacement.y / Double(probeUnits)
        guard roughGain > 0.2 else { throw Failure.pointerNotFound("it barely moved") }
        var samples: [(units: Double, point: CGPoint)] = [(Double(probeUnits), probe.displacement)]
        for fraction in [0.35, 0.7] {
            let targetPixels = Double(screen.width) * fraction
            let units = max(probeUnits + 8, Int(targetPixels / roughGain))
            let point = try await measure(units: units)
            samples.append((Double(units), point.displacement))
        }

        // Least squares over vertical displacement: pixels = offset + gain * units.
        let xs = samples.map { $0.units }
        let ys = samples.map { $0.point.y }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = zip(xs, xs).map { ($0 - mx) * ($1 - mx) }.reduce(0, +)
        let sxy = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
        let gain = sxy / sxx
        let residuals = zip(xs, ys).map { abs($1 - (my + gain * ($0 - mx))) }
        log.info("calibration gain \(gain) residuals \(residuals)")
        guard gain > 0.2, residuals.max() ?? 0 < 45 else {
            throw Failure.inconsistent("residual \(Int(residuals.max() ?? 0)) px")
        }
        profile.gain = CGFloat(gain)
        profile.offset = CGFloat(my - gain * mx)
        driver.profile = profile

        // Aim at three targets and measure where the pointer lands.
        progress("Checking accuracy")
        let anchor = profile.anchorPoint ?? .zero
        // The Home Screen magnetizes the pointer to app icons. Measure along
        // the empty top and left margins so icon morphing cannot bias the fit.
        let targets = [CGPoint(x: screen.width * 0.65, y: 210),
                       CGPoint(x: anchor.x, y: screen.height * 0.35),
                       CGPoint(x: anchor.x, y: screen.height * 0.65)]
        var errors: [CGFloat] = []
        for target in targets {
            try await driver.anchor()
            await sleep(ms: 350)
            guard let before = stream.latestImage() else { throw Failure.pointerNotFound("no frame") }
            try await driver.moveTo(Int(target.x), Int(target.y))
            await sleep(ms: 400)
            guard let after = stream.latestImage(),
                  let blob = PointerLocator.locate(before: before.image, after: after.image, origin: anchor, maxBlobSize: 100) else {
                throw Failure.pointerNotFound("verification")
            }
            log.info("target \(target.x),\(target.y) landed \(blob.center.x),\(blob.center.y)")
            errors.append(hypot(blob.center.x - target.x, blob.center.y - target.y))
        }
        guard errors.max() ?? .infinity <= 30 else {
            throw Failure.inconsistent("landing error \(Int(errors.max() ?? 0)) px")
        }
        profile.verifiedErrorPx = errors.max()
        profile.calibratedAt = Date()
        progress("Done")
        return Result(profile: profile, samples: zip(xs, ys).map { ($0, $1) }, errors: errors)
    }

    /// Measures vertical displacement from the pointer's actual corner inset.
    private func measure(units: Int) async throws -> (displacement: CGPoint, anchor: CGPoint) {
        for attempt in 1 ... 3 {
            try await driver.anchor()
            await sleep(ms: 350)
            guard let before = stream.latestImage() else { throw Failure.pointerNotFound("no frame") }
            try await driver.moveUnits(0, units)
            await sleep(ms: 400)
            guard let after = stream.latestImage() else { throw Failure.pointerNotFound("no frame") }
            if let directory = ProcessInfo.processInfo.environment["TAPLYNE_CALIBRATION_DIR"] {
                for (name, image) in [("before", before.image), ("after", after.image)] {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("probe-\(units)-\(attempt)-\(name).png")
                    if let output = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(output, image, nil)
                        CGImageDestinationFinalize(output)
                    }
                }
            }
            if let motion = PointerLocator.motion(before: before.image, after: after.image, origin: .zero) {
                let blob = motion.end
                log.info("units \(units) -> \(blob.center.x), \(blob.center.y) (\(blob.pixelCount) px)")
                return (CGPoint(x: blob.center.x - motion.start.center.x, y: blob.center.y - motion.start.center.y), motion.start.center)
            }
            log.info("pointer not found for \(units) units, attempt \(attempt)")
        }
        throw Failure.pointerNotFound("\(units) units")
    }

    private func sleep(ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }
}
