import Foundation
import CoreGraphics
@main struct PointerLocatorTests {
    static func frame(_ point: CGPoint, hover: CGRect? = nil) -> CGImage {
        let context = CGContext(data: nil, width: 1320, height: 2868, bitsPerComponent: 8, bytesPerRow: 1320 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1320, height: 2868))
        context.setFillColor(gray: 0.3, alpha: 1)
        if let hover { context.fill(CGRect(x: hover.minX, y: 2868 - hover.maxY, width: hover.width, height: hover.height)) }
        context.fillEllipse(in: CGRect(x: point.x - 28, y: 2868 - point.y - 28, width: 56, height: 56))
        return context.makeImage()!
    }
    static func main() {
        let before = frame(CGPoint(x: 54, y: 54))
        let after = frame(CGPoint(x: 109, y: 109))
        let motion = PointerLocator.motion(before: before, after: after, origin: .zero)!
        precondition(hypot(motion.start.center.x - 54, motion.start.center.y - 54) < 3)
        precondition(hypot(motion.end.center.x - 109, motion.end.center.y - 109) < 3)
        precondition(PointerLocator.motion(before: before, after: before, origin: .zero) == nil)
        let horizontal = PointerLocator.motion(before: before, after: frame(CGPoint(x: 180, y: 54)), origin: .zero)!
        precondition(abs(horizontal.end.center.x - horizontal.start.center.x - 126) < 3)
        // Overlapping disappearance/appearance must fail instead of inventing a gain.
        precondition(PointerLocator.motion(before: before, after: frame(CGPoint(x: 110, y: 54)), origin: .zero) == nil)
        let target = CGPoint(x: 514, y: 570)
        let hover = CGRect(x: 394, y: 454, width: 240, height: 232)
        let enlarged = frame(target, hover: hover)
        precondition(PointerLocator.motion(before: before, after: enlarged, origin: CGPoint(x: 54, y: 54)) == nil)
        let tracked = PointerLocator.motion(before: before, after: enlarged, origin: CGPoint(x: 54, y: 54), maxBlobSize: 320, expectedTarget: target)!
        precondition(hypot(tracked.end.center.x - target.x, tracked.end.center.y - target.y) < 4)
        // A second independent change cannot be folded into the hover.
        precondition(PointerLocator.motion(before: before, after: frame(CGPoint(x: 900, y: 1200), hover: hover), origin: CGPoint(x: 54, y: 54), maxBlobSize: 320, expectedTarget: target) == nil)
        print("PASS: inset pointer, unchanged and overlapping rejection, enlarged icon hover, unrelated movement rejection")
    }
}
