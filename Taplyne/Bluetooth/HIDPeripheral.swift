// Vendored from jqssun/darwin-bt-remote (commit ad7a76c, BTRemote/LowEnergy), AGPL-3.0-only.
// See LICENSE-AGPL-3.0 in this folder. Taplyne is a private, undistributed build; if it is
// ever distributed, the whole app must ship under AGPL-3.0 or with a commercial license.
// The GATT layout is untouched on purpose (see the upstream README for why).
// Taplyne changes: advertised name, UserDefaults keys, targetCentral filter, log subsystem,
// lossless sendReliably (the upstream path keeps only the newest pending report).

import Combine
import CoreBluetooth
import os
import SwiftUI

/// HID-over-GATT peripheral engine
@MainActor
final class HIDPeripheral: NSObject, ObservableObject {
    @Published private(set) var state: CBManagerState = .unknown
    @Published private(set) var isAdvertising = false
    @Published private(set) var isHIDServiceAdded = false
    /// central identifier: the set of characteristic UUIDs it is currently subscribed to
    @Published private(set) var subscribedCentrals: [UUID: Set<CBUUID>] = [:]
    /// broadcasts skip inactive hosts
    @Published private(set) var inactiveCentrals: Set<UUID> = []
    @Published private(set) var connectedCentrals: Set<UUID> = []
    @Published private(set) var keyboardLEDs: KeyboardLEDs = []
    @Published private(set) var lastError: String?
    @Published private(set) var batteryLevel: UInt8 = 100

    private var centralObjects: [UUID: CBCentral] = [:]

    var advertiseLocalName: String = Host.current().localizedName ?? "Taplyne"
    /// Taplyne: when set, reports go only to this central (one Mac, several phones).
    var targetCentral: UUID?

    private let log = Logger(subsystem: "agency.ziplyne.taplyne", category: "HIDPeripheral")
    private var pManager: CBPeripheralManager?
    private var batteryServiceObj: CBMutableService?
    private var deviceInfoServiceObj: CBMutableService?
    private var hidServiceObj: CBMutableService?
    private var isHIDServiceAllowed = false
    private var isReadyToSendNotification = true

    private var charsByReportID: [UInt8: CBMutableCharacteristic] = [:]
    private var bootMouseInputChar: CBMutableCharacteristic?
    private var bootKeyboardInputChar: CBMutableCharacteristic?
    private var bootKeyboardOutputChar: CBMutableCharacteristic?
    private var batteryLevelChar: CBMutableCharacteristic?
    private var serviceChangedObj: CBMutableService?
    private var serviceChangedArmed = false
    private static let serviceChangedGrace: UInt64 = 2_000_000_000

    /// last-sent payloads for reads and new subscriptions
    private var cachedReports: [UInt8: Data] = [
        ReportID.mouse.rawValue: MouseReport.zero.data,
        ReportID.keyboard.rawValue: KeyboardReport.zero.data,
        ReportID.systemControl.rawValue: SystemControlReport.zero.data,
        ReportID.consumerControl.rawValue: ConsumerReport.zero.data
    ]

    private var pendingBroadcast: (Data, CBMutableCharacteristic)?

    func start() {
        isHIDServiceAllowed = true
        if pManager == nil {
            pManager = CBPeripheralManager(
                delegate: self,
                queue: nil,
                options: [CBPeripheralManagerOptionShowPowerAlertKey: true]
            )
        } else if state == .poweredOn {
            if isHIDServiceAdded {
                startAdvertisingNow()
            } else {
                installServices()
            }
        }
    }

    func stop() {
        isHIDServiceAllowed = false
        pManager?.stopAdvertising()
        isAdvertising = false
    }

    func promptPowerAlert() {
        guard state != .poweredOn else { return }
        _resetForRestart()
        start()
    }

    private func _resetForRestart() {
        pManager?.stopAdvertising()
        pManager = nil
        isAdvertising = false
        isHIDServiceAdded = false
        isReadyToSendNotification = true
        pendingBroadcast = nil
        batteryServiceObj = nil
        deviceInfoServiceObj = nil
        hidServiceObj = nil
        serviceChangedObj = nil
        serviceChangedArmed = false
        batteryLevelChar = nil
        bootMouseInputChar = nil
        bootKeyboardInputChar = nil
        bootKeyboardOutputChar = nil
        charsByReportID.removeAll()
        subscribedCentrals.removeAll()
        inactiveCentrals.removeAll()
        connectedCentrals.removeAll()
        centralObjects.removeAll()
    }

    func sendMouse(_ report: MouseReport) {
        broadcast(report.data, reportID: .mouse)
    }

    func sendKeyboard(_ report: KeyboardReport) {
        broadcast(report.data, reportID: .keyboard)
        // boot mode hosts read this characteristic instead
        bootKeyboardInputChar.map { _ = updateValue(report.data, for: $0) }
    }

    func sendConsumer(_ report: ConsumerReport) {
        broadcast(report.data, reportID: .consumerControl)
    }

    func sendSystemControl(_ report: SystemControlReport) {
        broadcast(report.data, reportID: .systemControl)
    }

    // MARK: Taplyne: lossless sending

    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    /// Sends a report and waits for CoreBluetooth to accept it instead of dropping it
    /// when the transmit queue is full. Relative mouse motion must never be lost.
    @discardableResult
    func sendReliably(_ data: Data, reportID: ReportID) async -> Bool {
        cachedReports[reportID.rawValue] = data
        guard let char = charsByReportID[reportID.rawValue] else { return false }
        for _ in 0 ..< 40 {
            guard let pManager else { return false }
            let recipients = activeRecipients()
            guard !recipients.isEmpty else { return false }
            if isReadyToSendNotification, pendingBroadcast == nil,
               pManager.updateValue(data, for: char, onSubscribedCentrals: recipients) {
                return true
            }
            isReadyToSendNotification = false
            await waitUntilReady()
        }
        return false
    }

    private func waitUntilReady() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            readyWaiters.append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 50_000_000)
                self?.resumeReadyWaiters()
            }
        }
    }

    private func resumeReadyWaiters() {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    var hasSubscriber: Bool { !activeRecipients().isEmpty }

    func toggleActive(_ uuid: UUID) {
        if inactiveCentrals.contains(uuid) {
            inactiveCentrals.remove(uuid)
        } else {
            inactiveCentrals.insert(uuid)
        }
    }

    func updateBatteryLevel(_ level: UInt8) {
        let clamped = min(level, 100)
        batteryLevel = clamped
        let asHIDReport = Data([clamped])
        cachedReports[ReportID.battery.rawValue] = asHIDReport
        if let batteryLevelChar { _ = updateValue(asHIDReport, for: batteryLevelChar) }
    }

    /// if host connects but never subscribes (stale GATT cache), cycle a temp service to fire Service Changed so it re-discovers
    func scheduleServiceChanged() {
        guard UserDefaults.standard.bool(forKey: "bt.useServiceChanged"), !serviceChangedArmed else { return }
        serviceChangedArmed = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.serviceChangedGrace)
            self?._cycleServiceChangedIfUnsubscribed()
        }
    }

    /// Taplyne: makes connected hosts re-discover the GATT database now.
    func forceServiceChanged() {
        _cycleServiceChanged()
    }

    private func _cycleServiceChangedIfUnsubscribed() {
        guard subscribedCentrals.isEmpty else { return }
        _cycleServiceChanged()
    }

    private func _cycleServiceChanged() {
        guard let pManager else { return }
        if let svc = serviceChangedObj {
            pManager.remove(svc)
            pManager.add(svc)
        } else {
            let svc = buildServiceChangedTrigger()
            serviceChangedObj = svc
            pManager.add(svc)
        }
        _trace("Service Changed cycled")
    }

    /// temp service used to perturb the GATT to trigger Service Changed
    private func buildServiceChangedTrigger() -> CBMutableService {
        let service = CBMutableService(type: CBUUID(nsuuid: UUID()), primary: true)
        service.characteristics = [
            CBMutableCharacteristic(
                type: CBUUID(nsuuid: UUID()),
                properties: [.read, .notifyEncryptionRequired],
                value: nil,
                permissions: .readEncryptionRequired
            )
        ]
        return service
    }

    private func installServices() {
        guard let pManager, !isHIDServiceAdded, batteryServiceObj == nil else { return }
        let battery = buildBatteryService()
        batteryServiceObj = battery
        pManager.add(battery)
    }

    private func buildDeviceInfoService() -> CBMutableService {
        let service = CBMutableService(type: HIDProfile.deviceInformationService, primary: true)
        service.characteristics = [
            CBMutableCharacteristic(
                type: HIDProfile.manufacturerName,
                properties: .read,
                value: HIDProfile.manufacturerNameValue,
                permissions: .readable
            ),
            CBMutableCharacteristic(
                type: HIDProfile.modelNumber,
                properties: .read,
                value: HIDProfile.modelNumberValue,
                permissions: .readable
            ),
            CBMutableCharacteristic(
                type: HIDProfile.pnpID,
                properties: .read,
                value: HIDProfile.pnpIDValue,
                permissions: .readable
            )
        ]
        return service
    }

    private func buildBatteryService() -> CBMutableService {
        let service = CBMutableService(type: HIDProfile.batteryService, primary: true)
        let level = CBMutableCharacteristic(
            type: HIDProfile.batteryLevel,
            properties: [.read, .notifyEncryptionRequired],
            value: nil,
            permissions: .readEncryptionRequired
        )
        // expose battery as HID Report ID 4 too
        let reportRef = CBMutableDescriptor(
            type: HIDProfile.reportReference,
            value: NSData(data: ReportID.battery.descriptor(.input))
        )
        level.descriptors = [reportRef]
        service.characteristics = [level]
        batteryLevelChar = level
        return service
    }

    private func buildHIDService(includingBattery battery: CBMutableService?) -> CBMutableService {
        let service = CBMutableService(type: HIDProfile.hidService, primary: true)
        if let battery { service.includedServices = [battery] }

        let controlPoint = CBMutableCharacteristic(
            type: HIDProfile.hidControlPoint,
            properties: .read,
            value: nil,
            permissions: .readEncryptionRequired
        )

        let protocolMode = CBMutableCharacteristic(
            type: HIDProfile.protocolMode,
            properties: [.read, .writeWithoutResponse],
            value: nil,
            permissions: [.readEncryptionRequired, .writeEncryptionRequired]
        )

        let hidInfo = CBMutableCharacteristic(
            type: HIDProfile.hidInformation,
            properties: .read,
            value: HIDProfile.hidInformationValue,
            permissions: .readEncryptionRequired
        )

        let bootMouseInput = CBMutableCharacteristic(
            type: HIDProfile.bootMouseInputReport,
            properties: [.read, .notifyEncryptionRequired],
            value: nil,
            permissions: [.readEncryptionRequired, .writeEncryptionRequired]
        )
        let bootKbdInput = CBMutableCharacteristic(
            type: HIDProfile.bootKeyboardInputReport,
            properties: [.read, .notifyEncryptionRequired],
            value: nil,
            permissions: [.readEncryptionRequired, .writeEncryptionRequired]
        )
        let bootKbdOutput = CBMutableCharacteristic(
            type: HIDProfile.bootKeyboardOutputReport,
            properties: [.read, .writeWithoutResponse, .write],
            value: nil,
            permissions: [.readEncryptionRequired, .writeEncryptionRequired]
        )

        // links the HID report map to battery level
        let reportMap = CBMutableCharacteristic(
            type: HIDProfile.reportMap,
            properties: .read,
            value: HIDProfile.reportMapData,
            permissions: .readEncryptionRequired
        )
        reportMap.descriptors = [
            CBMutableDescriptor(
                type: HIDProfile.externalReportReference,
                value: NSData(data: HIDProfile.externalReportReferenceValue)
            )
        ]

        // report characteristic order matters
        let systemReportChar = makeReportChar(.systemControl, type: .input)
        let consumerReportChar = makeReportChar(.consumerControl, type: .input)
        let mouseReportChar = makeReportChar(.mouse, type: .input)
        let keyboardReportChar = makeReportChar(.keyboard, type: .input)
        let outputReportChar = CBMutableCharacteristic(
            type: HIDProfile.report,
            properties: [.read, .writeWithoutResponse, .write],
            value: nil,
            permissions: [.readEncryptionRequired, .writeEncryptionRequired]
        )
        outputReportChar.descriptors = [
            CBMutableDescriptor(
                type: HIDProfile.reportReference,
                value: NSData(data: ReportID.keyboardLEDs.descriptor(.output))
            )
        ]

        service.characteristics = [
            controlPoint,
            protocolMode,
            hidInfo,
            bootMouseInput,
            bootKbdInput,
            bootKbdOutput,
            reportMap,
            systemReportChar,
            consumerReportChar,
            mouseReportChar,
            keyboardReportChar,
            outputReportChar
        ]

        bootMouseInputChar = bootMouseInput
        bootKeyboardInputChar = bootKbdInput
        bootKeyboardOutputChar = bootKbdOutput
        charsByReportID[ReportID.systemControl.rawValue] = systemReportChar
        charsByReportID[ReportID.consumerControl.rawValue] = consumerReportChar
        charsByReportID[ReportID.mouse.rawValue] = mouseReportChar
        charsByReportID[ReportID.keyboard.rawValue] = keyboardReportChar
        charsByReportID[ReportID.keyboardLEDs.rawValue] = outputReportChar

        return service
    }

    private func makeReportChar(_ id: ReportID, type: ReportType) -> CBMutableCharacteristic {
        let char = CBMutableCharacteristic(
            type: HIDProfile.report,
            properties: [.read, .notifyEncryptionRequired],
            value: nil,
            permissions: .readEncryptionRequired
        )
        char.descriptors = [
            CBMutableDescriptor(type: HIDProfile.reportReference, value: NSData(data: id.descriptor(type)))
        ]
        return char
    }

    private func startAdvertisingNow() {
        guard let pManager, !isAdvertising else { return }
        pManager.startAdvertising([
            CBAdvertisementDataLocalNameKey: advertiseLocalName,
            // hidService must stay first if more than one service is being advertised
            CBAdvertisementDataServiceUUIDsKey: [HIDProfile.hidService]
        ])
    }

    private func broadcast(_ data: Data, reportID: ReportID) {
        cachedReports[reportID.rawValue] = data
        guard let char = charsByReportID[reportID.rawValue] else { return }
        _ = updateValue(data, for: char)
    }

    @discardableResult
    private func updateValue(_ data: Data, for char: CBMutableCharacteristic) -> Bool {
        guard let pManager else { return false }
        let recipients = activeRecipients()
        guard !recipients.isEmpty else { return false }
        if !isReadyToSendNotification {
            pendingBroadcast = (data, char)
            return false
        }
        let accepted = pManager.updateValue(data, for: char, onSubscribedCentrals: recipients)
        if !accepted {
            isReadyToSendNotification = false
            pendingBroadcast = (data, char)
        }
        return accepted
    }

    private func drainPendingBroadcast() {
        guard let (data, char) = pendingBroadcast, let pManager else { return }
        pendingBroadcast = nil
        let recipients = activeRecipients()
        guard !recipients.isEmpty else { return }
        let accepted = pManager.updateValue(data, for: char, onSubscribedCentrals: recipients)
        if !accepted {
            isReadyToSendNotification = false
            pendingBroadcast = (data, char)
        }
    }

    private func _trace(_ message: @autoclosure () -> String) {
        guard UserDefaults.standard.object(forKey: "bt.trace") as? Bool ?? true else { return }
        let text = message()
        log.info("\(text, privacy: .public)")
    }

    private func _trackInteraction(from central: CBCentral) {
        centralObjects[central.identifier] = central
        guard !connectedCentrals.contains(central.identifier) else { return }
        connectedCentrals.insert(central.identifier)
        _trace("central tracked: \(central.identifier)")
    }

    private func activeRecipients() -> [CBCentral] {
        subscribedCentrals.keys
            .filter { !inactiveCentrals.contains($0) }
            .filter { targetCentral == nil || $0 == targetCentral }
            .compactMap { centralObjects[$0] }
    }

    private func reportID(forCharacteristic char: CBCharacteristic) -> UInt8? {
        for (id, c) in charsByReportID where c.uuid == char.uuid && c === char as AnyObject {
            return id
        }
        // fallback for restored characteristics
        if char.uuid == HIDProfile.report,
           let descriptor = (char as? CBMutableCharacteristic)?
           .descriptors?
           .first(where: { $0.uuid == HIDProfile.reportReference }),
           let value = descriptor.value as? Data,
           let id = value.first
        {
            return id
        }
        return nil
    }
}

extension HIDPeripheral: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        state = peripheral.state
        _trace("CB state -> \(peripheral.state.rawValue)")
        if peripheral.state == .poweredOn, isHIDServiceAllowed, !isHIDServiceAdded {
            installServices()
        }
        if peripheral.state != .poweredOn {
            isAdvertising = false
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            log.error("didAddService(\(service.uuid)) error: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        switch service.uuid {
        case HIDProfile.batteryService:
            let dis = buildDeviceInfoService()
            deviceInfoServiceObj = dis
            peripheral.add(dis)
        case HIDProfile.deviceInformationService:
            let hid = buildHIDService(includingBattery: batteryServiceObj)
            hidServiceObj = hid
            peripheral.add(hid)
        case HIDProfile.hidService:
            isHIDServiceAdded = true
            startAdvertisingNow()
        default:
            break
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            isAdvertising = false
            lastError = error.localizedDescription
            log.error("startAdvertising error: \(error.localizedDescription, privacy: .public)")
        } else {
            isAdvertising = true
            _trace("advertising as \(advertiseLocalName)")
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        _trackInteraction(from: central)
        subscribedCentrals[central.identifier, default: []].insert(characteristic.uuid)
        _trace("subscribe: \(central.identifier) -> \(characteristic.uuid)")
        if let id = reportID(forCharacteristic: characteristic),
           let cached = cachedReports[id],
           let char = charsByReportID[id]
        {
            _ = updateValue(cached, for: char)
        } else if characteristic.uuid == HIDProfile.bootMouseInputReport, let bootMouseInputChar {
            _ = updateValue(MouseReport.zero.data, for: bootMouseInputChar)
        } else if characteristic.uuid == HIDProfile.bootKeyboardInputReport, let bootKeyboardInputChar {
            _ = updateValue(KeyboardReport.zero.data, for: bootKeyboardInputChar)
        } else if characteristic.uuid == HIDProfile.batteryLevel, let batteryLevelChar {
            _ = updateValue(Data([batteryLevel]), for: batteryLevelChar)
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        _trace("unsubscribe: \(central.identifier) <- \(characteristic.uuid)")
        guard var chars = subscribedCentrals[central.identifier] else { return }
        chars.remove(characteristic.uuid)
        if chars.isEmpty {
            subscribedCentrals.removeValue(forKey: central.identifier)
            centralObjects.removeValue(forKey: central.identifier)
            inactiveCentrals.remove(central.identifier)
            connectedCentrals.remove(central.identifier)
            serviceChangedArmed = false
        } else {
            subscribedCentrals[central.identifier] = chars
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        isReadyToSendNotification = true
        drainPendingBroadcast()
        resumeReadyWaiters()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        _trace("read: \(request.central.identifier) -> \(request.characteristic.uuid)")
        _trackInteraction(from: request.central)
        scheduleServiceChanged()
        let value = readValue(forRequest: request)
        guard let value else {
            peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
            return
        }
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: request.offset ..< value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    private func readValue(forRequest request: CBATTRequest) -> Data? {
        switch request.characteristic.uuid {
        case HIDProfile.batteryLevel: return Data([batteryLevel])
        case HIDProfile.hidInformation: return HIDProfile.hidInformationValue
        case HIDProfile.reportMap: return HIDProfile.reportMapData
        case HIDProfile.protocolMode: return Data([0x01]) // report protocol
        case HIDProfile.manufacturerName: return HIDProfile.manufacturerNameValue
        case HIDProfile.modelNumber: return HIDProfile.modelNumberValue
        case HIDProfile.pnpID: return HIDProfile.pnpIDValue
        case HIDProfile.report:
            if let id = reportID(forCharacteristic: request.characteristic) {
                return cachedReports[id] ?? Data()
            }
            return Data()
        case HIDProfile.bootMouseInputReport: return cachedReports[ReportID.mouse.rawValue]
        case HIDProfile.bootKeyboardInputReport: return cachedReports[ReportID.keyboard.rawValue]
        default: return Data()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            _trace("write: \(request.central.identifier) -> \(request.characteristic.uuid)")
            _trackInteraction(from: request.central)
            handleWriteRequest(request)
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    private func handleWriteRequest(_ request: CBATTRequest) {
        guard let value = request.value else { return }
        switch request.characteristic.uuid {
        case HIDProfile.bootKeyboardOutputReport:
            if let byte = value.first { keyboardLEDs = KeyboardLEDs(byte: byte) }
        case HIDProfile.report:
            if reportID(forCharacteristic: request.characteristic) == ReportID.keyboardLEDs.rawValue,
               let byte = value.first
            {
                keyboardLEDs = KeyboardLEDs(byte: byte)
            }
        case HIDProfile.protocolMode, HIDProfile.hidControlPoint:
            break
        default:
            break
        }
    }
}
