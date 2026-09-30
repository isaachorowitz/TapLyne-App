import Combine
import Foundation
import os
import TaplyneServer

/// What Taplyne remembers about a phone between launches.
struct PhoneConfig: Codable, Equatable {
    var udid: String
    var name: String
    var displayName: String?
    var model: String?
    var iosVersion: String?
    var createdAt: Date
    /// The Bluetooth central this phone connects as. Set when it pairs.
    var centralID: UUID?
    /// Verified over USB; never inferred from a nearby device's display name.
    var bluetoothAddress: String?
    /// Nil until the pointer is calibrated.
    var profile: PointerProfile?
    var width: Int?
    var height: Int?
    var apps: [AppEntry]?
    var appsUpdatedAt: Date?
}

/// One action as it starts running on a phone.
struct ActionEvent: Equatable {
    let id = UUID()
    let action: PhoneAction
    /// True when an agent sent it through the server rather than the person at the Mac.
    let byAgent: Bool
}

/// One iPhone known to this Mac, plugged in or not.
@MainActor
final class Phone: ObservableObject, Identifiable {
    enum Readiness: Equatable {
        case unplugged
        case needsCamera
        case locked
        case waitingForScreen
        case needsBluetooth
        case needsCalibration
        case ready

        var reason: String? {
            switch self {
            case .unplugged: "The iPhone is not plugged into this Mac."
            case .needsCamera: "Allow Camera access so Taplyne can see the iPhone's screen."
            case .locked: "Unlock the iPhone. Set Auto-Lock to Never so it stays unlocked."
            case .waitingForScreen: "Waiting for the iPhone's screen. Unlock it, and tap Trust if it asks."
            case .needsBluetooth: "Bluetooth input is not connected. Prepare pairing, then select this Mac in the iPhone's Bluetooth settings."
            case .needsCalibration: "Calibrate the pointer in Taplyne."
            case .ready: nil
            }
        }
    }

    nonisolated let udid: String
    nonisolated var id: String { udid }
    @Published var config: PhoneConfig { didSet { onConfigChange?() } }
    @Published fileprivate(set) var plugged = false
    @Published fileprivate(set) var captureDeviceID: String?
    @Published fileprivate(set) var readiness: Readiness = .unplugged
    fileprivate(set) var locked = false
    fileprivate var lockCheckedAt = Date.distantPast
    @Published var activity: String?
    @Published var lastError: String?
    /// The action the phone just started, so the screen can show where it landed.
    @Published var lastAction: ActionEvent?

    fileprivate(set) var stream: ScreenStream?
    fileprivate(set) var driver: PhoneDriver?
    fileprivate var onConfigChange: (() -> Void)?
    let inputQueue = PhoneInputQueue()
    @Published private(set) var controlState = PhoneControlState()
    @Published var lastVerification: Verification?

    init(config: PhoneConfig) {
        udid = config.udid
        self.config = config
        inputQueue.onStateChange = { [weak self] in self?.controlState = $0 }
    }

    var title: String { config.displayName ?? config.name }

    var screenSize: CGSize? {
        if let size = stream?.frameSize { return CGSize(width: size.width, height: size.height) }
        if let w = config.width, let h = config.height { return CGSize(width: w, height: h) }
        return nil
    }

    /// Runs `work` after every earlier job on this phone, so gestures never interleave.
    func enqueue<T: Sendable>(origin: InputOrigin = .manual, expected: PhoneControlState? = nil,
                              _ work: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        try await inputQueue.enqueue(origin: origin, expected: expected, work)
    }

    func publishControl(_ state: PhoneControlState) { controlState = state }

    @discardableResult func control(_ command: PhoneControlCommand) -> PhoneControlState {
        inputQueue.control(command)
    }

    var record: PhoneRecord {
        let size = screenSize
        return PhoneRecord(
            id: udid,
            name: config.name,
            displayName: config.displayName,
            connectionStatus: readiness == .ready ? .online : (plugged ? .available : .offline),
            statusReason: readiness.reason,
            width: size.map { Int($0.width) },
            height: size.map { Int($0.height) },
            model: config.model,
            createdAt: config.createdAt
        )
    }
}

@MainActor
final class PhoneRegistry: ObservableObject {
    @Published private(set) var phones: [Phone] = []

    let hid: HIDPeripheral
    let bluetooth: ClassicHIDTransport
    let capture: ScreenCaptureManager
    let tool = DeviceTool()
    private let usbmux = UsbmuxMonitor()
    private var cancellables: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    var onControlChange: ((Phone, PhoneControlState) -> Void)?
    private let log = Logger(subsystem: "agency.ziplyne.taplyne", category: "registry")

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Taplyne", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("phones.json")
    }

    init(hid: HIDPeripheral, bluetooth: ClassicHIDTransport, capture: ScreenCaptureManager) {
        self.hid = hid
        self.bluetooth = bluetooth
        self.capture = capture
        load()
    }

    func start() {
        usbmux.start { [weak self] in self?.scheduleRefresh() }
        capture.$devices.sink { [weak self] _ in self?.scheduleRefresh(delay: 0.2) }.store(in: &cancellables)
        capture.$authorization.sink { [weak self] _ in self?.scheduleRefresh(delay: 0.2) }.store(in: &cancellables)
        hid.$subscribedCentrals.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateReadiness() }
        }.store(in: &cancellables)
        bluetooth.$readyAddresses.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateReadiness() }
        }.store(in: &cancellables)
        // Frames arriving (or stopping) change readiness; check a few times a second.
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.updateReadiness() }
            .store(in: &cancellables)
        scheduleRefresh(delay: 0)
    }

    func phone(_ udid: String) -> Phone? {
        phones.first { $0.udid == udid }
    }

    func scheduleRefresh(delay: TimeInterval = 0.8) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Re-reads which phones are plugged in and wires each to its screen stream.
    func refresh() async {
        let usb: [DeviceTool.USBDevice]
        do {
            usb = try await tool.usbDevices()
        } catch {
            log.error("usb list failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        for device in usb where phone(device.udid) == nil {
            let config = PhoneConfig(udid: device.udid, name: device.name, model: device.productType,
                                     iosVersion: device.iosVersion, createdAt: Date())
            add(Phone(config: config))
        }
        for phone in phones {
            let device = usb.first { $0.udid == phone.udid }
            if phone.plugged && device == nil { phone.control(.stop) }
            phone.plugged = device != nil
            if let device {
                if phone.config.name != device.name { phone.config.name = device.name }
                if phone.config.iosVersion != device.iosVersion { phone.config.iosVersion = device.iosVersion }
            }
            let captureID = phone.plugged ? capture.deviceID(forUDID: phone.udid, name: phone.config.name) : nil
            if captureID != phone.captureDeviceID {
                if let old = phone.captureDeviceID { capture.stopStream(for: old) }
                phone.captureDeviceID = captureID
                phone.stream = nil
            }
            if let captureID, phone.stream == nil {
                phone.stream = capture.stream(for: captureID)
            }
        }
        autoBindCentral()
        updateReadiness()
    }

    /// With one unbound phone and one unbound Bluetooth connection, they belong together.
    func autoBindCentral() {
        let bound = Set(phones.compactMap(\.config.centralID))
        let freeCentrals = hid.subscribedCentrals.keys.filter { !bound.contains($0) }
        let unbound = phones.filter { $0.plugged && $0.config.centralID == nil }
        if freeCentrals.count == 1, unbound.count == 1, let central = freeCentrals.first {
            log.info("binding central \(central.uuidString, privacy: .public) to \(unbound[0].title, privacy: .public)")
            unbound[0].config.centralID = central
        }
    }

    func updateReadiness() {
        restartSilentStreams()
        for phone in phones {
            let readiness: Phone.Readiness
            if !phone.plugged {
                readiness = .unplugged
            } else if capture.authorization != .authorized {
                readiness = .needsCamera
            } else if phone.locked {
                readiness = .locked
            } else if phone.stream?.lastFrameAt == nil {
                readiness = .waitingForScreen
            } else if phone.config.bluetoothAddress.map({ bluetooth.readyAddresses.contains($0) }) != true {
                readiness = .needsBluetooth
            } else if phone.config.profile?.verifiedErrorPx.map({ $0 <= 30 }) != true {
                readiness = .needsCalibration
            } else {
                readiness = .ready
            }
            if phone.readiness != readiness { phone.readiness = readiness }
            if let size = phone.stream?.frameSize, phone.config.width != size.width || phone.config.height != size.height {
                phone.config.width = size.width
                phone.config.height = size.height
            }
            syncDriver(phone)
        }
    }

    /// A silent stream means either a locked phone (nothing to do but ask) or a stream
    /// bound to a device that re-enumerated on USB (restart it once unlocked).
    private func restartSilentStreams() {
        let now = Date()
        for phone in phones where phone.plugged {
            guard let id = phone.captureDeviceID, let stream = phone.stream else { continue }
            let last = stream.lastFrameAt ?? stream.startedAt
            let silent = now.timeIntervalSince(last) > 5
            if !silent {
                if phone.locked { phone.locked = false }
                continue
            }
            guard now.timeIntervalSince(phone.lockCheckedAt) > 4 else { continue }
            phone.lockCheckedAt = now
            let udid = phone.udid
            Task { [weak self] in
                guard let self else { return }
                let locked = (try? await self.tool.isLocked(udid: udid)) ?? false
                phone.locked = locked
                if !locked, now.timeIntervalSince(stream.startedAt) > 5, phone.stream === stream {
                    self.log.info("screen silent for \(phone.title, privacy: .public); restarting capture")
                    phone.stream = self.capture.restartStream(for: id)
                }
                self.updateReadiness()
            }
        }
    }

    /// The driver used for input. It exists once the phone is paired, even before
    /// calibration, because calibration itself needs it.
    func driver(for phone: Phone) -> PhoneDriver? {
        syncDriver(phone)
        return phone.driver
    }

    private func syncDriver(_ phone: Phone) {
        guard let address = phone.config.bluetoothAddress, let size = phone.screenSize else {
            phone.driver = nil
            return
        }
        let profile = phone.config.profile ?? PointerProfile()
        if let driver = phone.driver {
            driver.address = address
            if driver.screen != size {
                phone.control(.pause)
                driver.invalidatePointer()
            }
            driver.screen = size
            if phone.config.profile != nil && !driver.isCalibrating && !phone.inputQueue.hasActiveInput { driver.profile = profile }
        } else {
            phone.driver = PhoneDriver(bluetooth: bluetooth, address: address, profile: profile, screen: size)
        }
        phone.driver?.frameProvider = { [weak phone] in
            guard let stream = phone?.stream, let frame = await stream.nextImage(after: Date(), timeout: 2) else {
                throw PhoneServiceError.failed("CAPTURE_STALE: No fresh frame is available for pointer aiming.")
            }
            return frame
        }
    }

    func forgetBluetooth(_ phone: Phone) {
        phone.control(.stop)
        if let address = phone.config.bluetoothAddress { bluetooth.disconnect(address: address) }
        phone.config.bluetoothAddress = nil
        phone.config.centralID = nil
        phone.driver = nil
        updateReadiness()
    }

    func remove(_ phone: Phone) {
        phone.control(.stop)
        if let id = phone.captureDeviceID { capture.stopStream(for: id) }
        phones.removeAll { $0 === phone }
        save()
    }

    // MARK: - Persistence

    private func add(_ phone: Phone) {
        phone.onConfigChange = { [weak self] in self?.save() }
        phone.inputQueue.onStateChange = { [weak self, weak phone] state in
            guard let phone else { return }
            phone.publishControl(state)
            self?.onControlChange?(phone, state)
        }
        phones.append(phone)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let configs = (try? decoder.decode([PhoneConfig].self, from: data)) ?? []
        for config in configs {
            let phone = Phone(config: config)
            phone.onConfigChange = { [weak self] in self?.save() }
        phone.inputQueue.onStateChange = { [weak self, weak phone] state in
            guard let phone else { return }
            phone.publishControl(state)
            self?.onControlChange?(phone, state)
        }
            phones.append(phone)
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(phones.map(\.config)) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}

#if DEBUG
extension PhoneRegistry {
    /// Replaces the phones with unsaved fakes so the UI can be reviewed without hardware.
    /// Only `TAPLYNE_PREVIEW` launches of a Debug build call this.
    func seedPreview(_ scenario: String) {
        func phone(_ name: String, _ readiness: Phone.Readiness, plugged: Bool) -> Phone {
            let config = PhoneConfig(udid: "preview-\(name)", name: name, model: "iPhone18,2",
                                     iosVersion: "26.0", createdAt: Date(), width: 1320, height: 2868)
            let phone = Phone(config: config)
            phone.plugged = plugged
            phone.readiness = readiness
            return phone
        }
        switch scenario {
        case "empty":
            phones = []
        case "ready":
            phones = [phone("Demo iPhone", .ready, plugged: true), phone("Test iPhone", .unplugged, plugged: false)]
        default:
            phones = [phone("Demo iPhone", .needsBluetooth, plugged: true), phone("Test iPhone", .unplugged, plugged: false)]
        }
    }
}
#endif
