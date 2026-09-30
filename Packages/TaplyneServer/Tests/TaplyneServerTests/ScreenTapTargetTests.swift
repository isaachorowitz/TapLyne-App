import CoreGraphics
import Foundation
import Testing
@testable import TaplyneServer

@Suite struct ScreenTapTargetTests {
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
