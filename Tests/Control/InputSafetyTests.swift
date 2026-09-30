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
        print("PASS: clipboard ownership, missing pointer rejection, complete hover click, verified pointer reuse, reanchor after invalidation, unrelated page change rejection, cancellation releases")
    }
}
