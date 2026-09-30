import Foundation
import os

/// Talks to cabled iPhones over Apple's lockdown protocol through pymobiledevice3.
/// Everything here works on a stock iPhone that trusts this Mac: no jailbreak,
/// no Developer Mode, nothing installed on the phone.
struct DeviceTool: Sendable {
    struct USBDevice: Sendable, Equatable, Identifiable {
        let udid: String
        let name: String
        let productType: String
        let iosVersion: String
        var id: String { udid }
    }

    struct App: Sendable, Equatable {
        let name: String
        let bundleID: String
    }

    enum ToolError: LocalizedError {
        case missing
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missing: "pymobiledevice3 is not installed. Install it with: uv tool install pymobiledevice3"
            case let .failed(message): message
            }
        }
    }

    private static let log = Logger(subsystem: "agency.ziplyne.taplyne", category: "device")

    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/pymobiledevice3",
            "/opt/homebrew/bin/pymobiledevice3",
            "/usr/local/bin/pymobiledevice3"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    static var uvExecutable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    /// Installs pymobiledevice3 with uv when it is missing.
    static func install() async throws {
        guard let uv = uvExecutable else {
            throw ToolError.failed("uv is not installed, so pymobiledevice3 cannot be installed automatically.")
        }
        _ = try await run(uv, ["tool", "install", "pymobiledevice3"], timeout: 600)
    }

    func usbDevices() async throws -> [USBDevice] {
        let data = try await Self.pmd(["usbmux", "list", "--usb"])
        let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let udid = entry["UniqueDeviceID"] as? String ?? entry["Identifier"] as? String else { return nil }
            return USBDevice(
                udid: udid,
                name: entry["DeviceName"] as? String ?? "iPhone",
                productType: entry["ProductType"] as? String ?? "",
                iosVersion: entry["ProductVersion"] as? String ?? ""
            )
        }
    }

    func assistiveTouchEnabled(udid: String) async throws -> Bool {
        let data = try await Self.pmd(["lockdown", "assistive-touch", "--udid", udid])
        return String(decoding: data, as: UTF8.self).contains("true")
    }

    func bluetoothAddress(udid: String) async throws -> String {
        let data = try await Self.pmd(["lockdown", "get", "--key", "BluetoothAddress", "--udid", udid])
        let raw = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String
        let address = (raw ?? String(decoding: data, as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard address.range(of: "^[0-9A-F]{2}(:[0-9A-F]{2}){5}$", options: .regularExpression) != nil else {
            throw ToolError.failed("Could not read this iPhone's Bluetooth address. Unlock it and trust this Mac.")
        }
        return address
    }

    func setAssistiveTouch(udid: String, enabled: Bool) async throws {
        _ = try await Self.pmd(["lockdown", "assistive-touch", enabled ? "on" : "off", "--udid", udid])
    }

    /// True while the phone is locked (lockdown's PasswordProtected).
    func isLocked(udid: String) async throws -> Bool {
        let data = try await Self.pmd(["lockdown", "get", "--key", "PasswordProtected", "--udid", udid])
        return String(decoding: data, as: UTF8.self).lowercased().contains("true")
    }

    func restart(udid: String) async throws {
        _ = try await Self.pmd(["diagnostics", "restart", "--udid", udid])
    }

    /// Installed apps plus Apple's built-in apps, sorted by name.
    func apps(udid: String) async throws -> [App] {
        var result: [String: App] = [:]
        for type in ["User", "System"] {
            let data = try await Self.pmd(["apps", "list", "--type", type, "--udid", udid], timeout: 90)
            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] ?? [:]
            for (bundleID, info) in dict {
                let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? bundleID
                let hidden = (info["SBAppTags"] as? [String])?.contains("hidden") ?? false
                if hidden { continue }
                result[bundleID] = App(name: name, bundleID: bundleID)
            }
        }
        return result.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func pmd(_ arguments: [String], timeout: TimeInterval = 30) async throws -> Data {
        guard let tool = executable else { throw ToolError.missing }
        return try await run(tool, arguments, timeout: timeout)
    }

    private static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env["PYMOBILEDEVICE3_NO_COLOR"] = "1"
            env["NO_COLOR"] = "1"
            process.environment = env
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let outBuffer = PipeBuffer(out)
            let errBuffer = PipeBuffer(err)
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            process.terminationHandler = { finished in
                timer.cancel()
                let stdout = outBuffer.finish()
                let stderr = String(decoding: errBuffer.finish(), as: UTF8.self)
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    let message = stderr.split(separator: "\n").last.map(String.init) ?? "exit \(finished.terminationStatus)"
                    log.error("pymobiledevice3 \(arguments.joined(separator: " "), privacy: .public): \(message, privacy: .public)")
                    continuation.resume(throwing: ToolError.failed(message))
                }
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Drains a pipe as data arrives so a chatty child never blocks on a full pipe.
private final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let handle: FileHandle

    init(_ pipe: Pipe) {
        handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            self?.lock.withLock { self?.data.append(chunk) }
        }
    }

    func finish() -> Data {
        handle.readabilityHandler = nil
        let rest = handle.readDataToEndOfFile()
        return lock.withLock {
            data.append(rest)
            return data
        }
    }
}
