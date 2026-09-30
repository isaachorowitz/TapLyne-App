import CoreText
import Foundation
import Testing

@testable import TaplyneServer

@Suite struct ScreenRecognitionTests {
    @Test func realEnglishOCRAndBounds() async throws {
        let screen = try await ScreenRecognition.describe(Self.fixture())
        let label = try screen.uniqueMatch("Hello Taplyne")
        #expect(label.bounds.x > 20 && label.bounds.y < 400)
        #expect(label.bounds.width > 150 && label.confidence >= 0.45)
    }

    @Test(.enabled(if: HebrewOCR.isAvailable, "Install the optional Hebrew OCR models with scripts/install-ocr.sh"))
    func realHebrewOCRAndLabelMatching() async throws {
        let screen = try await ScreenRecognition.describe(Self.fixture())
        let label = try screen.uniqueMatch("שלום עולם")
        #expect(label.source == "tesseract_hebrew")
        #expect(label.bounds.y > 350 && label.bounds.y < 600)
        #expect(screen.warnings.isEmpty)
    }

    static func fixture() -> ScreenImage {
        let context = CGContext(data: nil, width: 800, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
        let font = CTFontCreateWithName("Arial" as CFString, 52, nil)
        for (text, y) in [("Hello Taplyne", 760.0), ("שלום עולם", 520.0)] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]))
            context.textPosition = CGPoint(x: 70, y: y)
            CTLineDraw(line, context)
        }
        return ScreenImage(image: context.makeImage()!, capturedAt: Date())
    }
}
