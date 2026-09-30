import Foundation
import Vision

public enum ScreenRecognition {
    public static func describe(_ image: ScreenImage, frameID: String = UUID().uuidString) async throws -> ScreenDescription {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = true
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = ["en-US", "he-IL"].filter { supported.contains($0) }
            try VNImageRequestHandler(cgImage: image.image, options: [:]).perform([request])
            try Task.checkCancellation()
            var elements = (request.results ?? []).compactMap { observation -> ScreenElement? in
                guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
                let r = observation.boundingBox
                let bounds = CGRect(x: r.minX * Double(image.width), y: (1 - r.maxY) * Double(image.height),
                                    width: r.width * Double(image.width), height: r.height * Double(image.height))
                return ScreenElement(text: candidate.string, confidence: Double(candidate.confidence), bounds: bounds)
            }
            var warnings: [String] = []
            if !supported.contains(where: { $0.hasPrefix("he") }) {
                if HebrewOCR.isAvailable {
                    do {
                        let hebrew = try await HebrewOCR.recognize(image)
                        // Vision can misread Hebrew as Latin. Replace overlapping guesses with the Hebrew result.
                        elements.removeAll { e in hebrew.contains { h in
                            let overlap = e.bounds.cgRect.intersection(h.bounds.cgRect)
                            return !overlap.isNull && overlap.width * overlap.height > e.bounds.width * e.bounds.height * 0.35
                        } }
                        elements += hebrew
                    } catch is CancellationError { throw CancellationError() }
                    catch { warnings.append("Hebrew OCR failed. Do not guess Hebrew labels; use a current screenshot or install the local OCR models again.") }
                } else {
                    warnings.append("Hebrew OCR is not installed. Run scripts/install-ocr.sh. Apple Vision on this Mac does not recognize Hebrew.")
                }
            }
            elements.sort {
                abs($0.bounds.y - $1.bounds.y) > 10 ? $0.bounds.y < $1.bounds.y : $0.bounds.x < $1.bounds.x
            }
            for i in elements.indices { elements[i].id = "\(frameID):\(i)" }
            return ScreenDescription(frameID: frameID, capturedAt: image.capturedAt, width: image.width,
                                     height: image.height, elements: elements, warnings: warnings)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
