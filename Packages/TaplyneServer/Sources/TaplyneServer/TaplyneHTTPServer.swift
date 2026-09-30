import Foundation
import Network
import Security

public struct ServerConfiguration: Sendable {
    /// "127.0.0.1" binds loopback only; "0.0.0.0" binds every interface.
    public var host: String
    public var port: UInt16
    public var apiKey: String
    public var version: String

    public init(host: String = "127.0.0.1", port: UInt16 = 7788, apiKey: String, version: String) {
        self.host = host
        self.port = port
        self.apiKey = apiKey
        self.version = version
    }
}

public enum APIKeyGenerator {
    /// "tl_" followed by 40 random hex characters.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return "tl_" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public enum ServerError: Error, Sendable, CustomStringConvertible {
    case alreadyStarted
    case failedToStart(String)

    public var description: String {
        switch self {
        case .alreadyStarted: "The server is already running"
        case .failedToStart(let m): "The server could not start: \(m)"
        }
    }
}

public final class TaplyneHTTPServer: @unchecked Sendable {
    private let configuration: ServerConfiguration
    private let router: Router
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private var sessions: [ObjectIdentifier: (HTTPConnection, Task<Void, Never>)] = [:]

    public init(configuration: ServerConfiguration, service: any PhoneService) {
        self.configuration = configuration
        self.router = Router(configuration: configuration, service: service)
    }

    /// The port the listener is bound to; 0 before `start()`. Useful when configured with port 0.
    public var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    /// Starts listening and returns once the socket is bound (or throws).
    public func start() throws {
        lock.lock()
        if listener != nil {
            lock.unlock()
            throw ServerError.alreadyStarted
        }
        lock.unlock()

        let parameters = NWParameters.tcp
        guard let requested = NWEndpoint.Port(rawValue: configuration.port) else {
            throw ServerError.failedToStart("invalid port")
        }
        let listener: NWListener
        do {
            if configuration.host == "0.0.0.0" {
                listener = try NWListener(using: parameters, on: requested)
            } else {
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host(configuration.host), port: requested)
                listener = try NWListener(using: parameters)
            }
        } catch {
            throw ServerError.failedToStart("\(error)")
        }

        let ready = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if outcome.set(nil) { ready.signal() }
            case .failed(let error):
                if outcome.set("\(error)") { ready.signal() }
            case .cancelled:
                if outcome.set("cancelled") { ready.signal() }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
        listener.start(queue: DispatchQueue(label: "taplyne.listener"))
        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw ServerError.failedToStart("timed out")
        }
        if let message = outcome.value {
            listener.cancel()
            throw ServerError.failedToStart(message)
        }
        lock.lock()
        self.listener = listener
        boundPort = listener.port?.rawValue ?? configuration.port
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        boundPort = 0
        let active = sessions
        sessions = [:]
        lock.unlock()
        listener?.cancel()
        for (connection, task) in active.values {
            task.cancel()
            connection.cancel()
        }
    }

    private func accept(_ nw: NWConnection) {
        let connection = HTTPConnection(nw)
        let id = ObjectIdentifier(connection)
        let router = self.router
        let task = Task { [weak self] in
            await connection.serve { await router.handle($0) }
            self?.forget(id)
        }
        lock.lock()
        sessions[id] = (connection, task)
        lock.unlock()
    }

    private func forget(_ id: ObjectIdentifier) {
        lock.lock()
        sessions[id] = nil
        lock.unlock()
    }
}

private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private(set) var value: String?

    /// Records the first outcome only. Returns true when this call was the first.
    func set(_ message: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        value = message
        return true
    }
}
