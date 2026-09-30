// Vendored from jqssun/darwin-bt-remote (commit ad7a76c, BTRemote/LowEnergy), AGPL-3.0-only.
// See LICENSE-AGPL-3.0 in this folder. Taplyne changes: no state restoration (iOS only),
// strings inlined, log subsystem, connectedPeripherals(withServices:).

import Combine
import CoreBluetooth
import Foundation
import os

/// central-side scanner and connection-event registrar
@MainActor
final class HIDCentral: NSObject, ObservableObject {
    @Published private(set) var state: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var discovered: [DiscoveredPeripheral] = []
    @Published private(set) var connected: Set<UUID> = []
    @Published private(set) var connecting: Set<UUID> = []
    @Published private(set) var lastError: String?


    private let log = Logger(subsystem: "agency.ziplyne.taplyne", category: "HIDCentral")
    private var centralManager: CBCentralManager?
    private var peripheralCache: [UUID: CBPeripheral] = [:]

    private func _trace(_ message: @autoclosure () -> String) {
        guard UserDefaults.standard.object(forKey: "bt.trace") as? Bool ?? true else { return }
        let text = message()
        log.info("\(text, privacy: .public)")
    }

    func start() {
        guard centralManager == nil else { return }
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
    }

    func startScan() {
        guard let centralManager, centralManager.state == .poweredOn else {
            start()
            return
        }
        discovered.removeAll()
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isScanning = true
        _trace("scan started")
    }

    func stopScan() {
        centralManager?.stopScan()
        isScanning = false
        _trace("scan stopped")
    }

    func connect(_ identifier: UUID) {
        guard let centralManager else { return }
        let peripheral = peripheralCache[identifier]
            ?? centralManager.retrievePeripherals(withIdentifiers: [identifier]).first
        guard let peripheral else {
            lastError = "The iPhone is no longer in range (\(identifier))."
            return
        }
        peripheralCache[identifier] = peripheral
        connecting.insert(identifier)
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
        _trace("connect requested: \(peripheral.identifier)")
    }

    /// Taplyne: peripherals already linked to this Mac (for example over Continuity)
    /// that expose any of `services`.
    func connectedPeripherals(withServices services: [CBUUID]) -> [(id: UUID, name: String?)] {
        guard let centralManager else { return [] }
        return centralManager.retrieveConnectedPeripherals(withServices: services).map { peripheral in
            peripheralCache[peripheral.identifier] = peripheral
            return (peripheral.identifier, peripheral.name)
        }
    }

    func disconnect(_ identifier: UUID) {
        guard let centralManager, let peripheral = peripheralCache[identifier] else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func refreshKnownPeripherals(servicesFilter: [CBUUID] = [HIDProfile.hidService]) {
        guard let centralManager else { return }
        let known = centralManager.retrieveConnectedPeripherals(withServices: servicesFilter)
        for peripheral in known {
            peripheralCache[peripheral.identifier] = peripheral
            upsertDiscovered(peripheral: peripheral, advertisementData: [:], rssi: 0)
        }
    }

    private func upsertDiscovered(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: Int
    ) {
        let resolvedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let companyID = Self.companyID(from: advertisementData)
        let txPower = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        _trace(
            "discovered: \(peripheral.identifier) name=\(resolvedName ?? "nil") company=\(companyID ?? 0) services=\(services) rssi=\(rssi)"
        )
        let entry = DiscoveredPeripheral(
            id: peripheral.identifier,
            name: resolvedName ?? "Unknown device",
            isNamed: resolvedName != nil,
            rssi: rssi,
            advertisedServices: services,
            companyID: companyID,
            txPower: txPower,
            isConnectable: isConnectable
        )
        if let index = discovered.firstIndex(where: { $0.id == entry.id }) {
            let existing = discovered[index]
            discovered[index] = DiscoveredPeripheral(
                id: entry.id,
                name: entry.isNamed ? entry.name : existing.name,
                isNamed: existing.isNamed || entry.isNamed,
                rssi: rssi == 0 ? existing.rssi : rssi,
                advertisedServices: services.isEmpty ? existing.advertisedServices : services,
                companyID: companyID ?? existing.companyID,
                txPower: txPower ?? existing.txPower,
                isConnectable: isConnectable ?? existing.isConnectable
            )
        } else {
            discovered.append(entry)
        }
    }

    private static func companyID(from advertisementData: [String: Any]) -> UInt16? {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 2 else { return nil }
        let bytes = [UInt8](data.prefix(2))
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }
}

struct DiscoveredPeripheral: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isNamed: Bool
    var rssi: Int
    var advertisedServices: [CBUUID]
    var companyID: UInt16?
    var txPower: Int?
    var isConnectable: Bool?
}

extension HIDCentral: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        _trace("central state -> \(central.state.rawValue)")
        if central.state == .poweredOn {
            // must happen before HID services are added
            #if os(iOS)
                central.registerForConnectionEvents(options: nil)
            #endif
            refreshKnownPeripherals()
        }
        if central.state != .poweredOn {
            isScanning = false
            connected.removeAll()
            connecting.removeAll()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        _trace("central willRestoreState: \(dict.keys.sorted())")
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in restored {
                peripheralCache[peripheral.identifier] = peripheral
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        peripheralCache[peripheral.identifier] = peripheral
        upsertDiscovered(
            peripheral: peripheral,
            advertisementData: advertisementData,
            rssi: RSSI.intValue
        )
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connecting.remove(peripheral.identifier)
        connected.insert(peripheral.identifier)
        _trace("connected: \(peripheral.identifier)")
        peripheralCache[peripheral.identifier] = peripheral
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        connecting.remove(peripheral.identifier)
        connected.remove(peripheral.identifier)
        if let error {
            log.error("disconnected with error: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        } else {
            _trace("disconnected: \(peripheral.identifier)")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        connecting.remove(peripheral.identifier)
        if let error {
            lastError = "Could not connect: \(error.localizedDescription)"
            log.error("failed to connect: \(error.localizedDescription, privacy: .public)")
        }
    }
}
