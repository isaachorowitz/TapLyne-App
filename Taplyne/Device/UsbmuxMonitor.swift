import Foundation
import Network
import os

/// Subscribes to usbmuxd (the daemon Finder uses to talk to iPhones) and reports
/// when a device is plugged in or unplugged.
@MainActor
final class UsbmuxMonitor {
    private var connection: NWConnection?
    private var onChange: (() -> Void)?
    private var retryTask: Task<Void, Never>?
    private let log = Logger(subsystem: "agency.ziplyne.taplyne", category: "usbmux")

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        connect()
    }

    func stop() {
        retryTask?.cancel()
        connection?.cancel()
        connection = nil
    }

    private func connect() {
        let connection = NWConnection(to: .unix(path: "/var/run/usbmuxd"), using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.sendListen()
                    self.readHeader()
                case .failed, .cancelled:
                    self.scheduleReconnect()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func scheduleReconnect() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.retryTask = nil
            self?.connect()
        }
    }

    private func sendListen() {
        let message: [String: Any] = [
            "MessageType": "Listen",
            "ClientVersionString": "taplyne",
            "ProgName": "taplyne",
            "kLibUSBMuxVersion": 3
        ]
        guard let payload = try? PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0) else { return }
        var packet = Data()
        for value in [UInt32(16 + payload.count), 1, 8, 1] {
            withUnsafeBytes(of: value.littleEndian) { packet.append(contentsOf: $0) }
        }
        packet.append(payload)
        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func readHeader() {
        connection?.receive(minimumIncompleteLength: 16, maximumLength: 16) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, let data, data.count == 16, error == nil else {
                    self?.connection?.cancel()
                    return
                }
                let length = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
                self.readPayload(Int(length) - 16)
            }
        }
    }

    private func readPayload(_ count: Int) {
        guard count > 0 else { return readHeader() }
        connection?.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, let data, error == nil else {
                    self?.connection?.cancel()
                    return
                }
                let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
                let type = plist?["MessageType"] as? String ?? ""
                if type == "Attached" || type == "Detached" {
                    self.log.info("usbmux \(type, privacy: .public)")
                    self.onChange?()
                }
                self.readHeader()
            }
        }
    }
}
