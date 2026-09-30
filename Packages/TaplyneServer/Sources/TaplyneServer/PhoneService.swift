import CoreGraphics
import Foundation

// The contract between the Taplyne app (which owns the phones) and this server
// package (which exposes them over REST, MCP, and a live stream). The app
// implements `PhoneService`; everything in this package talks only to it.

public enum ConnectionStatus: String, Codable, Sendable {
    /// Connected, screen visible, and Bluetooth input paired: accepts actions.
    case online
    /// Plugged in but not ready (setup unfinished, Bluetooth not connected, or locked).
    case available
    /// Not plugged into this Mac.
    case offline
}

public struct PhoneRecord: Codable, Sendable, Equatable {
    /// The phone's UDID. Stable across reconnects.
    public var id: String
    /// The name the phone reports, such as "My iPhone".
    public var name: String
    /// The name given in Taplyne, if any.
    public var displayName: String?
    public var connectionStatus: ConnectionStatus
    /// Why the phone is not online, in plain words. Nil when online.
    public var statusReason: String?
    /// Native screen size in pixels. Nil until the screen has been seen once.
    public var width: Int?
    public var height: Int?
    public var model: String?
    public var createdAt: Date

    public init(
        id: String, name: String, displayName: String? = nil,
        connectionStatus: ConnectionStatus, statusReason: String? = nil,
        width: Int? = nil, height: Int? = nil, model: String? = nil, createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.connectionStatus = connectionStatus
        self.statusReason = statusReason
        self.width = width
        self.height = height
        self.model = model
        self.createdAt = createdAt
    }
}

public struct AppEntry: Codable, Sendable, Equatable {
    public var name: String
    public var bundleID: String

    public init(name: String, bundleID: String) {
        self.name = name
        self.bundleID = bundleID
    }
}

public struct AppList: Sendable, Equatable {
    public var apps: [AppEntry]
    /// When the list was fetched from the phone. Nil when fetched for this request.
    public var updatedAt: Date?
    /// "database" when served from the saved copy, "device" when freshly fetched.
    public var source: String

    public init(apps: [AppEntry], updatedAt: Date?, source: String) {
        self.apps = apps
        self.updatedAt = updatedAt
        self.source = source
    }
}

/// A full-resolution frame of a phone's screen. Pixel positions in `image`
/// are the coordinates `PhoneAction` expects.
public struct ScreenImage: @unchecked Sendable {
    public let image: CGImage
    public let capturedAt: Date

    public init(image: CGImage, capturedAt: Date) {
        self.image = image
        self.capturedAt = capturedAt
    }

    public var width: Int { image.width }
    public var height: Int { image.height }
}

public enum Direction: String, Codable, Sendable, CaseIterable {
    case up, down, left, right
}

public enum Speed: String, Codable, Sendable, CaseIterable {
    case slow, medium, fast
}

public enum KeyName: String, Codable, Sendable, CaseIterable {
    case enter, escape, backspace, tab, space
    case arrowUp = "arrow_up"
    case arrowDown = "arrow_down"
    case arrowLeft = "arrow_left"
    case arrowRight = "arrow_right"
}

public enum Modifier: String, Codable, Sendable, CaseIterable {
    case control, shift, alternate, command
}

/// Every coordinate is in native screen pixels, top-left origin.
public enum PhoneAction: Sendable, Equatable {
    case tap(x: Int, y: Int)
    case doubleTap(x: Int, y: Int)
    case tripleTap(x: Int, y: Int)
    case tapAndHold(x: Int, y: Int, durationMs: Int)
    case flick(x: Int, y: Int, direction: Direction)
    case drag(fromX: Int, fromY: Int, toX: Int, toY: Int, speed: Speed)
    case holdAndDrag(fromX: Int, fromY: Int, toX: Int, toY: Int, holdDurationMs: Int, speed: Speed)
    /// Any Unicode text. The app types US-ASCII over the keyboard and pastes the rest.
    case type(text: String)
    /// Replaces the focused field without submitting it. Exact readback when supported.
    case setText(text: String)
    case keypress(key: KeyName, modifiers: [Modifier], repeatCount: Int)
    case home
    case navigate(NavigationCommand)
}

public enum PhoneServiceError: Error, Sendable, Equatable {
    case phoneNotFound(String)
    /// The phone exists but cannot take actions right now; the string says why.
    case phoneNotReady(String)
    case invalidArgument(String)
    case timeout
    case failed(String)
}

public protocol PhoneService: Sendable {
    func listPhones() async -> [PhoneRecord]
    func rename(phoneID: String, displayName: String?) async throws -> PhoneRecord
    func apps(phoneID: String, refresh: Bool) async throws -> AppList
    /// The latest full-resolution frame.
    func screenshot(phoneID: String) async throws -> ScreenImage
    /// Frames as they arrive, throttled by the app. Ends when the consumer stops iterating.
    func liveFrames(phoneID: String) async throws -> AsyncStream<ScreenImage>
    /// Runs one action to completion.
    func perform(phoneID: String, action: PhoneAction) async throws
    func controlState(phoneID: String) async throws -> PhoneControlState
    func control(phoneID: String, command: PhoneControlCommand) async throws -> PhoneControlState
    func performObserved(phoneID: String, action: PhoneAction, reference: ActionReference) async throws -> InputReceipt
}
