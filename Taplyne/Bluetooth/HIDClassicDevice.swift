// Vendored from jqssun/darwin-bt-remote (commit ad7a76c, BTRemote/Classic), AGPL-3.0-only.
// See LICENSE-AGPL-3.0 in this folder. Taplyne changes: strings inlined, log subsystem,
// storage key. The SDP negotiation and HIDP handling are untouched on purpose.

#if os(macOS)
    import Combine
    import Foundation
    @preconcurrency import IOBluetooth
    @preconcurrency import IOBluetoothUI
    import os
    import SwiftUI

    /// classic (macOS): publish a SDP record, open L2CAP control/interrupt channels to the paired host and emit HID reports
    /// low energy: macOS dual-mode controller advertises the public BD address with the BR/EDR-supported flag set, so the paired host can
    /// merge the low energy entry with the BR/EDR record, but finds no HID profile as the host only looks for classic mode
    @MainActor
    final class HIDClassicDevice: NSObject, ObservableObject {
        @Published private(set) var state: ControllerState = .unknown
        @Published private(set) var pairedDevices: [PairedDevice] = []
        @Published private(set) var connectedAddress: String?
        @Published private(set) var keyboardLEDs: KeyboardLEDs = []
        @Published private(set) var lastError: String?
        @Published private(set) var batteryLevel: UInt8 = 100
        @Published private(set) var isSDPPublished = false
        @Published private(set) var isReady = false

        private let log = Logger(subsystem: "agency.ziplyne.taplyne", category: "HIDClassicDevice")

        private var serviceRecord: IOBluetoothSDPServiceRecord?
        private var device: IOBluetoothDevice?
        private var controlChannel: IOBluetoothL2CAPChannel?
        private var interruptChannel: IOBluetoothL2CAPChannel?
        @Published private(set) var isConnecting = false

        /// answers GET_REPORT; seeded so a GET before any input still returns a valid report
        private var lastReports: [UInt8: Data] = [
            ReportID.mouse.rawValue: MouseReport.zero.data,
            ReportID.keyboard.rawValue: KeyboardReport.zero.data,
            ReportID.systemControl.rawValue: SystemControlReport.zero.data,
            ReportID.consumerControl.rawValue: ConsumerReport.zero.data
        ]
        /// SET_PROTOCOL mode: 0x00 boot, 0x01 report
        private var protocolMode: UInt8 = 0x01
        /// SET_IDLE rate; stored and echoed, not enforced
        private var idleRate: UInt8 = 0

        private static let storedDevicesKey = "taplyne.classic.devices.v1"
        private let defaults: UserDefaults = .standard

        enum ControllerState: Equatable {
            case unknown, poweredOff, poweredOn
        }

        func start() {}

        func stop() {
            disconnect()
            unpublishService()
        }

        func publishService() {
            guard serviceRecord == nil else { return }
            let dict = SDPRecord.buildHID(
                reportDescriptor: HIDProfile.reportMapData,
                name: "Taplyne",
                serviceDescription: "Keyboard and mouse",
                providerName: "Taplyne"
            )
            guard let record = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
                lastError = "Could not publish the Bluetooth keyboard service."
                log.error("publishedServiceRecord returned nil")
                return
            }
            serviceRecord = record
            isSDPPublished = true
            var handle: BluetoothSDPServiceRecordHandle = 0
            _ = record.getHandle(&handle)
            log.info("SDP service published; handle=\(handle, privacy: .public)")
        }

        func unpublishService() {
            if let serviceRecord {
                serviceRecord.remove()
                self.serviceRecord = nil
            }
            isSDPPublished = false
        }

        /// only show peers explicitly added through the pair modal, not the system paired list
        func refreshPairedDevices() {
            var collected = _loadStoredDevices()
            for i in collected.indices {
                collected[i].isConnected = _isClassicAclUp(addressID: collected[i].id)
            }
            pairedDevices = collected
        }

        /// calls a private BOOL getter on IOBluetoothDevice via KVC
        fileprivate nonisolated static func _privateBool(_ object: AnyObject, key: String) -> Bool {
            guard let ns = object as? NSObject else { return false }
            let value = ns.value(forKey: key)
            return (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
        }

        private func _loadStoredDevices() -> [PairedDevice] {
            guard let data = defaults.data(forKey: Self.storedDevicesKey) else { return [] }
            return (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
        }

        private func _saveStoredDevices(_ list: [PairedDevice]) {
            let data = try? JSONEncoder().encode(list)
            defaults.set(data, forKey: Self.storedDevicesKey)
        }

        private func _isClassicAclUp(addressID: String) -> Bool {
            guard let dev = _lookup(addressID: addressID) else { return false }
            return dev.isConnected()
        }

        private func _rememberDevice(_ entry: PairedDevice) {
            var list = _loadStoredDevices()
            if list.contains(where: { $0.id == entry.id }) { return }
            list.append(entry)
            _saveStoredDevices(list)
        }

        /// user-initiated removal of a stored entry; does not unpair at OS level
        func forgetDevice(id: String) {
            var list = _loadStoredDevices()
            list.removeAll { $0.id == id }
            _saveStoredDevices(list)
            refreshPairedDevices()
        }

        /// temporarily flips Class of Device so remote scanners recognize it as a HID device during handshake
        @discardableResult
        func presentPairingPicker() -> PairedDevice? {
            // get selector first, then publishService, then setCoD
            guard let selector = IOBluetoothDeviceSelectorController.deviceSelector() else {
                lastError = "Could not publish the Bluetooth keyboard service."
                return nil
            }
            publishService()

            if let host = IOBluetoothHostController.default() {
                host.setClassOfDevice(0x2540, forTimeInterval: 120.0)
            }
            selector.setTitle("Pair iPhone")
            selector.setHeader("Choose your iPhone")
            selector.setDescriptionText("Keep Settings > Bluetooth open on the iPhone.")
            let response = selector.runModal()
            guard response == kIOBluetoothUISuccess else {
                return nil
            }
            let results = selector.getResults() as? [IOBluetoothDevice] ?? []

            guard let picked = results.first else {
                return nil
            }
            let entry = PairedDevice(
                id: _canonicalAddress(picked.addressString ?? ""),
                name: picked.name ?? picked.addressString ?? "Unknown device",
                isConnected: picked.isConnected()
            )
            _rememberDevice(entry)
            refreshPairedDevices()
            return entry
        }

        func connect(to peer: PairedDevice) {
            guard !isConnecting else { return }
            publishService()
            guard let target = _lookup(addressID: peer.id) else {
                lastError = "\(peer.name) is not paired with this Mac."
                return
            }
            disconnect()
            device = target
            isConnecting = true
            let addressStr = target.addressString ?? "?"
            log.info("opening ACL to \(addressStr, privacy: .public)")

            // HID requires an authenticated, encrypted ACL before the L2CAP channels; openConnection establishes it
            if !target.isConnected() {
                let aclResult = target.openConnection()
                if aclResult != kIOReturnSuccess {
                    lastError = "Could not connect to the iPhone (\(Self._ioReturnCode(aclResult)))."
                    log.error("openConnection failed \(Self._ioReturnCode(aclResult), privacy: .public)")
                    isConnecting = false
                    device = nil
                    return
                }
            }

            var control: IOBluetoothL2CAPChannel?
            let controlResult = target.openL2CAPChannelSync(&control, withPSM: BluetoothL2CAPPSM(0x0011), delegate: self)
            if controlResult != kIOReturnSuccess || control == nil {
                lastError = "The iPhone refused the HID control channel (\(Self._ioReturnCode(controlResult)))."
                log.error("L2CAP PSM 0x0011 open failed \(Self._ioReturnCode(controlResult), privacy: .public)")
                target.closeConnection()
                device = nil
                isConnecting = false
                return
            }
            log.info("control L2CAP open")

            var interrupt: IOBluetoothL2CAPChannel?
            let interruptResult = target.openL2CAPChannelSync(&interrupt, withPSM: BluetoothL2CAPPSM(0x0013), delegate: self)
            if interruptResult != kIOReturnSuccess || interrupt == nil {
                lastError = "The iPhone refused the HID interrupt channel (\(Self._ioReturnCode(interruptResult)))."
                log.error("L2CAP PSM 0x0013 open failed \(Self._ioReturnCode(interruptResult), privacy: .public)")
                control?.close()
                target.closeConnection()
                device = nil
                isConnecting = false
                return
            }
            log.info("interrupt L2CAP open")

            controlChannel = control
            interruptChannel = interrupt
            connectedAddress = Self._canonicalAddress(addressStr)
            isReady = true
            isConnecting = false
            refreshPairedDevices()
        }

        func disconnect() {
            controlChannel?.close()
            interruptChannel?.close()
            controlChannel = nil
            interruptChannel = nil
            device?.closeConnection()
            device = nil
            connectedAddress = nil
            isReady = false
            isConnecting = false
        }

        func sendMouse(_ report: MouseReport) {
            _sendInputReport(.mouse, payload: report.data)
        }

        func sendKeyboard(_ report: KeyboardReport) {
            _sendInputReport(.keyboard, payload: report.data)
        }

        func sendConsumer(_ report: ConsumerReport) {
            _sendInputReport(.consumerControl, payload: report.data)
        }

        func sendSystemControl(_ report: SystemControlReport) {
            _sendInputReport(.systemControl, payload: report.data)
        }

        func updateBatteryLevel(_ level: UInt8) {
            // classic HID has no separate battery service; report ID 4 sends battery via HID input
            let clamped = min(level, 100)
            batteryLevel = clamped
            _sendInputReport(.battery, payload: Data([clamped]))
        }

        private func _refreshState() {
            let host = IOBluetoothHostController.default()
            guard let power = host?.powerState else { state = .unknown; return }
            if power == kBluetoothHCIPowerStateON {
                state = .poweredOn
            } else if power == kBluetoothHCIPowerStateOFF {
                state = .poweredOff
            } else {
                state = .unknown
            }
        }

        private nonisolated static func _canonicalAddress(_ raw: String) -> String {
            raw.lowercased().filter(\.isHexDigit)
        }

        private func _canonicalAddress(_ raw: String) -> String {
            Self._canonicalAddress(raw)
        }

        private func _lookup(addressID: String) -> IOBluetoothDevice? {
            // pairedDevices() can return a stale reference whose internal state is out-of-date
            let formatted = _formatAddressForLookup(addressID)
            return IOBluetoothDevice(addressString: formatted)
        }

        private func _formatAddressForLookup(_ canonical: String) -> String {
            canonical.groupedInPairs(separator: "-")
        }

        /// HID Interrupt PDU: header 0xA1 (DATA / INPUT) + reportID + payload
        private func _sendInputReport(_ reportID: ReportID, payload: Data) {
            lastReports[reportID.rawValue] = payload
            guard let interruptChannel else { return }
            var buffer = Data(capacity: 2 + payload.count)
            buffer.append(0xA1)
            buffer.append(reportID.rawValue)
            buffer.append(payload)
            let length = UInt16(buffer.count)
            buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                let status = interruptChannel.writeAsync(base, length: length, refcon: nil)
                if status != kIOReturnSuccess {
                    lastError = "Sending input failed (\(Self._ioReturnCode(status)))."
                    log.error("writeAsync interrupt failed \(Self._ioReturnCode(status), privacy: .public)")
                }
            }
        }

        fileprivate nonisolated static func _ioReturnCode(_ code: IOReturn) -> String {
            String(format: "0x%08X", UInt32(bitPattern: code))
        }
    }

    extension HIDClassicDevice: @preconcurrency IOBluetoothL2CAPChannelDelegate {
        func l2capChannelOpenComplete(_ channel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
            if error != kIOReturnSuccess {
                lastError = "An HID channel failed to open (\(Self._ioReturnCode(error)))."
            }
        }

        func l2capChannelClosed(_ channel: IOBluetoothL2CAPChannel!) {
            if channel === controlChannel { controlChannel = nil }
            if channel === interruptChannel { interruptChannel = nil }
            if controlChannel == nil, interruptChannel == nil {
                isReady = false
                connectedAddress = nil
            }
        }

        func l2capChannelReconfigured(_ channel: IOBluetoothL2CAPChannel!) {}

        func l2capChannelData(
            _ channel: IOBluetoothL2CAPChannel!,
            data dataPointer: UnsafeMutableRawPointer!,
            length dataLength: Int
        ) {
            let bytes = Data(bytes: dataPointer, count: dataLength)
            _handleHostMessage(on: channel, bytes: bytes)
        }

        func l2capChannelWriteComplete(
            _ channel: IOBluetoothL2CAPChannel!,
            refcon: UnsafeMutableRawPointer!,
            status error: IOReturn
        ) {
            if error != kIOReturnSuccess {
                log.error("writeComplete error: \(Self._ioReturnCode(error), privacy: .public)")
            }
        }

        /// HIDP transaction routing keyed on the header's high nibble (BT HID profile 1.1)
        private func _handleHostMessage(on channel: IOBluetoothL2CAPChannel, bytes: Data) {
            guard let header = bytes.first else { return }
            switch header & 0xF0 {
            case 0x00: // HANDSHAKE — device never initiates, ignore
                break
            case 0x10: // HID_CONTROL (no handshake reply)
                if header & 0x0F == 0x05 { disconnect() } // VIRTUAL_CABLE_UNPLUG
            case 0x40: // GET_REPORT
                _handleGetReport(bytes)
            case 0x50: // SET_REPORT
                _applyOutputReport(bytes)
                _sendControlHandshake(status: .successful)
            case 0x60: // GET_PROTOCOL
                _sendControlData(header: 0xA0, payload: Data([protocolMode]))
            case 0x70: // SET_PROTOCOL
                protocolMode = header & 0x01
                _sendControlHandshake(status: .successful)
            case 0x80: // GET_IDLE
                _sendControlData(header: 0xA0, payload: Data([idleRate]))
            case 0x90: // SET_IDLE
                if bytes.count >= 2 { idleRate = bytes[1] }
                _sendControlHandshake(status: .successful)
            case 0xA0: // DATA — host output report, no reply
                _applyOutputReport(bytes)
            default: // DATC / unknown
                _sendControlHandshake(status: .errUnsupportedRequest)
            }
        }

        /// GET_REPORT: low 2 bits = report type, next byte = report ID
        private func _handleGetReport(_ bytes: Data) {
            let reportType = bytes[0] & 0x03
            let reportID = bytes.count >= 2 ? bytes[1] : 0
            guard reportType == 0x01 else {
                _sendControlHandshake(status: .errUnsupportedRequest)
                return
            }
            guard let payload = lastReports[reportID] else {
                _sendControlHandshake(status: .errInvalidReportID)
                return
            }
            _sendControlData(header: 0xA0 | reportType, payload: Data([reportID]) + payload)
        }

        /// LED state from an output report (report type 0x02)
        private func _applyOutputReport(_ bytes: Data) {
            guard bytes[0] & 0x03 == 0x02, bytes.count >= 3 else { return }
            if bytes[1] == ReportID.keyboardLEDs.rawValue {
                keyboardLEDs = KeyboardLEDs(byte: bytes[2])
            }
        }

        /// HID HANDSHAKE response codes per BT HID profile spec
        private enum HandshakeStatus: UInt8 {
            case successful = 0x00
            case notReady = 0x01
            case errInvalidReportID = 0x02
            case errUnsupportedRequest = 0x03
            case errInvalidParameter = 0x04
            case errUnknown = 0x0E
            case errFatal = 0x0F
        }

        private func _sendControlHandshake(status: HandshakeStatus) {
            guard let controlChannel else { return }
            var byte: UInt8 = status.rawValue
            withUnsafeMutablePointer(to: &byte) { ptr in
                _ = controlChannel.writeAsync(UnsafeMutableRawPointer(ptr), length: 1, refcon: nil)
            }
        }

        private func _sendControlData(header: UInt8, payload: Data) {
            guard let controlChannel else { return }
            var buffer = Data([header])
            buffer.append(payload)
            let length = UInt16(buffer.count)
            buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                _ = controlChannel.writeAsync(base, length: length, refcon: nil)
            }
        }
    }

    struct PairedDevice: Identifiable, Equatable, Codable {
        let id: String
        let name: String
        var isConnected: Bool = false
        var displayAddress: String {
            id.uppercased().groupedInPairs(separator: ":")
        }

        private enum CodingKeys: String, CodingKey { case id, name }
    }

    private extension String {
        func groupedInPairs(separator: String) -> String {
            stride(from: 0, to: count, by: 2).map {
                let start = index(startIndex, offsetBy: $0)
                let end = index(start, offsetBy: 2, limitedBy: endIndex) ?? endIndex
                return String(self[start ..< end])
            }.joined(separator: separator)
        }
    }
#endif
