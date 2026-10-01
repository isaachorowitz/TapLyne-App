import Foundation

/// A conversation capability can observe and control exactly one device.
struct ScopedPhoneService: PhoneService {
    let base: any PhoneService
    let deviceID: String
    private func check(_ id: String) throws {
        guard id == deviceID else { throw PhoneServiceError.phoneNotFound(id) }
    }
    func listPhones() async -> [PhoneRecord] { await base.listPhones().filter { $0.id == deviceID } }
    func rename(phoneID: String, displayName: String?) async throws -> PhoneRecord {
        try check(phoneID); return try await base.rename(phoneID: phoneID, displayName: displayName)
    }
    func apps(phoneID: String, refresh: Bool) async throws -> AppList {
        try check(phoneID); return try await base.apps(phoneID: phoneID, refresh: refresh)
    }
    func screenshot(phoneID: String) async throws -> ScreenImage {
        try check(phoneID); return try await base.screenshot(phoneID: phoneID)
    }
    func liveFrames(phoneID: String) async throws -> AsyncStream<ScreenImage> {
        try check(phoneID); return try await base.liveFrames(phoneID: phoneID)
    }
    func perform(phoneID: String, action: PhoneAction) async throws {
        try check(phoneID); try await base.perform(phoneID: phoneID, action: action)
    }
    func controlState(phoneID: String) async throws -> PhoneControlState {
        try check(phoneID); return try await base.controlState(phoneID: phoneID)
    }
    func control(phoneID: String, command: PhoneControlCommand) async throws -> PhoneControlState {
        try check(phoneID)
        guard command == .pause || command == .stop else { throw PhoneServiceError.invalidArgument("Agents cannot resume manual control.") }
        return try await base.control(phoneID: phoneID, command: command)
    }
    func performObserved(phoneID: String, action: PhoneAction, reference: ActionReference) async throws -> InputReceipt {
        try check(phoneID); return try await base.performObserved(phoneID: phoneID, action: action, reference: reference)
    }
}
