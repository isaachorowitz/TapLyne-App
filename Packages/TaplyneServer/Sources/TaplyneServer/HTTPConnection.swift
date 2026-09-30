import Foundation
import Network

/// One accepted TCP connection: async receive/send plus the keep-alive request loop.
final class HTTPConnection: @unchecked Sendable {
    let connection: NWConnection
    private var buffer = Data()

    init(_ connection: NWConnection) { self.connection = connection }

    private func receive() async -> Data? {
        await withCheckedContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let data, !data.isEmpty { cont.resume(returning: data) } else { cont.resume(returning: nil) }
                _ = (complete, error)
            }
        }
    }

    func send(_ data: Data) async -> Bool {
        await withCheckedContinuation { cont in
            connection.send(content: data, completion: .contentProcessed { cont.resume(returning: $0 == nil) })
        }
    }

    func cancel() { connection.cancel() }

    /// Serves sequential requests until the client leaves or asks to close.
    func serve(handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) async {
        defer { connection.cancel() }
        connection.start(queue: DispatchQueue(label: "taplyne.connection"))
        while !Task.isCancelled {
            var request: HTTPRequest?
            while request == nil {
                switch HTTPParser.parse(&buffer) {
                case .request(let r): request = r
                case .failure(let status, let message):
                    let body = APIError(status: status, code: "BAD_REQUEST", message: message).response
                    await write(body, keepAlive: false)
                    return
                case .needMore:
                    guard let chunk = await receive() else { return }
                    buffer.append(chunk)
                }
            }
            guard let request else { return }
            let response = await handler(request)
            let keepAlive = !request.wantsClose
            switch response.body {
            case .data:
                await write(response, keepAlive: keepAlive)
                if !keepAlive { return }
            case .stream(let body):
                guard await send(response.head(keepAlive: false, contentLength: nil)) else { return }
                let streamTask = Task { await body(StreamWriter { [self] in await send($0) }) }
                // Watch for the client leaving; it sends nothing while streaming.
                let watcher = Task { [self] in
                    while await receive() != nil {}
                    streamTask.cancel()
                }
                await streamTask.value
                watcher.cancel()
                return
            }
        }
    }

    private func write(_ response: HTTPResponse, keepAlive: Bool) async {
        guard case .data(let body) = response.body else { return }
        var out = response.head(keepAlive: keepAlive, contentLength: body.count)
        out.append(body)
        _ = await send(out)
    }
}
