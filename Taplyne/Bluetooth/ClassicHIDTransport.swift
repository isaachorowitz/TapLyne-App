import Foundation
import os

@MainActor
final class ClassicHIDTransport: ObservableObject {
    let bridge = TLClassicBridge()
    @Published private(set) var status: String?
    @Published private(set) var busy = false
    @Published private(set) var readyAddresses: Set<String> = []
    private var sessions: [String: HIDSession] = [:]
    private var serviceHandle: UInt32 = 0
    private let log = Logger(subsystem: "agency.ziplyne.taplyne", category: "classic")

    init() {
        bridge.logHandler = { [weak self] line in self?.log.info("\(line, privacy: .public)") }
        bridge.statusHandler = { [weak self] message in self?.status = message }
        bridge.connectionHandler = { [weak self] address, ready in
            guard let self else { return }
            if ready {
                self.readyAddresses.insert(address)
                self.status = "Bluetooth input connected."
            } else {
                self.readyAddresses.remove(address)
                self.sessions[address] = nil
                self.status = "Bluetooth input disconnected. Prepare pairing to reconnect."
            }
        }
        bridge.dataHandler = { [weak self] address, psm, data in
            guard let self else { return }
            if data.first == 0x15 { // virtual cable unplug
                self.bridge.closeHIDAddress(address)
                return
            }
            var session = self.sessions[address] ?? HIDSession()
            let reply = session.receive(data)
            self.sessions[address] = session
            if psm == 17, let reply {
                self.bridge.sendPacket(reply, psm: 17, address: address) { [weak self] ok in
                    Task { @MainActor in
                        if !ok { self?.status = "Bluetooth control reply failed. Reconnect the iPhone." }
                    }
                }
            }
        }
    }

    func prepare(address: String) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        bridge.start()
        let deadline = Date().addingTimeInterval(5)
        while bridge.managerState() != 5, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard bridge.managerState() == 5 else {
            status = "Turn on Bluetooth and allow Taplyne to use it in System Settings."
            return false
        }
        if serviceHandle == 0 {
            var record = SDPRecord.buildHID(reportDescriptor: HIDProfile.reportMapData,
                name: "Taplyne", serviceDescription: "Keyboard and mouse", providerName: "Taplyne")
            record["020E - HIDBootDevice"] = false
            serviceHandle = bridge.addServiceData(record as NSDictionary)
        }
        guard serviceHandle != 0 else {
            status = "macOS could not register the Bluetooth keyboard and mouse service."
            return false
        }
        bridge.prepareIncomingPairing(address)
        if bridge.isPairedAddress(address) {
            status = "Reconnecting the keyboard and mouse."
            _ = bridge.connectAddress(address)
        } else {
            status = "On the iPhone, open Settings > Bluetooth and select “\(Host.current().localizedName ?? "this Mac")”. Compare and approve the code on both devices."
        }
        return true
    }

    func send(_ data: Data, reportID: ReportID, address: String) async -> Bool {
        guard readyAddresses.contains(address) else { return false }
        var session = sessions[address] ?? HIDSession()
        let packet = session.input(data, reportID: reportID)
        sessions[address] = session
        return await withCheckedContinuation { continuation in
            bridge.sendPacket(packet, psm: 19, address: address) { ok in
                continuation.resume(returning: ok)
            }
        }
    }

    func disconnect(address: String) {
        bridge.closeHIDAddress(address)
        readyAddresses.remove(address)
        sessions[address] = nil
    }

    func stop() {
        if serviceHandle != 0 { bridge.removeServiceHandle(serviceHandle) }
        serviceHandle = 0
        bridge.stop()
        readyAddresses.removeAll()
        sessions.removeAll()
    }
}
