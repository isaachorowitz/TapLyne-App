import Foundation

public enum PhoneControlMode: String, Codable, Sendable { case automatic, paused, manual }
public enum PhoneControlCommand: String, Sendable, CaseIterable { case pause, resume, takeover, stop }
public enum InputOrigin: Sendable { case agent, manual }

public struct PhoneControlState: Sendable, Equatable {
    public var mode: PhoneControlMode
    public var generation: UInt64
    public var revision: UInt64

    public init(mode: PhoneControlMode = .automatic, generation: UInt64 = 0, revision: UInt64 = 0) {
        self.mode = mode; self.generation = generation; self.revision = revision
    }

    var json: [String: Any] { ["mode": mode.rawValue, "generation": generation, "revision": revision] }
}

/// A phone has one cancellation-aware input queue, shared by the UI, REST and MCP.
@MainActor public final class PhoneInputQueue {
    public private(set) var state = PhoneControlState()
    public var onStateChange: ((PhoneControlState) -> Void)?
    private var tail: Task<Void, Never>?
    private var cancelActive: (() -> Void)?
    private var activeID: UUID?

    public var hasActiveInput: Bool { activeID != nil }

    public init() {}

    @discardableResult public func control(_ command: PhoneControlCommand) -> PhoneControlState {
        state.generation &+= 1
        state.revision &+= 1
        state.mode = command == .resume ? .automatic : (command == .takeover ? .manual : .paused)
        cancelActive?()
        onStateChange?(state)
        return state
    }

    public func enqueue<T: Sendable>(
        origin: InputOrigin = .manual, expected: PhoneControlState? = nil,
        _ work: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        if origin == .manual, state.mode == .automatic { control(.takeover) }
        let generation = state.generation
        let previous = tail
        let id = UUID()
        let cancellation = CancellationSlot<T>()
        let task = Task { @MainActor () throws -> T in
            await previous?.value
            try Task.checkCancellation()
            guard self.state.generation == generation else { throw PhoneServiceError.failed("CONTROL_CHANGED: Queued input was cancelled by a pause or takeover.") }
            if origin == .agent, self.state.mode != .automatic {
                throw PhoneServiceError.failed("AUTOMATION_PAUSED: Resume automation before sending agent input.")
            }
            if let expected, expected != self.state {
                throw PhoneServiceError.failed("STALE_FRAME: The phone changed after the observed frame. Describe it again.")
            }
            self.activeID = id
            self.cancelActive = { cancellation.task?.cancel() }
            self.state.revision &+= 1
            self.onStateChange?(self.state)
            defer {
                if self.activeID == id {
                    self.activeID = nil; self.cancelActive = nil
                    self.state.revision &+= 1
                    self.onStateChange?(self.state)
                }
            }
            return try await work()
        }
        tail = Task { _ = try? await task.value }
        cancellation.task = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
}

@MainActor private final class CancellationSlot<T: Sendable> { var task: Task<T, Error>? }
