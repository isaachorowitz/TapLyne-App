import Foundation

/// Separates likely loudspeaker echo from a user's correction while synthesized speech plays.
/// Acoustic echo cancellation remains the primary defense; this gate rejects exact transcript
/// fragments without delaying short, divergent corrections such as "no" or "stop".
struct VoiceEchoGate {
    enum Decision: Equatable { case empty, echo, ambiguous, userSpeech }

    private var assistantTokens: [String] = []

    mutating func assistantStarted(_ text: String) {
        assistantTokens = Self.tokens(text)
    }

    mutating func assistantStopped() {
        assistantTokens.removeAll(keepingCapacity: true)
    }

    func classify(_ transcript: String) -> Decision {
        let heard = Self.tokens(transcript)
        guard !heard.isEmpty else { return .empty }
        guard !assistantTokens.isEmpty else { return .userSpeech }

        // Recognition can join synthesized speech after its first word, so accept any exact
        // contiguous assistant fragment as echo. A divergent word is user speech immediately,
        // even if other words overlap the assistant.
        guard heard.count <= assistantTokens.count else { return .userSpeech }
        if heard.count == 1 {
            // A one-word correction must win even when the assistant happened to use that word.
            // Release the ambiguous word shortly if it does not grow into an echo phrase.
            return assistantTokens.contains(heard[0]) ? .ambiguous : .userSpeech
        }
        for start in 0...(assistantTokens.count - heard.count) {
            if Array(assistantTokens[start..<(start + heard.count)]) == heard { return .echo }
        }
        return .userSpeech
    }

    func removingEchoPrefix(from transcript: String) -> String {
        let rawWords = transcript.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let heard = Self.tokens(transcript)
        guard heard.count == rawWords.count, heard.count >= 3, assistantTokens.count >= 2 else {
            return transcript
        }
        var echoCount = 0
        for start in assistantTokens.indices {
            var count = 0
            while start + count < assistantTokens.count,
                  count < heard.count,
                  assistantTokens[start + count] == heard[count] {
                count += 1
            }
            echoCount = max(echoCount, count)
        }
        // Require multiple matching words and preserve a correction that only overlaps one word.
        guard echoCount >= 2, echoCount < rawWords.count else { return transcript }
        return rawWords.dropFirst(echoCount).joined(separator: " ")
    }

    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

struct VoiceReconnectPolicy {
    static let maximumAttempts = 4

    static func delayNanoseconds(beforeAttempt attempt: Int) -> UInt64? {
        let delays: [UInt64] = [0, 250_000_000, 750_000_000, 1_500_000_000]
        guard attempt >= 0, attempt < delays.count else { return nil }
        return delays[attempt]
    }
}

enum VoicePCM16 {
    static func floatSamples(from bytes: Data) -> [Float]? {
        guard !bytes.isEmpty, bytes.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            return nil
        }
        return bytes.withUnsafeBytes { raw in
            (0..<(bytes.count / MemoryLayout<Int16>.size)).map { index in
                let sample = raw.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Int16>.size,
                    as: Int16.self
                )
                return Float(Int16(littleEndian: sample)) / 32_768
            }
        }
    }
}

struct VoicePlaybackAccounting {
    struct Ticket: Equatable, Sendable {
        let epoch: UUID
        let itemID: String
        let frames: Int
    }

    private(set) var epoch = UUID()
    private(set) var itemID: String?
    private(set) var queuedFrames = 0
    private(set) var playedFrames: Int64 = 0

    mutating func begin(itemID: String) {
        epoch = UUID()
        self.itemID = itemID
        queuedFrames = 0
        playedFrames = 0
    }

    mutating func invalidate() {
        epoch = UUID()
        itemID = nil
        queuedFrames = 0
        playedFrames = 0
    }

    mutating func schedule(frames: Int) -> Ticket? {
        guard let itemID, frames > 0 else { return nil }
        queuedFrames += frames
        return Ticket(epoch: epoch, itemID: itemID, frames: frames)
    }

    @discardableResult
    mutating func complete(_ ticket: Ticket) -> Bool {
        guard ticket.epoch == epoch, ticket.itemID == itemID else { return false }
        queuedFrames = max(0, queuedFrames - ticket.frames)
        playedFrames += Int64(ticket.frames)
        return true
    }
}

struct VoiceInputLiveness {
    enum Decision: Equatable { case healthy, recover, fail }

    let stallInterval: TimeInterval
    private(set) var startedAt: TimeInterval?
    private(set) var lastBufferAt: TimeInterval?
    private(set) var recoveryIssued = false

    init(stallInterval: TimeInterval = 3) {
        self.stallInterval = stallInterval
    }

    mutating func reset() {
        startedAt = nil
        lastBufferAt = nil
        recoveryIssued = false
    }

    mutating func audioStarted(at time: TimeInterval) {
        startedAt = time
        lastBufferAt = nil
    }

    mutating func receivedBuffer(at time: TimeInterval) {
        lastBufferAt = time
        recoveryIssued = false
    }

    mutating func evaluate(
        at time: TimeInterval,
        engineRunning: Bool,
        interrupted: Bool
    ) -> Decision {
        guard !interrupted, let startedAt else { return .healthy }
        let reference = lastBufferAt ?? startedAt
        guard !engineRunning || time - reference >= stallInterval else { return .healthy }
        if recoveryIssued { return .fail }
        recoveryIssued = true
        return .recover
    }
}

enum VoiceCaptureRecoveryGate {
    static func allowsEngineNotification(
        hasReceivedBuffer: Bool,
        recoveryInFlight: Bool,
        interrupted: Bool
    ) -> Bool {
        hasReceivedBuffer && !recoveryInFlight && !interrupted
    }

    static func allowsRouteNotification(
        routeChanged: Bool,
        hasReceivedBuffer: Bool,
        recoveryInFlight: Bool,
        interrupted: Bool
    ) -> Bool {
        routeChanged && allowsEngineNotification(
            hasReceivedBuffer: hasReceivedBuffer,
            recoveryInFlight: recoveryInFlight,
            interrupted: interrupted
        )
    }
}
