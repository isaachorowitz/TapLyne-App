import CoreGraphics

/// Small local fingerprints ignore compression noise; callers also compare OCR and control revisions.
public enum ScreenComparison {
    public static func stableForInput(_ before: CGImage, _ after: CGImage, ignoring points: [CGPoint]) -> Bool {
        guard before.width == after.width, before.height == after.height,
              let a = grayscale(before), let b = grayscale(after) else { return false }
        let width = 128
        let height = a.count / width
        var compared = 0, changed = 0
        for i in a.indices {
            let p = CGPoint(x: Double(i % width) / Double(width) * Double(before.width),
                            y: Double(i / width) / Double(height) * Double(before.height))
            if points.contains(where: { hypot(p.x - $0.x, p.y - $0.y) < 55 }) { continue }
            compared += 1
            if abs(Int(a[i]) - Int(b[i])) > 22 { changed += 1 }
        }
        return compared > 0 && Double(changed) / Double(compared) < 0.004
    }

    public static func changed(_ before: CGImage, _ after: CGImage) -> Bool {
        guard before.width == after.width, before.height == after.height,
              let a = grayscale(before), let b = grayscale(after), a.count == b.count else { return true }
        let changes = zip(a, b).filter { abs(Int($0) - Int($1)) > 22 }.count
        return Double(changes) / Double(a.count) > 0.008
    }

    public static func targetChanged(_ before: CGImage, _ after: CGImage, around point: CGPoint, ignoring points: [CGPoint] = []) -> Bool {
        guard before.width == after.width, before.height == after.height else { return true }
        let rect = CGRect(x: point.x - 70, y: point.y - 70, width: 140, height: 140)
            .intersection(CGRect(x: 0, y: 0, width: before.width, height: before.height)).integral
        guard let a = before.cropping(to: rect), let b = after.cropping(to: rect) else { return true }
        if points.isEmpty { return changed(a, b) }
        return !stableForInput(a, b, ignoring: points.map { CGPoint(x: $0.x - rect.minX, y: $0.y - rect.minY) })
    }

    public static func regionChanged(_ before: CGImage, _ after: CGImage, region: CGRect, ignoring points: [CGPoint]) -> Bool {
        let crop = region.intersection(CGRect(x: 0, y: 0, width: before.width, height: before.height)).integral
        guard before.width == after.width, before.height == after.height,
              let a = before.cropping(to: crop), let b = after.cropping(to: crop) else { return false }
        return !stableForInput(a, b, ignoring: points.map { CGPoint(x: $0.x - crop.minX, y: $0.y - crop.minY) })
    }

    private static func grayscale(_ image: CGImage) -> [UInt8]? {
        let width = 128, height = max(1, min(320, Int(Double(image.height) / Double(image.width) * 128)))
        var data = [UInt8](repeating: 0, count: width * height)
        let success = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return success ? data : nil
    }
}
