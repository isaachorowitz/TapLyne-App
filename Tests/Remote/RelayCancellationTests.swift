import Foundation

@main
struct RelayCancellationTests {
    @MainActor static func main() async throws {
        let endpoint = URL(string: "ws://127.0.0.1:8787")!
        let pair = try RelayConfiguration.pair(endpoint: endpoint, scope: .runner)
        var host = try RelayCipher(configuration: pair.host)
        var device = try RelayCipher(configuration: pair.device)
        _ = try host.open(try device.seal(.hello))
        _ = try device.open(try host.seal(.hello))
        _ = try device.open(try host.seal(.acknowledgment))
        _ = try host.open(try device.seal(.acknowledgment))

        let connection = UUID()
        let canceledID = UUID()
        var pending = Set([canceledID])
        pending.remove(canceledID)
        precondition(!RelaySendAdmission.allows(requestID: canceledID, pendingIDs: pending,
                                                currentConnection: connection, requestConnection: connection),
                     "Canceled request remained send-admitted")

        let queue = RelayOutboundQueue()
        var firstEntered = false
        var releaseFirst: CheckedContinuation<Void, Never>?
        var deliveredFrames: [Data] = []
        let first = Task { @MainActor in
            try await queue.enqueue(
                admission: { true },
                frame: { try host.seal(.request, request: RelayRequest(method: "GET", path: "status", body: nil)) },
                deliver: { data in
                    firstEntered = true
                    await withCheckedContinuation { continuation in releaseFirst = continuation }
                    deliveredFrames.append(data)
                }
            )
        }
        while !firstEntered { await Task.yield() }

        var canceledFrameSealed = false
        let second = Task { @MainActor in
            try await queue.enqueue(
                admission: { pending.contains(canceledID) },
                frame: {
                    canceledFrameSealed = true
                    return try host.seal(.request, request: RelayRequest(method: "GET", path: "status", body: nil))
                },
                deliver: { _ in }
            )
        }
        while queue.queuedCount < 2 { await Task.yield() }
        pending.remove(canceledID)
        releaseFirst?.resume()
        _ = try await first.value
        do { _ = try await second.value; preconditionFailure("Canceled queued frame was delivered") } catch {}
        precondition(!canceledFrameSealed, "Canceled queued request sealed before admission")

        // The next actual queue item seals immediately after the first frame,
        // proving that the canceled item consumed no encrypted sequence.
        try await queue.enqueue(
            admission: { true },
            frame: { try host.seal(.request, request: RelayRequest(method: "GET", path: "status", body: nil)) },
            deliver: { deliveredFrames.append($0) }
        )
        for frame in deliveredFrames { _ = try device.open(frame) }
        precondition(!RelaySendAdmission.allows(requestID: canceledID, pendingIDs: pending,
                                                currentConnection: UUID(), requestConnection: connection),
                     "A stale connection epoch remained send-admitted")
        print("PASS: canceled relay requests do not consume encrypted sequence numbers")
    }
}
