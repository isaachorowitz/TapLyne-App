import CoreGraphics
import Foundation
import Testing
@testable import TaplyneServer

@Suite struct ScreenTapTargetTests {
    @Test func tabletCaptionsResolveToSmallerDetectedIcons() throws {
        let width = 1535, height = 2048
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let tiles = [CGRect(x: 235, y: 1320, width: 120, height: 120), CGRect(x: 485, y: 1320, width: 120, height: 120)]
        for (index, tile) in tiles.enumerated() {
            context.setFillColor(CGColor(red: index == 0 ? 0.1 : 0.7, green: 0.2, blue: 0.4, alpha: 1))
            let rect = CGRect(x: tile.minX, y: CGFloat(height) - tile.maxY, width: tile.width, height: tile.height)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.fillPath()
        }
        let image = try #require(context.makeImage())
        let elements = tiles.enumerated().map { index, tile in
            ScreenElement(id: String(index), text: "App \(index)", confidence: 1,
                bounds: CGRect(x: tile.minX, y: tile.maxY + 18, width: tile.width, height: 20))
        }
        let screen = ScreenDescription(frameID: "tablet", capturedAt: Date(), width: width, height: height, elements: elements)
        let result = ScreenTapTarget.annotate(screen, image: image)
        for (element, tile) in zip(result.elements, tiles) {
            let target = try #require(element.tapTarget?.cgRect)
            #expect(abs(target.midX - tile.midX) < 10)
            #expect(abs(target.midY - tile.midY) < 10)
        }
    }

    @Test func iconGridTargetsTileButOrdinaryLabelsKeepTheirCenter() {
        let a = ScreenElement(id: "a", text: "Settings", confidence: 1, bounds: CGRect(x: 140, y: 700, width: 120, height: 40))
        let b = ScreenElement(id: "b", text: "Wolt", confidence: 1, bounds: CGRect(x: 460, y: 700, width: 80, height: 40))
        let screen = ScreenDescription(frameID: "f", capturedAt: Date(), width: 1320, height: 2868, elements: [a, b])
        let tiles = [CGRect(x: 100, y: 470, width: 200, height: 200), CGRect(x: 400, y: 470, width: 200, height: 200)]
        #expect(ScreenTapTarget.point(for: a, screen: screen, tiles: tiles) == CGPoint(x: 200, y: 570))
        #expect(ScreenTapTarget.point(for: a, screen: screen, tiles: [tiles[0]]) == nil)
        #expect(ScreenTapTarget.point(for: a, screen: screen, tiles: tiles + [tiles[0].insetBy(dx: 10, dy: 10)]) == nil)
        let unrelated = ScreenElement(id: "u", text: "Continue", confidence: 1, bounds: CGRect(x: 100, y: 1100, width: 200, height: 40))
        #expect(ScreenTapTarget.point(for: unrelated, screen: screen, tiles: tiles) == nil)
    }
}
