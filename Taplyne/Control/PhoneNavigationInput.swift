import Foundation
import TaplyneServer

extension PhoneDriver {
    func navigate(_ command: NavigationCommand) async throws {
        switch command {
        case .home: try await pressHome()
        case .appSwitcher:
            try await pressHome()
            try await sleep(ms: 100)
            try await pressHome()
        case .dismissKeyboard: try await keyStroke(.escape)
        case .back:
            try await drag(from: CGPoint(x: Int(max(60, profile.anchorPoint?.x ?? 60)), y: Int(screen.height / 2)),
                                        to: CGPoint(x: Int(screen.width * 0.8), y: Int(screen.height / 2)), holdMs: 0, speed: .medium)
        case .notifications, .controlCenter:
            try await drag(from: CGPoint(x: Int(screen.width * (command == .notifications ? 0.2 : 0.93)), y: Int(max(60, profile.anchorPoint?.y ?? 60))),
                                        to: CGPoint(x: Int(screen.width / 2), y: Int(screen.height * 0.7)), holdMs: 0, speed: .medium)
        }
    }
}
