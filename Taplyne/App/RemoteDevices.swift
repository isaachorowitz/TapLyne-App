import Foundation
import TaplyneServer

@MainActor
extension PhoneRegistry {
    func addRemote(name: String, endpoint: URL) throws -> Phone {
        _ = try WebDriverConnection(endpoint: endpoint)
        let config = PhoneConfig(udid: "remote-" + UUID().uuidString.lowercased(), name: name,
                                 model: "Remote iPhone or iPad", createdAt: Date(), remoteEndpoint: endpoint.absoluteString)
        let phone = Phone(config: config)
        add(phone)
        attachRemote(phone)
        return phone
    }

    func attachRemote(_ phone: Phone) {
        guard phone.remote == nil, let address = phone.config.remoteEndpoint, let url = URL(string: address) else { return }
        do {
            let connection = try WebDriverConnection(endpoint: url)
            phone.remote = connection
            pollRemote(phone, connection: connection)
        } catch { phone.lastError = error.localizedDescription }
    }

    func pollRemote(_ phone: Phone, connection: WebDriverConnection) {
        phone.remoteTask = Task { @MainActor [weak phone] in
                var wasConnected = false
                while !Task.isCancelled, let phone {
                    do {
                        let image = try await connection.screenshot()
                        try Task.checkCancellation()
                        phone.remoteImage = image
                        if phone.config.width != image.width || phone.config.height != image.height {
                            var config = phone.config; config.width = image.width; config.height = image.height
                            phone.config = config
                        }
                        phone.plugged = true
                        phone.readiness = .ready
                        phone.lastError = nil
                        wasConnected = true
                    } catch is CancellationError { break }
                    catch {
                        if wasConnected { phone.control(.pause) }
                        wasConnected = false
                        phone.plugged = false
                        phone.readiness = .waitingForScreen
                        phone.lastError = "Remote capture disconnected. Reconnect the device and resume manually; no input is replayed."
                    }
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                }
                await connection.close()
            }
    }

    func stopRemoteDevices() {
        for phone in phones where phone.remote != nil { detachRemote(phone) }
    }
}
