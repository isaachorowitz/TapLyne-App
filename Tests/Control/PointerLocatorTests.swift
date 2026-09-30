import Foundation
import CoreGraphics
@main struct PointerLocatorTests {
    static func frame(_ point: CGPoint) -> CGImage {
        let context = CGContext(data: nil, width: 1320, height: 2868, bitsPerComponent: 8, bytesPerRow: 1320 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1320, height: 2868))
        context.setFillColor(gray: 0.3, alpha: 1)
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
        print("PASS: inset pointer origin, new position, unchanged frame rejection")
    }
}
