import Foundation

/// Barge-in invalidates both already-playing audio and late tools/audio from the cancelled turn.
struct RealtimeTurnFence {
    private(set) var revision = UUID()
    private var activeResponse: String?
    private var cancelled: Set<String> = []
    private var waitingForSpeechEnd = false

    mutating func interrupt() {
        revision = UUID()
        if let activeResponse { cancelled.insert(activeResponse) }
        waitingForSpeechEnd = true
    }
    mutating func speechEnded() { waitingForSpeechEnd = false }
    mutating func created(_ id: String) {
        activeResponse = id
        if waitingForSpeechEnd { cancelled.insert(id) }
    }
    func allows(_ id: String?) -> Bool {
        guard let id else { return false }
        return id == activeResponse && !cancelled.contains(id) && !waitingForSpeechEnd
    }

    func canStartOperation(responseID: String?) -> Bool { allows(responseID) }

    func operationIsCurrent(_ operationRevision: UUID) -> Bool {
        operationRevision == revision && !waitingForSpeechEnd
    }
}
