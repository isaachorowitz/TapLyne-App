import Foundation

/// MJPEG stream and the small HTML dashboard.
final class LiveView: Sendable {
    let controller: PhoneController
    static let boundary = "taplyneframe"
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static let minFrameInterval: TimeInterval = 0.1

    init(controller: PhoneController) { self.controller = controller }

    func stream(phoneID: String) async -> HTTPResponse {
        let frames: AsyncStream<ScreenImage>
        do {
            _ = try await controller.phone(phoneID)
            frames = try await controller.service.liveFrames(phoneID: phoneID)
        } catch let e as APIError {
            return e.response
        } catch {
            return APIError.from(error, phoneID: phoneID).response
        }
        let boundary = Self.boundary
        return HTTPResponse(
            status: 200,
            headers: [
                ("Content-Type", "multipart/x-mixed-replace; boundary=\(boundary)"),
                ("Cache-Control", "no-store"),
            ],
            body: .stream { writer in
                var last = Date.distantPast
                for await frame in frames {
                    if Task.isCancelled { break }
                    let now = Date()
                    guard now.timeIntervalSince(last) >= Self.minFrameInterval else { continue }
                    guard let jpeg = ImageEncoding.jpegFitting(frame.image, maxLongEdge: 1000, quality: 0.7) else { continue }
                    last = now
                    var chunk = Data("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.data.count)\r\n\r\n".utf8)
                    chunk.append(jpeg.data)
                    chunk.append(Data("\r\n".utf8))
                    if !(await writer.write(chunk)) { break }
                }
            })
    }

    func keyRequiredPage() -> HTTPResponse {
        .html(
            """
            <!doctype html><meta charset="utf-8"><title>Taplyne</title>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <body style="font:16px system-ui;padding:2rem"><h1>Taplyne</h1>
            <p>Open this page with your API key: <code>/?key=tl_&hellip;</code></p></body>
            """, status: 401)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    func dashboard(key: String) async -> HTTPResponse {
        let phones = await controller.service.listPhones()
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
        var cards = ""
        for p in phones {
            let title = Self.escape(p.displayName ?? p.name)
            let reason = p.statusReason.map { "<p class=\"reason\">\(Self.escape($0))</p>" } ?? ""
            let id = p.id.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
            let live =
                p.connectionStatus == .offline
                ? "" : "<img alt=\"Live view of \(title)\" src=\"/stream/\(id)?key=\(encodedKey)\">"
            cards += "<section><h2>\(title)</h2><p class=\"s \(p.connectionStatus.rawValue)\">\(p.connectionStatus.rawValue)</p>\(reason)\(live)</section>"
        }
        if phones.isEmpty { cards = "<p>No phones yet.</p>" }
        return .html(
            """
            <!doctype html><html lang="en"><meta charset="utf-8"><title>Taplyne</title>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
            :root{color-scheme:light dark;--bg:#fff;--fg:#1c1c1e;--card:#f2f2f7;--mute:#6e6e73}
            @media (prefers-color-scheme:dark){:root{--bg:#000;--fg:#f5f5f7;--card:#1c1c1e;--mute:#98989d}}
            body{margin:0;padding:1.5rem;background:var(--bg);color:var(--fg);font:16px system-ui,sans-serif}
            main{display:flex;flex-wrap:wrap;gap:1rem}
            section{background:var(--card);border-radius:14px;padding:1rem;width:320px}
            h1{margin-top:0}h2{margin:0 0 .25rem;font-size:1.1rem}
            .s{margin:0 0 .5rem;font-weight:600;color:var(--mute)}.s.online{color:#30a14e}
            .reason{color:var(--mute);margin:.25rem 0 .75rem;font-size:.9rem}
            img{width:100%;height:auto;border-radius:10px;background:#000;display:block}
            </style>
            <body><h1>Taplyne</h1><main>\(cards)</main></body></html>
            """)
    }
}
