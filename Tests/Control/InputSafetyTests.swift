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
        driver.isCalibrating = true
        let active = Task { try await driver.perform(.tapAndHold(x: 350, y: 450, durationMs: 1000)) }
        while !transport.reports.contains(where: { $0.0 == .mouse && $0.1.first == 1 }) { await Task.yield() }
        active.cancel()
        do { _ = try await active.value; preconditionFailure("Hold ignored cancellation") } catch let error as InputFailure { precondition(error.delivery == .delivered) }
        precondition(transport.reports.suffix(3).map { $0.0 } == [.mouse, .keyboard, .consumerControl])
        precondition(transport.reports.suffix(3).allSatisfy { $0.1.allSatisfy { $0 == 0 } })
        precondition(driver.pointer == nil)
        print("PASS: rich clipboard restoration, concurrent clipboard protection, missing pointer rejection, cancellation releases held input")
    }
}
