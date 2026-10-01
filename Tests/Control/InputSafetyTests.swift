import AppKit
import TaplyneServer

// The executable links the production driver to this deterministic transport.
@MainActor final class ClassicHIDTransport {
    var readyAddresses: Set<String> = ["test"]
    var reports: [(ReportID, Data)] = []
    func send(_ data: Data, reportID: ReportID, address: String) async -> Bool {
        if Task.isCancelled { return false }
        reports.append((reportID, data)); return readyAddresses.contains(address)
    }
}

@main struct InputSafetyTests {
    @MainActor static func main() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("taplyne-test-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let original = NSPasteboardItem()
        original.setString("Original 👋 שלום", forType: .string)
        original.setData(Data([1, 2, 3]), forType: .rtf)
        board.writeObjects([original])
        let lease = ClipboardLease(board: board)
        try lease.write("Temporary")
        lease.restoreIfOwned()
        precondition(board.string(forType: .string) == "Original 👋 שלום")
        precondition(board.data(forType: .rtf) == Data([1, 2, 3]))
        let concurrent = ClipboardLease(board: board)
        try concurrent.write("Temporary")
        board.clearContents(); board.setString("New user content", forType: .string)
        do { try concurrent.checkOwned(); preconditionFailure("User clipboard write was ignored") } catch {}
        concurrent.restoreIfOwned()
        precondition(board.string(forType: .string) == "New user content")

        let unknown = ClipboardLease(board: board)
        try unknown.write("sentinel")
        board.clearContents(); board.setString("Phone or user copy", forType: .string)
        let received = try await unknown.receive(excluding: "sentinel", timeoutMs: 100)
        precondition(received == "Phone or user copy")
        unknown.restoreIfOwned()
        precondition(board.string(forType: .string) == "Phone or user copy")
        board.clearContents()
        let protected = NSPasteboardItem()
        protected.setString("secret", forType: .string)
        protected.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        board.writeObjects([protected])
        let concealed = ClipboardLease(board: board)
        try concealed.write("temporary")
        concealed.restoreIfOwned()
        precondition(board.string(forType: .string) == nil)

        let transport = ClassicHIDTransport()
        var profile = PointerProfile(); profile.anchorReports = 1; profile.intervalMs = 0; profile.settleMs = 0
        let driver = PhoneDriver(bluetooth: transport, address: "test", profile: profile, screen: CGSize(width: 800, height: 1000))
        do { _ = try await driver.perform(.tap(x: 350, y: 450)); preconditionFailure("Clicked without pointer evidence") } catch {}
        precondition(!transport.reports.contains { $0.0 == .mouse && $0.1.first == 1 })
        precondition(transport.reports.suffix(3).map { $0.0 } == [.mouse, .keyboard, .consumerControl])
        precondition(transport.reports.suffix(3).allSatisfy { $0.1.allSatisfy { $0 == 0 } })
        transport.reports.removeAll()
        var frames = 0
        driver.frameProvider = {
            frames += 1
            let ctx = CGContext(data: nil, width: 800, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: frames == 1 ? 0.2 : 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
            return ScreenImage(image: ctx.makeImage()!, capturedAt: Date())
        }
        do { _ = try await driver.perform(.tap(x: 350, y: 450)); preconditionFailure("Clicked after page changed during anchor") }
        catch let error as InputFailure { precondition(error.delivery == .notDelivered) }
        precondition(!transport.reports.contains { $0.0 == .mouse && $0.1.first == 1 })
        transport.reports.removeAll()

        // Complete the same anchor, hover and click path used on the phone.
        // The icon grows around the target, but unrelated content must stay put.
        func pointerFrame(_ point: CGPoint, hover: Bool = false, pageChange: Bool = false) -> ScreenImage {
            let context = CGContext(data: nil, width: 1320, height: 2868, bitsPerComponent: 8, bytesPerRow: 5280,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(gray: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 1320, height: 2868))
            context.setFillColor(gray: 0.4, alpha: 1)
            if hover { context.fill(CGRect(x: 394, y: 2868 - 686, width: 240, height: 232)) }
            context.fillEllipse(in: CGRect(x: point.x - 28, y: 2868 - point.y - 28, width: 56, height: 56))
            if pageChange { context.fill(CGRect(x: 700, y: 300, width: 500, height: 500)) }
            return ScreenImage(image: context.makeImage()!, capturedAt: Date())
        }
        profile.anchorPoint = CGPoint(x: 54, y: 54); profile.gain = 1; profile.verifiedErrorPx = 28
        let hovering = PhoneDriver(bluetooth: transport, address: "test", profile: profile, screen: CGSize(width: 1320, height: 2868))
        var hoverFrames = 0
        hovering.frameProvider = {
            hoverFrames += 1
            if hoverFrames == 1 { return pointerFrame(CGPoint(x: 900, y: 1200)) }
            if hoverFrames == 2 { return pointerFrame(CGPoint(x: 54, y: 54)) }
            if hoverFrames == 3 { return pointerFrame(CGPoint(x: 514, y: 650)) }
            return pointerFrame(CGPoint(x: 514, y: 570), hover: true)
        }
        _ = try await hovering.perform(.tap(x: 514, y: 570))
        precondition(transport.reports.filter { $0.0 == .mouse && $0.1.first == 1 }.count == 1)
        transport.reports.removeAll()
        var reusedFrames = 0
        hovering.frameProvider = {
            reusedFrames += 1
            return reusedFrames <= 2 ? pointerFrame(CGPoint(x: 514, y: 570), hover: true) :
                pointerFrame(CGPoint(x: 514, y: 1000))
        }
        _ = try await hovering.perform(.tap(x: 514, y: 1000))
        precondition(transport.reports.filter { $0.0 == .mouse && $0.1.first == 1 }.count == 1)
        precondition(!transport.reports.contains { $0.0 == .mouse && $0.1 == MouseReport(dX: -127, dY: -127).data })
        transport.reports.removeAll(); hovering.invalidatePointer(); hoverFrames = 0
        hovering.frameProvider = {
            hoverFrames += 1
            if hoverFrames == 1 { return pointerFrame(CGPoint(x: 900, y: 1200)) }
            if hoverFrames == 2 { return pointerFrame(CGPoint(x: 54, y: 54)) }
            return pointerFrame(CGPoint(x: 514, y: 570), hover: true, pageChange: true)
        }
        do { _ = try await hovering.perform(.tap(x: 514, y: 570)); preconditionFailure("Clicked after unrelated content changed") }
        catch let error as InputFailure { precondition(error.delivery == .notDelivered) }
        precondition(!transport.reports.contains { $0.0 == .mouse && $0.1.first == 1 })
        precondition(transport.reports.contains { $0.0 == .mouse && $0.1 == MouseReport(dX: -127, dY: -127).data })
        transport.reports.removeAll()
        let typing = PhoneDriver(bluetooth: transport, address: "test", profile: profile, screen: CGSize(width: 1320, height: 2868))
        typing.frameProvider = { pointerFrame(CGPoint(x: 54, y: 54)) }
        let typed = try await typing.perform(.type(text: "Settings"))
        precondition(typed.textVerification?.status == .unverified)
        let keys = transport.reports.filter { $0.0 == .keyboard }.compactMap { $0.1.count > 2 ? $0.1[2] : nil }.filter { $0 != 0 }
        precondition(keys == "Settings".compactMap { KeyMap.stroke(for: $0)?.key.rawValue })
        precondition(!keys.contains(Keycode.return.rawValue) && !keys.contains(Keycode.tab.rawValue))
        transport.reports.removeAll()
        driver.isCalibrating = true
        let active = Task { try await driver.perform(.tapAndHold(x: 350, y: 450, durationMs: 1000)) }
        while !transport.reports.contains(where: { $0.0 == .mouse && $0.1.first == 1 }) { await Task.yield() }
        active.cancel()
        do { _ = try await active.value; preconditionFailure("Hold ignored cancellation") } catch let error as InputFailure { precondition(error.delivery == .delivered) }
        precondition(transport.reports.suffix(3).map { $0.0 } == [.mouse, .keyboard, .consumerControl])
        precondition(transport.reports.suffix(3).allSatisfy { $0.1.allSatisfy { $0 == 0 } })
        precondition(driver.pointer == nil)
        try await remoteInput()
        print("PASS: clipboard ownership, missing pointer rejection, complete hover click, verified pointer reuse, reanchor after invalidation, unrelated page change rejection, cancellation releases")
    }
}


extension InputSafetyTests {
    @MainActor static func remoteInput() async throws {
        precondition(EndpointPolicy.allows(URL(string: "https://example.com")!))
        precondition(EndpointPolicy.allows(URL(string: "http://192.168.1.4:8100")!))
        precondition(EndpointPolicy.allows(URL(string: "http://100.101.2.3:8100")!))
        precondition(!EndpointPolicy.allows(URL(string: "http://example.com")!))
        precondition(!EndpointPolicy.allows(URL(string: "https://user:password@example.com")!))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteFixture.self]
        let session = URLSession(configuration: configuration)
        let remote = try WebDriverConnection(endpoint: URL(string: "http://127.0.0.1:8100")!, session: session)
        let context = CGContext(data: nil, width: 200, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let frame = ScreenImage(image: context.makeImage()!, capturedAt: Date())
        _ = try await remote.perform(.tap(x: 100, y: 200), image: frame)
        precondition(RemoteFixture.bodies.last?["x"] as? Double == 50)
        precondition(RemoteFixture.bodies.last?["y"] as? Double == 100)
        let receipt = try await remote.perform(.setText(text: "שלום 👋"), image: frame)
        precondition(receipt.textVerification?.status == .verified)
        let multiline = "first line\nשלום 👋\nlast line"
        RemoteFixture.elementType = "XCUIElementTypeTextView"
        RemoteFixture.readback = multiline
        let multilineReceipt = try await remote.perform(.setText(text: multiline), image: frame)
        precondition(multilineReceipt.textVerification?.status == .verified)
        precondition(RemoteFixture.bodies.reversed().contains { $0["text"] as? String == multiline })
        let longText = String(repeating: "אבג🙂", count: 301)
        RemoteFixture.readback = longText
        let longReceipt = try await remote.perform(.setText(text: longText), image: frame)
        precondition(longReceipt.textVerification?.status == .verified)
        RemoteFixture.elementType = "XCUIElementTypeTextField"
        RemoteFixture.readback = "שלום 👋"
        let before = RemoteFixture.paths.count
        do { _ = try await remote.perform(.setText(text: "unsafe\nsubmit"), image: frame); preconditionFailure("Newline accepted") } catch {}
        precondition(!RemoteFixture.paths.suffix(RemoteFixture.paths.count - before).contains { $0.hasSuffix("/clear") || $0.hasSuffix("/value") })
        do { _ = try await remote.perform(.setText(text: "unsafe\tfocus-change"), image: frame); preconditionFailure("Tab accepted") } catch {}
        RemoteFixture.windowWidth = 200
        RemoteFixture.windowHeight = 200
        let orientationPaths = RemoteFixture.paths.count
        do { _ = try await remote.perform(.tap(x: 100, y: 200), image: frame); preconditionFailure("Orientation change accepted") } catch {}
        precondition(!RemoteFixture.paths.suffix(RemoteFixture.paths.count - orientationPaths).contains { $0.hasSuffix("/tap") })
        RemoteFixture.windowWidth = 100
        RemoteFixture.windowHeight = 200
        let count = RemoteFixture.paths.count
        do { _ = try await remote.perform(.tap(x: 201, y: 200), image: frame); preconditionFailure("Out of bounds accepted") } catch {}
        precondition(!RemoteFixture.paths.suffix(RemoteFixture.paths.count - count).contains { $0.hasSuffix("/tap") })
        session.invalidateAndCancel()
        try await remoteRecoveryAndCancellation(frame: frame)
        print("PASS: remote pixel scaling, focused Unicode readback, bounded multiline TextView entry, newline/tab rejection, orientation/bounds and endpoint policy")
        if let address = ProcessInfo.processInfo.environment["TAPLYNE_WDA_TEST_ENDPOINT"], let url = URL(string: address) {
            let live = try WebDriverConnection(endpoint: url)
            let image = try await live.screenshot()
            // The task-owned companion's address field, discovered with Argent describe.
            _ = try await live.perform(.tap(x: image.width / 2, y: Int(Double(image.height) * 0.149)), image: image)
            let result = try await live.perform(.setText(text: "שלום 👋"), image: try await live.screenshot())
            precondition(result.textVerification?.status == .verified, "Physical/Simulator remote Unicode readback failed")
            print("PASS LIVE: WebDriver screenshot, tap and exact Hebrew/emoji field readback")
        }
    }

    @MainActor private static func remoteRecoveryAndCancellation(frame: ScreenImage) async throws {
        func response(_ object: [String: Any], status: Int = 200) -> (Data, Int) {
            (try! JSONSerialization.data(withJSONObject: object), status)
        }

        var sessionNumber = 0
        var paths: [String] = []
        let recovery = try WebDriverConnection(endpoint: URL(string: "http://127.0.0.1:8100")!, exchange: { method, path, _ in
            paths.append("\(method) \(path)")
            if path == "session" {
                sessionNumber += 1
                return response(["value": ["sessionId": "recovery-\(sessionNumber)"]])
            }
            if path.hasSuffix("/window/size") {
                return response(["value": ["width": 100, "height": 200]])
            }
            if path.hasSuffix("/wda/tap") && sessionNumber == 1 {
                return response(["value": ["error": "invalid session id", "message": "The session was discarded."]], status: 404)
            }
            return response(["value": NSNull()])
        })
        do { _ = try await recovery.perform(.tap(x: 100, y: 200), image: frame); preconditionFailure("Uncertain tap was reported as successful") } catch {}
        precondition(sessionNumber == 1)
        precondition(paths.filter { $0 == "POST session" }.count == 1)
        precondition(paths.filter { $0.contains("/wda/tap") }.count == 1)
        _ = try await recovery.perform(.tap(x: 100, y: 200), image: frame)
        precondition(sessionNumber == 2, "The next explicit action did not establish a fresh session")
        precondition(paths.filter { $0.contains("/wda/tap") }.count == 2, "The failed mutating request was replayed")
        await recovery.close()
        precondition(paths.contains("DELETE session/recovery-2"), "Injected close did not target the active session")

        final class CancellationBox {
            var task: Task<InputReceipt, Error>?
        }
        let cancellation = CancellationBox()
        var cancellationPaths: [String] = []
        let canceled = try WebDriverConnection(endpoint: URL(string: "http://127.0.0.1:8100")!, exchange: { _, path, _ in
            cancellationPaths.append(path)
            if path == "session" { return response(["value": ["sessionId": "cancel-session"]]) }
            if path.hasSuffix("/window/size") { return response(["value": ["width": 100, "height": 200]]) }
            if path.hasSuffix("/element/active") { return response(["value": ["ELEMENT": "field-1"]]) }
            if path.hasSuffix("/name") { return response(["value": "XCUIElementTypeTextField"]) }
            if path.hasSuffix("/clear") {
                cancellation.task?.cancel()
                return response(["value": NSNull()])
            }
            return response(["value": "should not be read"])
        })
        let task = Task<InputReceipt, Error> { @MainActor in
            try await canceled.perform(.setText(text: "cancel me"), image: frame)
        }
        cancellation.task = task
        do { _ = try await task.value; preconditionFailure("Cancellation after clear was ignored") } catch {}
        precondition(cancellationPaths.contains { $0.hasSuffix("/clear") })
        precondition(!cancellationPaths.contains { $0.hasSuffix("/value") }, "Text was sent after cancellation following clear")
    }
}

private final class RemoteFixture: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var paths: [String] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    nonisolated(unsafe) static var elementType = "XCUIElementTypeTextField"
    nonisolated(unsafe) static var readback = "שלום 👋"
    nonisolated(unsafe) static var windowWidth = 100
    nonisolated(unsafe) static var windowHeight = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.paths.append(path)
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(buffer, count: count) }
            data = result
        } else { data = Data() }
        Self.bodies.append((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        let value: Any
        if path == "/session" { value = ["sessionId": "test-session"] }
        else if path.hasSuffix("/window/size") { value = ["width": Self.windowWidth, "height": Self.windowHeight] }
        else if path.hasSuffix("/element/active") { value = ["ELEMENT": "field-1"] }
        else if path.hasSuffix("/name") { value = Self.elementType }
        else if path.hasSuffix("/attribute/value") { value = Self.readback }
        else { value = NSNull() }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["value": value]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
