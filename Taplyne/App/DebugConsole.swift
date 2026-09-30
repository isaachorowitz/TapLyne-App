#if DEBUG
import Foundation
import Network
import os

/// A loopback-only line console for development: one JSON object per line in,
/// one JSON object per line out. Enabled with `defaults write agency.ziplyne.taplyne debugConsole -bool YES`.
@MainActor
final class DebugConsole {
    typealias Handler = @MainActor ([String: Any]) async -> [String: Any]

    private var listener: NWListener?
    private let handler: Handler
    private let token: String
    private let log = Logger(subsystem: "agency.ziplyne.taplyne", category: "debug")

    init(token: String, handler: @escaping Handler) {
        self.token = token; self.handler = handler
    }

    func start(port: UInt16 = 7799) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else {
            log.error("debug console could not listen")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serve(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
        log.info("debug console on 127.0.0.1:\(port)")
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex ..< newline]
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                    guard request["token"] as? String == self.token, !self.token.isEmpty else { connection.cancel(); return }
                    let reply = await self.handler(request)
                    var out = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data("{}".utf8)
                    out.append(0x0A)
                    connection.send(content: out, completion: .contentProcessed { _ in })
                }
                if buffer.count > 65536 { connection.cancel(); return }
                if done || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }
}
#endif
