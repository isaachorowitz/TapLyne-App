import Foundation
import Darwin

/// Owns the bounded install and launch process, not the detached device runner.
/// All arguments are literal argv entries.
@MainActor
final class RunnerSetup: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published private(set) var profileExpiry: String?
    private var process: Process?
    private var bootstrap: URL?
    private var output = Data()
    private var generation = UUID()
    private var cancelling = false

    /// Validates all local prerequisites without touching relay state or starting
    /// a process. Callers can run this before any pairing or connection mutation.
    nonisolated static func validatePreflight(phoneID: String, team: String, runnerToolsAvailable: Bool) throws {
        guard phoneID.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw RelayFailure("Select a device and enter the ten-character Apple team ID.")
        }
        guard runnerToolsAvailable else {
            throw RelayFailure("Runner setup tools are missing from this app. Rebuild Taplyne.")
        }
    }

    func start(phoneID: String, team: String, configuration: RelayConfiguration) throws {
        guard !running else { throw RelayFailure("Wait for the current setup to finish before starting another.") }
        let files = FileManager.default
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("RunnerTools")
        try Self.validatePreflight(phoneID: phoneID, team: team, runnerToolsAvailable: bundled.map { files.fileExists(atPath: $0.path) } == true)
        guard let bundled else { throw RelayFailure("Runner setup tools are missing from this app. Rebuild Taplyne.") }
        let root = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Taplyne/RunnerTools")
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for folder in ["scripts", "Shared", "Runner"] {
            let destination = root.appendingPathComponent(folder)
            try files.createDirectory(at: destination, withIntermediateDirectories: true)
            for source in try files.contentsOfDirectory(at: bundled.appendingPathComponent(folder), includingPropertiesForKeys: nil) {
                let target = destination.appendingPathComponent(source.lastPathComponent)
                if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
                try files.copyItem(at: source, to: target)
            }
        }
        let file = root.appendingPathComponent("pairing-" + UUID().uuidString + ".json")
        try JSONEncoder().encode(configuration).write(to: file, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        bootstrap = file
        let child = Process(); let pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [root.appendingPathComponent("Runner/runner-launch.py").path,
                           root.appendingPathComponent("scripts/run-runner.sh").path,
                           "--udid", phoneID, "--team", team, "--bootstrap", file.path, "--background"]
        child.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.contains("KEY") || key.contains("TOKEN") || key.contains("SECRET") { environment.removeValue(forKey: key) }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        child.environment = environment
        child.standardOutput = pipe; child.standardError = pipe
        let attempt = UUID(); generation = attempt
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.consume(chunk, attempt: attempt) }
        }
        child.terminationHandler = { [weak self] child in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self, self.generation == attempt else { return }
                self.running = false; self.process = nil; self.removeBootstrap()
                if self.cancelling {
                    self.status = "Setup cancelled. A runner already launched on the device may remain active."
                } else if child.terminationStatus == 0 {
                    self.status = "Runner launch accepted. Verify the Device connection and open a fresh screen."
                } else {
                    self.status = "Runner setup ended. Check Xcode signing, Developer Mode and the private logs in Application Support/Taplyne/RunnerTools/.build/runner/logs."
                }
                self.cancelling = false
            }
        }
        do { try child.run() }
        catch { removeBootstrap(); throw error }
        process = child; running = true; cancelling = false; profileExpiry = nil; output = Data(); status = "Preparing the signed runner…"
    }

    private func consume(_ chunk: Data, attempt: UUID) {
        guard generation == attempt, running, !cancelling else { return }
        output.append(chunk)
        if output.count > 32_768 { output.removeFirst(output.count - 32_768) }
        while let newline = output.firstIndex(of: 10) {
            let line = output[..<newline]; output.removeSubrange(...newline)
            guard let item = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: String],
                  let event = item["event"], let detail = item["detail"] else { continue }
            let labels = ["prepare": "Preparing runner", "build": "Building and signing", "install": "Installing runner", "bootstrap": "Pairing runner", "runner_xctest": "XCTest runner", "runner_background": "Background runner launch", "runner_network": "Private device connection", "runner_error": "Setup failed"]
            if let label = labels[event] { status = label + ": " + detail }
            if event == "bootstrap", detail == "complete" { removeBootstrap() }
            if let expiry = item["profileExpires"] { profileExpiry = expiry }
        }
    }

    /// Cancels only this Mac's setup process. The device owns a detached runner.
    func stop() {
        guard let process, process.isRunning, !cancelling else { return }
        cancelling = true
        status = "Cancelling setup. A runner already launched on the device may remain active."
        let pid = process.processIdentifier
        if getpgid(pid) == pid { kill(-pid, SIGTERM) } else { process.terminate() }
        removeBootstrap()
    }
    private func removeBootstrap() { if let bootstrap { try? FileManager.default.removeItem(at: bootstrap) }; bootstrap = nil }
}
