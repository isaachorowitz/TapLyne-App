@preconcurrency import IOBluetooth
import Foundation
import os

/// Pairs the Mac with an iPhone over Bluetooth Classic, presenting the Mac as a keyboard.
///
/// A Mac's Bluetooth LE advertisement carries its public address, so an iPhone on
/// the same Apple Account folds it into the Mac it already knows and never offers
/// it as a keyboard. Classic pairing from the Mac's side avoids that: the Mac
/// publishes a HID service record, briefly takes a keyboard class of device, finds
/// the iPhone (discoverable while its Bluetooth settings are open), and pairs.
@MainActor
final class ClassicPairer: NSObject, ObservableObject {
    @Published private(set) var status: String?
    @Published private(set) var busy = false

    private var inquiry: IOBluetoothDeviceInquiry?
    private var found: [IOBluetoothDevice] = []
    private var inquiryDone: CheckedContinuation<Void, Never>?
    private var pairing: IOBluetoothDevicePair?
    private var pairingDone: CheckedContinuation<IOReturn, Never>?
    private let log = Logger(subsystem: "agency.ziplyne.taplyne", category: "classic")

    /// The phone's Classic device if it is already paired with this Mac.
    static func pairedDevice(named name: String) -> IOBluetoothDevice? {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return paired.first { same($0.name, name) }
    }

    /// Finds and pairs the iPhone. Returns its Bluetooth address on success.
    func pair(phoneName: String, classic: HIDClassicDevice) async -> String? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false }

        classic.publishService()
        IOBluetoothHostController.default()?.setClassOfDevice(0x2540, forTimeInterval: 180)

        if let existing = Self.pairedDevice(named: phoneName), let address = existing.addressString {
            status = "\(phoneName) is already paired."
            return address
        }

        status = "Searching for \(phoneName). Keep Settings > Bluetooth open on the iPhone."
        found = []
        let inquiry = IOBluetoothDeviceInquiry(delegate: self)!
        inquiry.inquiryLength = 12
        inquiry.updateNewDeviceNames = true
        self.inquiry = inquiry
        await withCheckedContinuation { continuation in
            inquiryDone = continuation
            let result = inquiry.start()
            if result != kIOReturnSuccess {
                log.error("inquiry start failed \(result)")
                inquiryDone = nil
                continuation.resume()
            }
        }
        self.inquiry = nil
        log.info("inquiry found: \(self.found.map { "\($0.name ?? "?") \($0.addressString ?? "")" }.joined(separator: ", "), privacy: .public)")
        guard let device = found.first(where: { Self.same($0.name, phoneName) }) else {
            status = "\(phoneName) did not show up. Open Settings > Bluetooth on the iPhone and try again."
            return nil
        }

        status = "Pairing. Tap Pair on the iPhone when it asks."
        let pair = IOBluetoothDevicePair(device: device)!
        pair.delegate = self
        pairing = pair
        let result: IOReturn = await withCheckedContinuation { continuation in
            pairingDone = continuation
            let started = pair.start()
            if started != kIOReturnSuccess {
                pairingDone = nil
                continuation.resume(returning: started)
            }
        }
        pairing = nil
        guard result == kIOReturnSuccess else {
            status = "Pairing failed (\(String(format: "0x%08X", UInt32(bitPattern: result)))). Try again."
            return nil
        }
        status = "Paired with \(phoneName)."
        return device.addressString
    }

    fileprivate static func same(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        func norm(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{2019}", with: "'").lowercased().trimmingCharacters(in: .whitespaces)
        }
        return norm(a) == norm(b)
    }
}

extension ClassicPairer: @preconcurrency IOBluetoothDeviceInquiryDelegate {
    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        guard let device, !found.contains(where: { $0.addressString == device.addressString }) else { return }
        found.append(device)
    }

    func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32) {}

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        inquiryDone?.resume()
        inquiryDone = nil
    }
}

extension ClassicPairer: @preconcurrency IOBluetoothDevicePairDelegate {
    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        log.info("pairing confirmation \(numericValue)")
        status = "Tap Pair on the iPhone. The code is \(String(format: "%06u", numericValue))."
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }

    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        log.info("pairing passkey \(passkey)")
        status = "Enter \(String(format: "%06u", passkey)) on the iPhone if it asks."
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        log.info("pairing PIN request")
        var pin = BluetoothPINCode()
        pin.data.0 = 0x30; pin.data.1 = 0x30; pin.data.2 = 0x30; pin.data.3 = 0x30
        (sender as? IOBluetoothDevicePair)?.replyPINCode(4, pinCode: &pin)
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        log.info("pairing finished \(error)")
        pairingDone?.resume(returning: error)
        pairingDone = nil
    }
}
