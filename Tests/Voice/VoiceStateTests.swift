import Foundation

@main
enum VoiceStateTests {
    static func main() {
        testEchoGate()
        testTurnFence()
        testReconnectPolicy()
        testPCM16()
        testPlaybackAccountingFence()
        testInputLiveness()
        testCaptureRecoveryGate()
        print("PASS: voice echo, cancellation, playback fencing, capture recovery, retry and PCM policies")
    }

    private static func testEchoGate() {
        var gate = VoiceEchoGate()
        gate.assistantStarted("I can open Settings and check that now.")
        precondition(gate.classify("open settings") == .echo)
        precondition(gate.classify("OPEN, settings!") == .echo)
        precondition(gate.classify("no") == .userSpeech)
        precondition(gate.classify("settings instead") == .userSpeech)
        // A short correction wins even when its word also appears in synthesized speech.
        precondition(gate.classify("settings") == .ambiguous)
        precondition(gate.removingEchoPrefix(from: "I can open Settings no use WiFi") == "no use WiFi")
        precondition(gate.removingEchoPrefix(from: "settings instead") == "settings instead")

        gate.assistantStarted("אני פותח את ההגדרות עכשיו")
        precondition(gate.classify("פותח את ההגדרות") == .echo)
        precondition(gate.classify("לא") == .userSpeech)
        gate.assistantStopped()
        precondition(gate.classify("continue") == .userSpeech)
        precondition(gate.classify("   ") == .empty)
    }

    private static func testTurnFence() {
        var fence = RealtimeTurnFence()
        fence.created("first")
        let firstRevision = fence.revision
        precondition(fence.allows("first"))
        precondition(fence.canStartOperation(responseID: "first"))
        precondition(fence.operationIsCurrent(firstRevision))

        fence.interrupt()
        precondition(!fence.allows("first"))
        precondition(!fence.operationIsCurrent(firstRevision))
        fence.created("late")
        precondition(!fence.canStartOperation(responseID: "late"))
        fence.speechEnded()
        precondition(!fence.allows("late"))
        fence.created("corrected")
        precondition(fence.allows("corrected"))
        precondition(!fence.allows(nil))
    }

    private static func testReconnectPolicy() {
        precondition(VoiceReconnectPolicy.maximumAttempts == 4)
        precondition(VoiceReconnectPolicy.delayNanoseconds(beforeAttempt: 0) == 0)
        precondition(VoiceReconnectPolicy.delayNanoseconds(beforeAttempt: 3) == 1_500_000_000)
        precondition(VoiceReconnectPolicy.delayNanoseconds(beforeAttempt: 4) == nil)
        precondition(VoiceReconnectPolicy.delayNanoseconds(beforeAttempt: -1) == nil)
    }

    private static func testPCM16() {
        let fixture = Data([0x00, 0x80, 0x00, 0x00, 0xff, 0x7f])
        guard let samples = VoicePCM16.floatSamples(from: fixture) else {
            preconditionFailure("Valid little-endian PCM was rejected")
        }
        precondition(samples.count == 3)
        precondition(samples[0] == -1 && samples[1] == 0)
        precondition(abs(samples[2] - 0.9999695) < 0.000001)
        precondition(VoicePCM16.floatSamples(from: Data([0x01])) == nil)
    }

    private static func testPlaybackAccountingFence() {
        var accounting = VoicePlaybackAccounting()
        accounting.begin(itemID: "old")
        let old = accounting.schedule(frames: 480)!
        precondition(accounting.queuedFrames == 480)

        accounting.begin(itemID: "new")
        let current = accounting.schedule(frames: 240)!
        precondition(!accounting.complete(old))
        precondition(accounting.itemID == "new")
        precondition(accounting.queuedFrames == 240 && accounting.playedFrames == 0)
        precondition(accounting.complete(current))
        precondition(accounting.queuedFrames == 0 && accounting.playedFrames == 240)

        accounting.begin(itemID: "same")
        let previousEpoch = accounting.schedule(frames: 60)!
        accounting.begin(itemID: "same")
        let currentEpoch = accounting.schedule(frames: 30)!
        precondition(!accounting.complete(previousEpoch))
        precondition(accounting.queuedFrames == 30 && accounting.playedFrames == 0)
        precondition(accounting.complete(currentEpoch))

        let stopped = accounting.schedule(frames: 120)!
        accounting.invalidate()
        precondition(!accounting.complete(stopped))
        precondition(accounting.itemID == nil)
        precondition(accounting.queuedFrames == 0 && accounting.playedFrames == 0)
    }

    private static func testInputLiveness() {
        var liveness = VoiceInputLiveness(stallInterval: 3)
        liveness.audioStarted(at: 10)
        precondition(liveness.evaluate(at: 12, engineRunning: true, interrupted: false) == .healthy)
        precondition(liveness.evaluate(at: 13, engineRunning: true, interrupted: true) == .healthy)
        precondition(liveness.evaluate(at: 13, engineRunning: false, interrupted: false) == .recover)

        // Starting a replacement graph preserves the one-recovery budget.
        liveness.audioStarted(at: 14)
        precondition(liveness.evaluate(at: 17, engineRunning: true, interrupted: false) == .fail)

        // A real tap buffer proves recovery and opens a new budget for a later incident.
        liveness.receivedBuffer(at: 18)
        precondition(liveness.evaluate(at: 19, engineRunning: true, interrupted: false) == .healthy)
        precondition(liveness.evaluate(at: 21, engineRunning: true, interrupted: false) == .recover)
        liveness.reset()
        precondition(liveness.evaluate(at: 100, engineRunning: false, interrupted: false) == .healthy)
    }

    private static func testCaptureRecoveryGate() {
        precondition(!VoiceCaptureRecoveryGate.allowsEngineNotification(
            hasReceivedBuffer: false,
            recoveryInFlight: false,
            interrupted: false
        ))
        precondition(VoiceCaptureRecoveryGate.allowsEngineNotification(
            hasReceivedBuffer: true,
            recoveryInFlight: false,
            interrupted: false
        ))
        precondition(!VoiceCaptureRecoveryGate.allowsRouteNotification(
            routeChanged: false,
            hasReceivedBuffer: true,
            recoveryInFlight: false,
            interrupted: false
        ))
        precondition(!VoiceCaptureRecoveryGate.allowsRouteNotification(
            routeChanged: true,
            hasReceivedBuffer: true,
            recoveryInFlight: true,
            interrupted: false
        ))
        precondition(!VoiceCaptureRecoveryGate.allowsRouteNotification(
            routeChanged: true,
            hasReceivedBuffer: true,
            recoveryInFlight: false,
            interrupted: true
        ))
        precondition(VoiceCaptureRecoveryGate.allowsRouteNotification(
            routeChanged: true,
            hasReceivedBuffer: true,
            recoveryInFlight: false,
            interrupted: false
        ))
    }
}
