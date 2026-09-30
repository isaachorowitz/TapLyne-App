import CoreGraphics
import Foundation

public struct ScreenRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ rect: CGRect) {
        x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct ScreenElement: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var confidence: Double
    /// Native pixels, top-left origin. These are OCR bounds, not native accessibility bounds.
    public var bounds: ScreenRect
    public var source: String

    public init(id: String = UUID().uuidString, text: String, confidence: Double, bounds: CGRect, source: String = "vision_ocr") {
        self.id = id; self.text = text; self.confidence = confidence
        self.bounds = ScreenRect(bounds); self.source = source
    }
}

public struct ScreenDescription: Codable, Sendable, Equatable {
    public var frameID: String
    public var capturedAt: Date
    public var width: Int
    public var height: Int
    public var elements: [ScreenElement]
    public var warnings: [String]

    public var text: String { elements.map(\.text).joined(separator: "\n") }

    public init(frameID: String, capturedAt: Date, width: Int, height: Int, elements: [ScreenElement], warnings: [String] = []) {
        self.frameID = frameID; self.capturedAt = capturedAt; self.width = width
        self.height = height; self.elements = elements; self.warnings = warnings
    }

    public func canVerifyText(_ needle: String) -> Bool {
        let hebrew = needle.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) }
        return !hebrew || !warnings.contains { $0.contains("Hebrew OCR") }
    }

    public func matches(_ label: String, exact: Bool = true) -> [ScreenElement] {
        let needle = Self.normalized(label)
        guard !needle.isEmpty else { return [] }
        return elements.filter {
            let candidate = Self.normalized($0.text)
            return $0.confidence >= 0.45 && (exact ? candidate == needle : candidate.contains(needle))
        }
    }

    public func uniqueMatch(_ label: String, exact: Bool = true) throws -> ScreenElement {
        let found = matches(label, exact: exact)
        guard !found.isEmpty else { throw PhoneServiceError.failed("LABEL_NOT_FOUND: No visible match for \(label). Describe the screen or scroll to it.") }
        guard found.count == 1 else { throw PhoneServiceError.failed("AMBIGUOUS_LABEL: \(found.count) matches for \(label). Use an element_id from describe_screen.") }
        return found[0]
    }

    /// Normalize canonical Unicode and harmless display direction controls, preserving punctuation and emoji.
    public static func normalized(_ text: String) -> String {
        let controls: Set<UInt32> = [0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
        let scalars = text.unicodeScalars.filter { !controls.contains($0.value) }
        return String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    func json(maxEdge: Int? = nil) -> [String: Any] {
        let fit = maxEdge.map { ImageEncoding.fittedSize(width: width, height: height, maxLongEdge: $0) } ?? (width, height)
        let sx = Double(fit.0) / Double(width), sy = Double(fit.1) / Double(height)
        return [
            "frame_id": frameID, "captured_at": JSON.iso(capturedAt), "width": fit.0, "height": fit.1,
            "coordinate_space": maxEdge == nil ? "native_pixels" : "screenshot_pixels",
            "source": "local_ocr", "native_accessibility_tree": false,
            "text": text, "warnings": warnings,
            "elements": elements.map { e -> [String: Any] in
                ["id": e.id, "text": e.text, "confidence": e.confidence, "source": e.source,
                 "bounds": ["x": e.bounds.x * sx, "y": e.bounds.y * sy, "width": e.bounds.width * sx, "height": e.bounds.height * sy],
                 "tap_x": e.bounds.cgRect.midX * sx, "tap_y": e.bounds.cgRect.midY * sy,
                 "normalized_frame": ["x": e.bounds.x / Double(width), "y": e.bounds.y / Double(height),
                                      "width": e.bounds.width / Double(width), "height": e.bounds.height / Double(height)]]
            },
        ]
    }
}

public enum VerificationStatus: String, Codable, Sendable {
    case verified, unverified, failed
}

public struct Verification: Codable, Sendable, Equatable {
    public var status: VerificationStatus
    public var method: String
    public var detail: String

    public init(_ status: VerificationStatus, method: String, detail: String) {
        self.status = status; self.method = method; self.detail = detail
    }
}

public struct ActionExpectation: Sendable, Equatable {
    public var textPresent: String?
    public var textAbsent: String?
    public var screenChanged: Bool?

    public init(textPresent: String? = nil, textAbsent: String? = nil, screenChanged: Bool? = nil) {
        self.textPresent = textPresent; self.textAbsent = textAbsent; self.screenChanged = screenChanged
    }

    public var isEmpty: Bool { textPresent == nil && textAbsent == nil && screenChanged == nil }
}

public struct ObservedAction: @unchecked Sendable {
    public var screen: ScreenDescription
    public var image: ScreenImage
    public var verification: Verification
    public var inputDelivered: Bool
    public var completedSteps: Int = 0

    public init(screen: ScreenDescription, image: ScreenImage, verification: Verification, inputDelivered: Bool = true) {
        self.screen = screen; self.image = image; self.verification = verification; self.inputDelivered = inputDelivered
    }

    func json(maxEdge: Int? = nil) -> [String: Any] {
        ["input_delivered": inputDelivered, "completed_steps": completedSteps,
         "verification": ["status": verification.status.rawValue, "method": verification.method, "detail": verification.detail],
         "screen": screen.json(maxEdge: maxEdge)]
    }
}
