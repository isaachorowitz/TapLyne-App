import Foundation
import ImageIO
import TaplyneServer

/// Optional XCTest transport. The endpoint must already run a trusted WebDriverAgent.
/// It does not install a runner, change Developer Mode or expose a public listener.
@MainActor
final class WebDriverConnection {
    typealias Exchange = @MainActor (String, String, Data?) async throws -> (Data, Int)

    let endpoint: URL
    private let session: URLSession
    private let exchange: Exchange?
    private var sessionID: String?
    private var connecting: Task<String, Error>?

    init(endpoint: URL, session: URLSession = PrivateHTTPClient.session, exchange: Exchange? = nil) throws {
        guard EndpointPolicy.allows(endpoint) else {
            throw PhoneServiceError.invalidArgument("Use the HTTP or HTTPS address of your private WebDriverAgent endpoint.")
        }
        self.endpoint = endpoint
        self.session = session
        self.exchange = exchange
    }

    func close() async {
        guard let id = sessionID else { return }
        sessionID = nil
        // A close is best effort and bounded. It only targets the session this
        // connection created, and is never retried because the outcome is not
        // relevant to delivery of a user action.
        if let exchange {
            await boundedClose { try await exchange("DELETE", "session/" + id, nil) }
        } else {
            let endpoint = endpoint; let session = session
            await Task.detached {
                var request = URLRequest(url: endpoint.appendingPathComponent("session/" + id), timeoutInterval: 3)
                request.httpMethod = "DELETE"
                _ = try? await session.data(for: request)
            }.value
        }
    }

    func screenshot() async throws -> ScreenImage {
        let result = try await request("GET", "screenshot")
        guard let encoded = result["value"] as? String, let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PhoneServiceError.failed("The remote device returned an invalid screenshot.")
        }
        return ScreenImage(image: image, capturedAt: Date())
    }

    func perform(_ action: PhoneAction, image: ScreenImage) async throws -> InputReceipt {
        let id = try await ensureSession()
        let root = "session/\(id)/"
        let size = try await request("GET", root + "window/size")["value"] as? [String: Any] ?? [:]
        guard let width = size["width"] as? Double, let height = size["height"] as? Double,
              width > 0, height > 0,
              abs(width / height - Double(image.width) / Double(image.height)) < 0.03 else {
            throw PhoneServiceError.failed("The remote screen orientation changed. Describe it again before acting.")
        }
        func point(_ x: Int, _ y: Int) throws -> [String: Any] {
            guard x >= 0, y >= 0, x < image.width, y < image.height else { throw PhoneServiceError.invalidArgument("Point is outside the current screen.") }
            return ["x": Double(x) * width / Double(image.width), "y": Double(y) * height / Double(image.height)]
        }
        func drag(_ x: Int, _ y: Int, _ ex: Int, _ ey: Int, hold: Double) async throws {
            let a = try point(x, y), b = try point(ex, ey)
            _ = try await request("POST", root + "wda/dragfromtoforduration", ["fromX": a["x"]!, "fromY": a["y"]!, "toX": b["x"]!, "toY": b["y"]!, "duration": hold])
        }
        try Task.checkCancellation()
        do {
            switch action {
            case let .tap(x, y): _ = try await request("POST", root + "wda/tap", point(x, y))
            case let .doubleTap(x, y): _ = try await request("POST", root + "wda/doubleTap", point(x, y))
            case let .tripleTap(x, y):
                var body = try point(x, y); body["numberOfTaps"] = 3; body["numberOfTouches"] = 1
                _ = try await request("POST", root + "wda/tapWithNumberOfTaps", body)
            case let .tapAndHold(x, y, ms):
                var body = try point(x, y); body["duration"] = Double(ms) / 1000
                _ = try await request("POST", root + "wda/touchAndHold", body)
            case let .drag(x, y, ex, ey, _): try await drag(x, y, ex, ey, hold: 0.1)
            case let .holdAndDrag(x, y, ex, ey, ms, _): try await drag(x, y, ex, ey, hold: Double(ms) / 1000)
            case let .flick(x, y, direction):
                let dx = direction == .left ? -image.width / 2 : direction == .right ? image.width / 2 : 0
                let dy = direction == .up ? -image.height / 2 : direction == .down ? image.height / 2 : 0
                try await drag(x, y, max(1, min(image.width - 2, x + dx)), max(1, min(image.height - 2, y + dy)), hold: 0.05)
            case let .type(text): return try await textInput(text, replace: false, root: root)
            case let .setText(text): return try await textInput(text, replace: true, root: root)
            case let .keypress(key, modifiers, count):
                guard modifiers.isEmpty else { throw PhoneServiceError.invalidArgument("Remote keyboard modifiers are not supported.") }
                let mapping: [KeyName: String] = [.enter: "\n", .backspace: "\u{8}", .space: " ", .tab: "\t"]
                guard let character = mapping[key], count > 0, count <= 100 else { throw PhoneServiceError.invalidArgument("This key is not supported by the remote input transport.") }
                _ = try await request("POST", root + "wda/keys", ["value": [String(repeating: character, count: count)]])
            case .home, .navigate(.home): _ = try await request("POST", "wda/homescreen", [:])
            case .navigate(.back): try await drag(1, image.height / 2, image.width * 3 / 4, image.height / 2, hold: 0.1)
            case .navigate(.notifications): try await drag(image.width / 3, 1, image.width / 3, image.height * 3 / 4, hold: 0.1)
            case .navigate(.controlCenter): try await drag(image.width - 2, 1, image.width - 2, image.height * 3 / 4, hold: 0.1)
            case .navigate(.appSwitcher): try await drag(image.width / 2, image.height - 2, image.width / 2, image.height / 2, hold: 0.5)
            case .navigate(.dismissKeyboard):
                throw PhoneServiceError.invalidArgument("Use a visible keyboard-dismiss control on this remote device.")
            }
        } catch {
            // HTTP cancellation cannot prove a gesture did not reach XCTest.
            throw InputFailure(error, delivery: .unknown)
        }
        return InputReceipt()
    }

    private func textInput(_ text: String, replace: Bool, root: String) async throws -> InputReceipt {
        guard text.count <= 8_192 else { throw PhoneServiceError.invalidArgument("Text must be at most 8192 characters.") }
        let focused = try await request("GET", root + "element/active")["value"] as? [String: Any] ?? [:]
        guard let element = focused["element-6066-11e4-a52e-4f735466cecf"] as? String ?? focused["ELEMENT"] as? String,
              element.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else {
            throw PhoneServiceError.failed("The remote device has no focused editable field. No text was sent.")
        }
        let path = root + "element/\(element)/"
        let type = try await request("GET", path + "name")["value"] as? String ?? ""
        let isTextView = type == "XCUIElementTypeTextView"
        guard ["XCUIElementTypeTextField", "XCUIElementTypeTextView", "XCUIElementTypeSearchField"].contains(type) else {
            throw PhoneServiceError.failed("The focused control is not a supported text field. Password fields are excluded.")
        }
        // Set the value directly so multiline TextViews retain their newlines.
        // Tab is always rejected because it can move focus. Newline is safe only
        // for a genuine TextView; sending it to a single-line field can submit.
        guard !text.contains("\t") else {
            throw PhoneServiceError.invalidArgument("Remote field entry does not accept Tab because it can move focus.")
        }
        guard isTextView || (!text.contains("\n") && !text.contains("\r")) else {
            throw PhoneServiceError.invalidArgument("Newline is only supported in a multiline TextView.")
        }
        try Task.checkCancellation()
        if replace { _ = try await request("POST", path + "clear", [:]) }
        try Task.checkCancellation()
        if !text.isEmpty { _ = try await request("POST", path + "value", ["text": text]) }
        let readback = try await request("GET", path + "attribute/value")["value"] as? String
        let passed = readback.map { replace ? $0 == text : $0.contains(text) }
        return InputReceipt(textVerification: Verification(passed == true ? .verified : passed == false ? .failed : .unverified,
            method: replace ? "remote_exact_readback" : "remote_fragment_readback",
            detail: passed == true ? "The focused field contains the requested Unicode text." : "Remote field readback did not confirm the text. Inspect the field before continuing."))
    }

    private func ensureSession() async throws -> String {
        if let sessionID { return sessionID }
        if let connecting { return try await connecting.value }
        let task = Task { @MainActor in
            let response = try await request("POST", "session", ["capabilities": ["alwaysMatch": ["shouldUseCompactResponses": true]]])
            let value = response["value"] as? [String: Any] ?? [:]
            guard let id = response["sessionId"] as? String ?? value["sessionId"] as? String,
                  id.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else {
                throw PhoneServiceError.failed("The remote automation session could not start.")
            }
            return id
        }
        connecting = task
        defer { connecting = nil }
        sessionID = try await task.value
        return sessionID!
    }

    private func request(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let data: Data
        let statusCode: Int
        if let exchange {
            (data, statusCode) = try await exchange(method, path, bodyData)
        } else {
            var request = URLRequest(url: endpoint.appendingPathComponent(path), timeoutInterval: 15)
            request.httpMethod = method
            if let bodyData {
                request.httpBody = bodyData
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let result = try await session.data(for: request)
            data = result.0
            guard let response = result.1 as? HTTPURLResponse else {
                throw PhoneServiceError.failed("The remote device did not return an HTTP response. Inspect it before retrying.")
            }
            statusCode = response.statusCode
        }
        try Task.checkCancellation()
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // WDA sends useful session errors in JSON even for HTTP 4xx/5xx. Parse
        // that body before generic status handling so a dead cached session is
        // forgotten. The failed request is never replayed because its delivery
        // is already uncertain.
        let wdaError = object.flatMap { object in
            (object["value"] as? [String: Any])?["error"] as? String ?? object["error"] as? String
        }
        if let code = wdaError {
            if code == "invalid session id" { sessionID = nil }
            throw PhoneServiceError.failed("Remote automation returned \(code). Input was not retried.")
        }
        guard (200..<300).contains(statusCode), let object else {
            throw PhoneServiceError.failed("The remote device did not confirm the request. Inspect it before retrying.")
        }
        return object
    }

    private func boundedClose(_ operation: @escaping @Sendable () async throws -> (Data, Int)) async {
        let (finished, signal) = AsyncStream<Void>.makeStream()
        let requestTask = Task {
            defer { signal.yield(()); signal.finish() }
            _ = try? await operation()
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in finished { break }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            _ = await group.next()
            group.cancelAll()
        }
        requestTask.cancel()
        // Session teardown is best effort. It must never turn close into a
        // user-visible input failure or trigger another DELETE.
    }
}
