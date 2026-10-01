import Foundation
import ImageIO
import UniformTypeIdentifiers

/// HTTP is used only inside an endpoint. The relay cannot choose a destination or headers.
enum RelayHTTP {
    static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static func exchange(_ request: RelayRequest, baseURL: URL, maxBytes: Int = 5 * 1024 * 1024) async throws -> RelayResponse {
        var http = URLRequest(url: baseURL.appendingPathComponent(request.path), timeoutInterval: 16)
        http.httpMethod = request.method; http.httpBody = request.body
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization = request.authorization { http.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: http)
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= maxBytes else { throw RelayFailure("Remote response is too large.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxBytes else { throw RelayFailure("Remote response is too large.") }
            data.append(byte)
        }
        return RelayResponse(id: request.id, status: response.statusCode, body: data)
    }
}

enum RelayWDAProxy {
    static func allows(_ request: RelayRequest) -> Bool {
        guard request.isFresh, request.authorization == nil, (request.body?.count ?? 0) <= 100_000 else { return false }
        let simple: [String: Set<String>] = ["GET": ["status", "screenshot"], "POST": ["session", "wda/homescreen"]]
        if simple[request.method]?.contains(request.path) == true { return true }
        guard request.path.range(of: "^session/[A-Za-z0-9-]+(?:/.*)?$", options: .regularExpression) != nil else { return false }
        let parts = request.path.split(separator: "/").map(String.init)
        if parts.count == 2 { return request.method == "DELETE" }
        let suffix = parts.dropFirst(2).joined(separator: "/")
        if request.method == "GET", ["window/size", "element/active"].contains(suffix) { return true }
        if request.method == "POST", ["wda/tap", "wda/doubleTap", "wda/tapWithNumberOfTaps", "wda/touchAndHold", "wda/dragfromtoforduration", "wda/keys", "actions", "element"].contains(suffix) { return true }
        guard suffix.range(of: "^element/[A-Za-z0-9-]+/(name|attribute/value|clear|value)$", options: .regularExpression) != nil else { return false }
        return request.method == "GET" ? (suffix.hasSuffix("/name") || suffix.hasSuffix("/attribute/value")) : request.method == "POST" && (suffix.hasSuffix("/clear") || suffix.hasSuffix("/value"))
    }
    static func handle(_ request: RelayRequest) async -> RelayResponse {
        guard allows(request) else { return .failure(request, status: 403) }
        do {
            let screenshot = request.method == "GET" && request.path == "screenshot"
            let response = try await RelayHTTP.exchange(request, baseURL: URL(string: "http://127.0.0.1:8100")!,
                                                        maxBytes: screenshot ? 16 * 1024 * 1024 : 5 * 1024 * 1024)
            return screenshot && response.status == 200 ? try normalizedScreenshot(response) : response
        }
        catch { return .failure(request) }
    }

    /// WDA returns lossless full-resolution PNGs that can exceed a relay frame.
    /// Preserve aspect ratio; the Mac scales this evidence into native window points.
    static func normalizedScreenshot(_ response: RelayResponse) throws -> RelayResponse {
        guard var json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let value = json["value"] as? String, let data = Data(base64Encoded: value),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw RelayFailure("Runner screenshot is invalid.") }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RelayFailure("Runner screenshot conversion failed.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RelayFailure("Runner screenshot conversion failed.") }
        json["value"] = (jpeg as Data).base64EncodedString()
        let body = try JSONSerialization.data(withJSONObject: json)
        guard body.count <= 5 * 1024 * 1024 else { throw RelayFailure("Runner screenshot exceeds the relay limit.") }
        return RelayResponse(id: response.id, status: response.status, body: body)
    }

}

/// A paired companion can reach only its assigned conversation and credential mint.
enum RelayCompanionPolicy {
    static func allows(_ request: RelayRequest, phoneID: String) -> Bool {
        guard request.isFresh, (request.body?.count ?? 0) <= 100_000,
              request.authorization?.hasPrefix("Bearer ") == true else { return false }
        if request.method == "GET", request.path == "companion/phones" { return true }
        if ["GET", "POST"].contains(request.method), request.path == "companion/conversations/" + phoneID { return true }
        return request.method == "POST" && request.path == "companion/voice/" + phoneID
    }
}
