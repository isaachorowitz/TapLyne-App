import Foundation

/// Local OCR fallback for systems whose Vision models do not include Hebrew.
enum HebrewOCR {
    static var executable: URL? {
        ["/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }.map(URL.init(fileURLWithPath:))
    }

    static var models: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Taplyne/OCR", isDirectory: true)
    }

    static var isAvailable: Bool {
        executable != nil && ["heb", "eng"].allSatisfy {
            FileManager.default.fileExists(atPath: models.appendingPathComponent("\($0).traineddata").path)
        }
    }

    static func recognize(_ image: ScreenImage) async throws -> [ScreenElement] {
        guard let executable, isAvailable, let data = ImageEncoding.png(image.image) else { return [] }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("taplyne-ocr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("frame.png")
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let result = try await LocalProcess.run(executable, arguments: [file.path, "stdout", "--tessdata-dir", models.path,
                                                                       "-l", "heb+eng", "--oem", "1", "--psm", "11", "-c", "tessedit_create_tsv=1"], timeout: 8)
        return parse(result).filter { $0.text.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) } }
    }

    static func parse(_ tsv: String) -> [ScreenElement] {
        struct Line {
            var words: [String] = []
            var bounds = CGRect.null
            var confidence = 0.0
        }
        var lines: [String: Line] = [:]
        var order: [String] = []
        for row in tsv.split(separator: "\n").dropFirst() {
            let c = row.split(separator: "\t", maxSplits: 11, omittingEmptySubsequences: false)
            guard c.count == 12, c[0] == "5", !c[11].isEmpty,
                  let x = Double(c[6]), let y = Double(c[7]), let w = Double(c[8]), let h = Double(c[9]),
                  let confidence = Double(c[10]), confidence >= 30, w > 0, h > 0 else { continue }
            let key = c[1...4].joined(separator: ":")
            if lines[key] == nil { lines[key] = Line(); order.append(key) }
            var line = lines[key] ?? Line()
            line.words.append(String(c[11]))
            line.bounds = line.bounds.union(CGRect(x: x, y: y, width: w, height: h))
            line.confidence += confidence / 100
            lines[key] = line
        }
        return order.compactMap { key in
            guard let line = lines[key], !line.words.isEmpty else { return nil }
            return ScreenElement(text: line.words.joined(separator: " "), confidence: line.confidence / Double(line.words.count),
                                 bounds: line.bounds, source: "tesseract_hebrew")
        }
    }
}
