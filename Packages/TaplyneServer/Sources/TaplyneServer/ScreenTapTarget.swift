import CoreGraphics
import Vision

/// OCR finds an app's caption; Home Screen and Spotlight targets are the icons above it.
/// Infer that target only when the image contains a matching row of square tiles.
enum ScreenTapTarget {
    static func annotate(_ screen: ScreenDescription, image: CGImage) -> ScreenDescription {
        guard screen.elements.contains(where: { a in screen.elements.contains { b in
            a.id != b.id && abs(a.bounds.cgRect.midY - b.bounds.cgRect.midY) < a.bounds.height * 0.6
        } }) else { return screen }
        let request = VNDetectRectanglesRequest()
        request.minimumSize = 0.04; request.minimumAspectRatio = 0.75
        request.maximumAspectRatio = 1; request.maximumObservations = 100
        request.minimumConfidence = 0.8; request.quadratureTolerance = 20
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return screen }
        let tiles = (request.results ?? []).map { observation in
            let b = observation.boundingBox
            return CGRect(x: b.minX * CGFloat(image.width), y: (1 - b.maxY) * CGFloat(image.height),
                          width: b.width * CGFloat(image.width), height: b.height * CGFloat(image.height))
        }.filter { rect in
            // Tablet icons occupy less of the screen than phone icons. A matching
            // caption and square neighbour are still required.
            rect.width >= CGFloat(image.width) * 0.05 && rect.width <= CGFloat(image.width) * 0.25 &&
            rect.height / rect.width >= 0.75 && rect.height / rect.width <= 1.3
        }
        var result = screen
        for index in result.elements.indices {
            if let point = point(for: result.elements[index], screen: screen, tiles: tiles) {
                result.elements[index].tapTarget = ScreenRect(CGRect(x: point.x, y: point.y, width: 0, height: 0))
            }
        }
        return result
    }

    static func point(for element: ScreenElement, screen: ScreenDescription, tiles: [CGRect]) -> CGPoint? {
        let caption = element.bounds.cgRect
        func matches(_ label: CGRect, _ tile: CGRect) -> Bool {
            let gap = label.minY - tile.maxY
            return gap >= -5 && gap <= tile.height * 0.4 &&
                abs(label.midX - tile.midX) <= tile.width * 0.15
        }
        let candidates = tiles.filter { matches(caption, $0) }
        guard candidates.count == 1, let tile = candidates.first else { return nil }
        let neighbours = screen.elements.filter {
            $0.id != element.id && abs($0.bounds.cgRect.midY - caption.midY) < caption.height * 0.6
        }
        let grid = neighbours.contains { label in
            tiles.contains { other in
                abs(other.midX - tile.midX) > tile.width * 1.2 &&
                abs(other.width - tile.width) <= tile.width * 0.3 &&
                abs(other.height - tile.height) <= tile.height * 0.3 && matches(label.bounds.cgRect, other)
            }
        }
        guard grid else { return nil }
        return CGPoint(x: tile.midX, y: tile.midY)
    }
}
