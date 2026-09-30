import CoreGraphics
import Foundation

/// Finds the AssistiveTouch pointer by comparing a frame before and after a move.
/// The pointer is the only thing that changed, so it shows up as a blob in the
/// difference; the blob farthest from where the pointer started is where it is now.
enum PointerLocator {
    struct Blob {
        var center: CGPoint     // in full-resolution pixels
        var pixelCount: Int
        var bounds: CGRect
    }

    static let downscale = 4

    /// Grayscale thumbnail used for differencing.
    struct Gray {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init?(_ image: CGImage) {
            let width = image.width / PointerLocator.downscale
            let height = image.height / PointerLocator.downscale
            self.width = width
            self.height = height
            var buffer = [UInt8](repeating: 0, count: width * height)
            let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard ok else { return nil }
            pixels = buffer
        }
    }

    /// Blobs of pixels that differ by more than `threshold`, largest first.
    static func changedBlobs(_ a: Gray, _ b: Gray, threshold: UInt8 = 18, minPixels: Int = 12) -> [Blob] {
        guard a.width == b.width, a.height == b.height else { return [] }
        let w = a.width, h = a.height
        var mask = [Bool](repeating: false, count: w * h)
        for i in 0 ..< w * h {
            let d = Int(a.pixels[i]) - Int(b.pixels[i])
            mask[i] = abs(d) > Int(threshold)
        }
        var seen = [Bool](repeating: false, count: w * h)
        var blobs: [Blob] = []
        var stack: [Int] = []
        for start in 0 ..< w * h where mask[start] && !seen[start] {
            var count = 0, sx = 0, sy = 0
            var minX = w, minY = h, maxX = 0, maxY = 0
            stack.append(start)
            seen[start] = true
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                count += 1; sx += x; sy += y
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                // 8-neighbourhood with a one-pixel gap bridge keeps a ring-shaped pointer in one blob.
                for dy in -2 ... 2 {
                    for dx in -2 ... 2 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let j = ny * w + nx
                        if mask[j], !seen[j] {
                            seen[j] = true
                            stack.append(j)
                        }
                    }
                }
            }
            guard count >= minPixels else { continue }
            let s = CGFloat(downscale)
            blobs.append(Blob(
                center: CGPoint(x: (CGFloat(sx) / CGFloat(count) + 0.5) * s, y: (CGFloat(sy) / CGFloat(count) + 0.5) * s),
                pixelCount: count,
                bounds: CGRect(x: CGFloat(minX) * s, y: CGFloat(minY) * s,
                               width: CGFloat(maxX - minX + 1) * s, height: CGFloat(maxY - minY + 1) * s)
            ))
        }
        return blobs.sorted { $0.pixelCount > $1.pixelCount }
    }

    /// The pointer's new position after it moved away from `origin`, or nil if the
    /// difference does not look like a single moving pointer (the screen changed).
    static func locate(before: CGImage, after: CGImage, origin: CGPoint, maxBlobSize: CGFloat = 320) -> Blob? {
        motion(before: before, after: after, origin: origin, maxBlobSize: maxBlobSize)?.end
    }

    static func motion(before: CGImage, after: CGImage, origin: CGPoint, maxBlobSize: CGFloat = 100, expectedTarget: CGPoint? = nil) -> (start: Blob, end: Blob)? {
        guard let a = Gray(before), let b = Gray(after) else { return nil }
        let blobs = changedBlobs(a, b)
            .filter { $0.bounds.width <= maxBlobSize && $0.bounds.height <= maxBlobSize }
        // AssistiveTouch keeps the circle inset from the edge. Find the actual
        // vanished circle near the anchor rather than treating (0,0) as its center.
        let anchor = blobs.filter { hypot($0.center.x - origin.x, $0.center.y - origin.y) < 150 }
            .min { hypot($0.center.x - origin.x, $0.center.y - origin.y) < hypot($1.center.x - origin.x, $1.center.y - origin.y) }
        guard let anchor else { return nil }
        var candidates = blobs.filter {
            return hypot($0.center.x - anchor.center.x, $0.center.y - anchor.center.y) > max(anchor.bounds.width, anchor.bounds.height)
        }
        if let target = expectedTarget {
            // iOS enlarges an icon beneath the pointer. Its changed outline and
            // the circle can be separate, overlapping blobs from the same hover.
            let nearby = candidates.filter { hypot($0.center.x - target.x, $0.center.y - target.y) < 150 }
            if let largest = nearby.max(by: { $0.pixelCount < $1.pixelCount }) {
                let group = nearby.filter { largest.bounds.insetBy(dx: -12, dy: -12).intersects($0.bounds) }
                let bounds = group.reduce(largest.bounds) { $0.union($1.bounds) }
                guard bounds.width <= maxBlobSize, bounds.height <= maxBlobSize else { return nil }
                let outside = candidates.filter { item in !group.contains { $0.bounds == item.bounds } }
                guard !outside.contains(where: { $0.pixelCount >= max(12, anchor.pixelCount / 2) }) else { return nil }
                let merged = Blob(center: CGPoint(x: bounds.midX, y: bounds.midY),
                                  pixelCount: group.reduce(0) { $0 + $1.pixelCount }, bounds: bounds)
                candidates = outside + [merged]
            }
        }
        guard let best = candidates.max(by: { $0.pixelCount < $1.pixelCount }) else { return nil }
        // Anything else of similar size means the screen itself changed.
        let rivals = candidates.filter { $0.pixelCount > best.pixelCount / 2 }
        return rivals.count == 1 ? (anchor, best) : nil
    }
}
