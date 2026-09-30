import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageEncoding {
    static func png(_ image: CGImage) -> Data? { encode(image, type: UTType.png, quality: nil) }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        encode(image, type: UTType.jpeg, quality: quality)
    }

    /// Size with the long edge at most `maxLongEdge`; never upscales.
    static func fittedSize(width: Int, height: Int, maxLongEdge: Int) -> (width: Int, height: Int) {
        let long = max(width, height)
        guard long > maxLongEdge, long > 0 else { return (width, height) }
        let s = Double(maxLongEdge) / Double(long)
        return (max(1, Int((Double(width) * s).rounded())), max(1, Int((Double(height) * s).rounded())))
    }

    /// Scales onto an opaque RGB canvas (JPEG cannot carry alpha).
    static func scaled(_ image: CGImage, maxLongEdge: Int) -> CGImage? {
        let size = fittedSize(width: image.width, height: image.height, maxLongEdge: maxLongEdge)
        guard
            let context = CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }

    /// A JPEG whose long edge is at most `maxLongEdge`, plus its pixel size.
    static func jpegFitting(_ image: CGImage, maxLongEdge: Int, quality: Double) -> (data: Data, width: Int, height: Int)? {
        guard let small = scaled(image, maxLongEdge: maxLongEdge), let data = jpeg(small, quality: quality) else { return nil }
        return (data, small.width, small.height)
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
