import Foundation

/// A parsed HTTP/1.1 request.
struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    /// Header names are lowercased.
    var headers: [String: String]
    var body: Data
    var version: String

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var wantsClose: Bool {
        let value = header("connection")?.lowercased() ?? ""
        if version == "HTTP/1.0" { return !value.contains("keep-alive") }
        return value.contains("close")
    }
}

/// Writes chunks of a streaming response. Returns false once the client is gone.
struct StreamWriter: Sendable {
    let write: @Sendable (Data) async -> Bool
}

enum HTTPBody: Sendable {
    case data(Data)
    case stream(@Sendable (StreamWriter) async -> Void)
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [(String, String)]
    var body: HTTPBody

    init(status: Int, headers: [(String, String)] = [], body: HTTPBody = .data(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status, headers: [("Content-Type", "application/json")],
            body: .data(JSON.data(object)))
    }

    static func data(_ data: Data, contentType: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", contentType)], body: .data(data))
    }

    static func html(_ html: String, status: Int = 200) -> HTTPResponse {
        .data(Data(html.utf8), contentType: "text/html; charset=utf-8", status: status)
    }

    static func empty(_ status: Int) -> HTTPResponse { HTTPResponse(status: status) }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }

    /// The status line and headers. `length` is nil for streams and 204/202 style empties.
    func head(keepAlive: Bool, contentLength: Int?) -> Data {
        var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        if let contentLength { text += "Content-Length: \(contentLength)\r\n" }
        text += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return Data(text.utf8)
    }
}

enum HTTPParseResult {
    case needMore
    case request(HTTPRequest)
    case failure(status: Int, message: String)
}

enum HTTPParser {
    static let maxBody = 10 * 1024 * 1024
    static let maxHead = 64 * 1024
    private static let terminator = Data("\r\n\r\n".utf8)

    /// Consumes one request from the front of `buffer` when complete.
    static func parse(_ buffer: inout Data) -> HTTPParseResult {
        guard let end = buffer.range(of: terminator) else {
            return buffer.count > maxHead
                ? .failure(status: 431, message: "Request headers too large") : .needMore
        }
        guard end.lowerBound <= maxHead else {
            return .failure(status: 431, message: "Request headers too large")
        }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8)
        else { return .failure(status: 400, message: "Malformed request head") }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            return .failure(status: 400, message: "Malformed request line")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .failure(status: 400, message: "Malformed header")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        if let te = headers["transfer-encoding"], te.lowercased() != "identity" {
            return .failure(status: 411, message: "Chunked request bodies are not supported; send Content-Length")
        }
        var length = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else {
                return .failure(status: 400, message: "Invalid Content-Length")
            }
            guard n <= maxBody else {
                return .failure(status: 413, message: "Request body exceeds 10 MB")
            }
            length = n
        }
        let bodyStart = end.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return .needMore }
        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)])
        buffer.removeSubrange(buffer.startIndex..<buffer.index(bodyStart, offsetBy: length))

        let target = String(parts[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let path = components?.percentEncodedPath.removingPercentEncoding ?? target
        return .request(
            HTTPRequest(
                method: String(parts[0]).uppercased(), path: path, query: query,
                headers: headers, body: body, version: String(parts[2])))
    }
}
