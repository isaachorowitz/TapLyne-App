import Darwin
import Foundation

/// Runs one owned local helper with drained, bounded pipes and a deadline. Never invokes a shell.
enum LocalProcess {
    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe(), error = Pipe()
        let stdout = Buffer(output), stderr = Buffer(error)
        process.standardOutput = output; process.standardError = error
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline, !stdout.exceededLimit, !stderr.exceededLimit else {
                    throw PhoneServiceError.failed("Local OCR exceeded its output or time limit.")
                }
                try await Task.sleep(for: .milliseconds(25))
            }
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            _ = stdout.finish(); _ = stderr.finish()
            throw error
        }
        let data = stdout.finish()
        _ = stderr.finish()
        guard process.terminationStatus == 0 else { throw PhoneServiceError.failed("Local OCR failed with status \(process.terminationStatus).") }
        return String(decoding: data, as: UTF8.self)
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private let handle: FileHandle
        private var data = Data()
        private var exceeded = false
        private static let capacity = 2_000_000

        init(_ pipe: Pipe) {
            handle = pipe.fileHandleForReading
            handle.readabilityHandler = { [weak self] h in
                let chunk = h.availableData
                guard !chunk.isEmpty else { return }
                self?.append(chunk)
            }
        }

        var exceededLimit: Bool { lock.withLock { exceeded } }

        private func append(_ chunk: Data) {
            lock.withLock {
                if data.count + chunk.count > Self.capacity { exceeded = true }
                data.append(chunk.prefix(max(0, Self.capacity - data.count)))
            }
        }

        func finish() -> Data {
            handle.readabilityHandler = nil
            append(handle.readDataToEndOfFile())
            return lock.withLock { data }
        }
    }
}
