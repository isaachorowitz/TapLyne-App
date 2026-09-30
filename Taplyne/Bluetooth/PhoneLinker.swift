import CoreBluetooth
import Foundation
import os

/// Connects the Mac to an iPhone over Bluetooth LE from the Mac's side.
///
/// A Mac and iPhone on the same Apple Account are already paired through iCloud,
/// so the Mac never appears in the iPhone's Settings > Bluetooth. Instead the Mac
/// connects to the phone, and the phone then finds Taplyne's keyboard-and-mouse
/// service on the existing bond and subscribes to it.
@MainActor
final class PhoneLinker: ObservableObject {
    @Published private(set) var status: String?
    @Published private(set) var busy = false

    let central = HIDCentral()
    private let log = Logger(subsystem: "agency.ziplyne.taplyne", category: "linker")

    /// Services an iPhone exposes over an existing link: Device Information and
    /// Apple's Continuity service.
    private static let appleServices = [
        CBUUID(string: "180A"),
        CBUUID(string: "D0611E78-BBB4-4591-A5F8-487910AE4366"),
        CBUUID(string: "9FA480E0-4967-4542-9390-D343DC5D04AE")
    ]

    /// Connects to the phone named `phoneName` and waits until `isSubscribed` reports
    /// that it picked up the HID service.
    func link(phoneName: String, isSubscribed: @escaping () -> Bool, timeout: TimeInterval = 25) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        central.start()
        status = "Turning on Bluetooth"
        guard await waitUntil(5, { self.central.state == .poweredOn }) else {
            status = "Bluetooth is off or Taplyne is not allowed to use it."
            return false
        }

        status = "Looking for \(phoneName)"
        var target = central.connectedPeripherals(withServices: Self.appleServices)
            .first { Self.same($0.name, phoneName) }?.id
        if target == nil {
            central.startScan()
            _ = await waitUntil(12) {
                target = self.central.discovered.first { Self.same($0.name, phoneName) }?.id
                return target != nil
            }
            central.stopScan()
        }
        guard let target else {
            status = "\(phoneName) was not found nearby. Make sure its Bluetooth is on."
            return false
        }

        status = "Connecting to \(phoneName). Accept any pairing request on the iPhone."
        log.info("connecting to \(target.uuidString, privacy: .public)")
        central.connect(target)
        let subscribed = await waitUntil(timeout, isSubscribed)
        status = subscribed ? "Connected." : "Connected, but the iPhone has not started using Taplyne's mouse yet. Try again, or pair from the iPhone's Bluetooth settings."
        return subscribed
    }

    private static func same(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        func norm(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{2019}", with: "'").lowercased().trimmingCharacters(in: .whitespaces)
        }
        return norm(a) == norm(b)
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return condition()
    }
}
