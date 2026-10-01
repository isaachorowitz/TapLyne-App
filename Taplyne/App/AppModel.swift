import AppKit
import IOBluetooth
import Foundation
import os
import TaplyneServer

@MainActor
final class AppModel: ObservableObject {
    let hid = HIDPeripheral()
    let capture = ScreenCaptureManager()
    let registry: PhoneRegistry
    let service: AppPhoneService
    private var agentKeys: [String: String] = [:]
    private var chats: [String: AgentChat] = [:]
    var chat: AgentChat { conversation(for: selectedPhone?.udid ?? "unselected") }
    @Published var agentProvider: String = UserDefaults.standard.string(forKey: "agentProvider") ?? "claude" {
        didSet {
            if oldValue != agentProvider { realtime.stop(); speech.stop() }
            if !Self.isPreview { UserDefaults.standard.set(agentProvider, forKey: "agentProvider") }
        }
    }
    let runnerSetup = RunnerSetup()
    let realtime = RealtimeVoice()
    let speech = ConversationSpeech()
    var voicePhoneID: String?
    let automation: PhoneAutomation
    let bluetooth = ClassicHIDTransport()
    let classic = HIDClassicDevice()
    let classicPairer = ClassicPairer()
    var bridge: TLClassicBridge { bluetooth.bridge }

    @Published var selectedPhoneID: String? { didSet {
        if oldValue != selectedPhoneID { realtime.stop(); speech.stop(); voicePhoneID = nil }
    } }
    @Published private(set) var serverPort: UInt16?
    @Published private(set) var serverError: String?
    @Published private(set) var apiKey: String
    @Published var calibrationStatus: String?

    @Published var serverPortSetting: Int { didSet { if !Self.isPreview { UserDefaults.standard.set(serverPortSetting, forKey: "serverPort") } } }
    @Published var listenOnNetwork: Bool { didSet { if !Self.isPreview { UserDefaults.standard.set(listenOnNetwork, forKey: "listenOnNetwork") } } }
    @Published var agentModel: String { didSet { if !Self.isPreview { UserDefaults.standard.set(agentModel, forKey: "agentModel") } } }

    private var server: TaplyneHTTPServer?
    private lazy var conversationService = AppConversationService(model: self)
    #if DEBUG
    private var debugConsole: DebugConsole?
    #endif
    private var started = false
    private let log = Logger(subsystem: "agency.ziplyne.taplyne", category: "app")

    private static var isPreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["TAPLYNE_PREVIEW"] != nil
        #else
        return false
        #endif
    }

    init() {
        registry = PhoneRegistry(hid: hid, bluetooth: bluetooth, capture: capture)
        service = AppPhoneService(registry: registry)
        automation = PhoneAutomation(service: service)
        let defaults = UserDefaults.standard
        serverPortSetting = defaults.object(forKey: "serverPort") as? Int ?? 7788
        listenOnNetwork = defaults.bool(forKey: "listenOnNetwork")
        agentModel = defaults.string(forKey: "agentModel") ?? ""
        #if DEBUG
        if ProcessInfo.processInfo.environment["TAPLYNE_PREVIEW"] != nil {
            if ProcessInfo.processInfo.environment["TAPLYNE_TEST_IMPORT_OPENAI_KEY"] == "1",
               let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
                _ = Keychain.write(key, account: Keychain.Account.openAIPreview)
            }
            unsetenv("OPENAI_API_KEY")
            unsetenv("TAPLYNE_TEST_IMPORT_OPENAI_KEY")
            serverPortSetting = 17788
            listenOnNetwork = false
            apiKey = "preview-only-no-server"
            if let provider = ProcessInfo.processInfo.environment["TAPLYNE_TEST_AGENT_PROVIDER"], ["openai", "claude", "chatgpt"].contains(provider) { agentProvider = provider }
            if let chosenModel = ProcessInfo.processInfo.environment["TAPLYNE_TEST_AGENT_MODEL"] { agentModel = chosenModel }
            return
        }
        #endif
        if let key = Keychain.read("api-key") {
            apiKey = key
        } else {
            let key = APIKeyGenerator.generate()
            Keychain.write(key, account: "api-key")
            apiKey = key
        }
    }

    func start() {
        guard !started else { return }
        started = true
        registry.relayServerPort = { [weak self] in self?.serverPort }
        capture.start()
        registry.start()
        startServer()
        registry.onControlChange = { [weak self] phone, state in
            guard let self, let chat = self.chats[phone.udid] else { return }
            if state.mode != .automatic { chat.pauseForControlChange() }
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugConsole") {
            let console = DebugConsole(token: apiKey) { [weak self] request in
                await self?.handleDebug(request) ?? ["error": "gone"]
            }
            console.start()
            debugConsole = console
        }
        #endif
    }

    func conversation(for id: String) -> AgentChat {
        if let existing = chats[id] { return existing }
        let chat = AgentChat()
        if agentKeys[id] == nil {
            let key = APIKeyGenerator.generate(); agentKeys[id] = key
            server?.registerAgent(phoneID: id, key: key)
        }
        chat.selectDevice(id)
        chat.mcpURL = { [weak self] in self?.mcpURL }
        chat.apiKey = { [weak self] in self?.agentKeys[id] ?? "" }
        chat.provider = { [weak self] in self?.agentProvider ?? "claude" }
        chat.providerKey = { [weak self] in self?.openAIKey() ?? "" }
        chat.model = { [weak self] in self?.agentModel }
        chat.phoneID = { id }
        chat.phoneContext = { [weak self] in self?.registry.phone(id).map { "Selected device: \($0.title), phone_id \(id)." } ?? "Device unavailable." }
        chat.prepareInput = { [weak self] _ in self?.registry.phone(id)?.controlState.mode == .automatic }
        chat.onResumeReady = { [weak self] _ in self?.registry.phone(id)?.control(.resume) }
        chat.cancelInput = { [weak self] _, command in self?.registry.phone(id)?.control(command) }
        chats[id] = chat
        return chat
    }

    func stopConversations() { realtime.stop(); speech.stop(); for chat in chats.values { chat.stop() } }

    func openAIKey(voice: Bool = false) -> String? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TAPLYNE_PREVIEW"] != nil { return Keychain.read(Keychain.Account.openAIPreview) }
        #endif
        return voice ? Keychain.voiceOpenAIKey() : Keychain.openAIKey()
    }

    func stop() {
        realtime.stop(); speech.stop()
        runnerSetup.stop()
        for chat in chats.values { chat.stop() }
        registry.stopRemoteDevices()
        server?.stop()
        bluetooth.stop()
    }

    var selectedPhone: Phone? {
        selectedPhoneID.flatMap(registry.phone) ?? registry.phones.first(where: \.plugged) ?? registry.phones.first
    }

    // MARK: - Server

    var mcpURL: URL? {
        serverPort.flatMap { URL(string: "http://127.0.0.1:\($0)/mcp") }
    }

    var dashboardURL: URL? {
        serverPort.flatMap { URL(string: "http://127.0.0.1:\($0)/?key=\(apiKey)") }
    }

    func startServer() {
        server?.stop()
        server = nil
        serverPort = nil
        for phone in registry.phones where agentKeys[phone.udid] == nil { agentKeys[phone.udid] = APIKeyGenerator.generate() }
        var configuration = ServerConfiguration(
            host: listenOnNetwork ? "0.0.0.0" : "127.0.0.1",
            port: UInt16(clamping: serverPortSetting),
            apiKey: apiKey,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            companionKeys: Dictionary(uniqueKeysWithValues: registry.phones.compactMap { phone in
                Keychain.read("companion-" + phone.udid).map { (phone.udid, $0) }
            }), agentKeys: agentKeys
        )
        #if DEBUG
        if ProcessInfo.processInfo.environment["TAPLYNE_PREVIEW"] == "remote", ProcessInfo.processInfo.environment["TAPLYNE_TEST_RUNNER_PAIRING_DIR"] == nil, let id = registry.phones.first?.udid {
            configuration.companionKeys = [id: "companion-test-only"]
        }
        #endif
        let server = TaplyneHTTPServer(configuration: configuration, service: service, conversations: conversationService)
        do {
            try server.start()
            self.server = server
            serverPort = server.port
            serverError = nil
            log.info("server on port \(server.port)")
        } catch {
            serverError = "The server could not start on port \(serverPortSetting): \(error.localizedDescription)"
        }
    }

    func regenerateAPIKey() {
        let key = APIKeyGenerator.generate()
        Keychain.write(key, account: "api-key")
        apiKey = key
        startServer()
    }

    var claudeCodeCommand: String {
        "claude mcp add --scope user --transport http taplyne \(mcpURL?.absoluteString ?? "http://127.0.0.1:7788/mcp") --header \"X-API-Key: \(apiKey)\""
    }

    var mcpConfigJSON: String {
        """
        {
          "mcpServers": {
            "taplyne": {
              "type": "http",
              "url": "\(mcpURL?.absoluteString ?? "http://127.0.0.1:7788/mcp")",
              "headers": { "X-API-Key": "\(apiKey)" }
            }
          }
        }
        """
    }

    private func phoneContext() -> String {
        let phones = registry.phones.filter(\.plugged)
        guard !phones.isEmpty else { return "No iPhone is plugged in right now." }
        let lines = phones.map { "- \($0.title): phone_id \($0.udid), \($0.readiness == .ready ? "ready" : ($0.readiness.reason ?? ""))" }
        var text = "Phones on this Mac:\n" + lines.joined(separator: "\n")
        if let selected = selectedPhone, selected.plugged {
            text += "\nOperate only phone_id \(selected.udid) in this conversation. To use another phone, ask the user to select it and start a new conversation."
        }
        return text
    }

    func control(_ phone: Phone, _ command: PhoneControlCommand) {
        if command == .resume, chat.paused, chat.activePhoneID == phone.udid {
            chat.resume()
            return
        }
        phone.control(command)
    }

    // MARK: - Phone maintenance

    func calibrate(_ phone: Phone) async {
        guard let driver = registry.driver(for: phone), let stream = phone.stream else {
            calibrationStatus = phone.readiness.reason ?? "The iPhone is not ready."
            return
        }
        do {
            let result = try await phone.enqueue { [weak self] in
                try await PointerCalibrator(driver: driver, stream: stream) { step in
                    self?.calibrationStatus = step
                }.run()
            }
            phone.config.profile = result.profile
            registry.updateReadiness()
            let worst = Int(result.errors.max() ?? 0)
            calibrationStatus = "Calibrated. Worst landing error \(worst) px."
        } catch {
            calibrationStatus = error.localizedDescription
        }
    }

    /// Identifies the cabled phone and prepares phone-initiated Classic pairing.
    func connectBluetooth(_ phone: Phone) async {
        do {
            let address = try await registry.tool.bluetoothAddress(udid: phone.udid)
            // The HID channels alone do not make mouse input usable on iOS.
            // Enable the pointer as part of the existing phone setup action.
            try await registry.tool.setAssistiveTouch(udid: phone.udid, enabled: true)
            guard await bluetooth.prepare(address: address) else { return }
            phone.config.bluetoothAddress = address
            phone.lastError = nil
            registry.updateReadiness()
        } catch {
            phone.lastError = error.localizedDescription
        }
    }

    func resetAssistiveTouch(_ phone: Phone) async {
        do {
            try await registry.tool.setAssistiveTouch(udid: phone.udid, enabled: false)
            try await Task.sleep(nanoseconds: 800_000_000)
            try await registry.tool.setAssistiveTouch(udid: phone.udid, enabled: true)
        } catch {
            phone.lastError = error.localizedDescription
        }
    }

    func enableAssistiveTouch(_ phone: Phone) async {
        do {
            try await registry.tool.setAssistiveTouch(udid: phone.udid, enabled: true)
        } catch {
            phone.lastError = error.localizedDescription
        }
    }

    func restartPhone(_ phone: Phone) async {
        do {
            try await registry.tool.restart(udid: phone.udid)
        } catch {
            phone.lastError = error.localizedDescription
        }
    }

    #if DEBUG
    /// A private, explicitly requested preview can use a runner already paired by QA.
    /// This never discovers credentials, changes production phone storage, or stages a runner.
    func startRelayPreviewIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TAPLYNE_PREVIEW"] == "remote", let directory = environment["TAPLYNE_TEST_RUNNER_PAIRING_DIR"] else { return false }
        guard !started else { return true }
        started = true
        do {
            let files = FileManager.default
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            let id = environment["TAPLYNE_TEST_PREVIEW_PHONE_ID"] ?? "preview-relay-ipad-20261001"
            guard id.range(of: "^preview-relay-[A-Za-z0-9-]{1,70}$", options: .regularExpression) != nil else { throw RelayFailure("Invalid preview phone identifier.") }
            func privateData(_ name: String) throws -> Data {
                let path = root.appendingPathComponent(name)
                let attributes = try files.attributesOfItem(atPath: path.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                      (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 8_192 else { throw RelayFailure("Preview pairing files must be private regular files owned by this user.") }
                return try Data(contentsOf: path)
            }
            let host = try JSONDecoder().decode(RelayConfiguration.self, from: privateData("host.json")).validated()
            let device = try JSONDecoder().decode(RelayConfiguration.self, from: privateData("device.json")).validated()
            guard host.role == .host, device.role == .device, host.scope == .runner, device.scope == .runner,
                  host.room == device.room, host.endpoint == device.endpoint, host.encryptionKey == device.encryptionKey else { throw RelayFailure("Preview runner roles do not match.") }
            let profile: RelayDeviceProfile
            if let saved = RelayDeviceProfile.load(id) {
                guard saved.runnerHost == host, saved.runnerDevice == device else { throw RelayFailure("Preview pairing differs from its saved profile. Remove the old preview accounts first.") }
                profile = saved
            } else {
                let conversation = try RelayConfiguration.pair(endpoint: host.endpoint, scope: .conversation, enrollment: host.enrollmentToken)
                profile = RelayDeviceProfile(runnerHost: host, runnerDevice: device, conversationHost: conversation.host, conversationDevice: conversation.device)
                try profile.save(id)
            }
            let key = Keychain.read("companion-" + id) ?? APIKeyGenerator.generate()
            guard Keychain.write(key, account: "companion-" + id) else { throw RelayFailure("Could not save the preview companion key.") }
            let pairing = RelayCompanionPairing(configuration: profile.conversationDevice, phoneID: id, companionKey: key)
            for (name, data) in [("companion-pairing.json", try JSONEncoder().encode(pairing)),
                                 ("companion-pairing.url", Data(try pairing.url().absoluteString.utf8))] {
                let path = root.appendingPathComponent(name)
                if files.fileExists(atPath: path.path) { _ = try privateData(name) }
                guard files.createFile(atPath: path.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw RelayFailure("Could not export the private companion pairing.") }
            }
            let phone = Phone(config: PhoneConfig(udid: id, name: "Taplyne relay test iPad", model: "Physical iPad", createdAt: Date(), relayEnabled: true))
            registry.add(phone); selectedPhoneID = id
            registry.relayServerPort = { [weak self] in self?.serverPort }
            registry.onControlChange = { [weak self] phone, state in
                guard let self, let chat = self.chats[phone.udid], state.mode != .automatic else { return }
                chat.pauseForControlChange()
            }
            startServer(); registry.attachRelay(phone)
        } catch { serverError = "Relay preview could not start: " + error.localizedDescription }
        return true
    }

    // MARK: - Development console

    private func handleDebug(_ r: [String: Any]) async -> [String: Any] {
        let cmd = r["cmd"] as? String ?? ""
        let phone = (r["phone"] as? String).flatMap(registry.phone) ?? selectedPhone
        switch cmd {
        case "state":
            return [
                "bt_state": hid.state.rawValue,
                "advertising": hid.isAdvertising,
                "classic_ready_count": bluetooth.readyAddresses.count,
                "classic_state": bridge.managerState(),
                "subscribed": Array(hid.subscribedCentrals.keys.map(\.uuidString)),
                "camera": capture.authorization.rawValue,
                "server_port": Int(serverPort ?? 0),
                "phones": registry.phones.map { p in
                    [
                        "udid": p.udid, "name": p.title, "plugged": p.plugged,
                        "readiness": "\(p.readiness)", "central": p.config.centralID?.uuidString ?? "",
                        "gain": p.config.profile.map { Double($0.gain) } ?? 0,
                        "offset": p.config.profile.map { Double($0.offset) } ?? 0,
                        "size": p.screenSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "",
                        "frames": p.stream?.frameCount ?? -1,
                        "frame_age": p.stream?.lastFrameAt.map { Date().timeIntervalSince($0) } ?? -1
                    ] as [String: Any]
                }
            ]
        case "camera":
            return ["granted": await capture.requestAccess()]
        case "write-key-header":
            // Lets local test scripts authenticate with `curl -H @file` without printing the key.
            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Taplyne/dev-header")
            try? Data("X-API-Key: \(apiKey)\n".utf8).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return ["path": url.path]
        case "advertise-name":
            hid.stop()
            hid.advertiseLocalName = r["name"] as? String ?? (Host.current().localizedName ?? "Taplyne")
            try? await Task.sleep(nanoseconds: 300_000_000)
            hid.start()
            try? await Task.sleep(nanoseconds: 800_000_000)
            return ["advertising": hid.isAdvertising, "name": hid.advertiseLocalName]
        case "chat":
            chat.send(r["text"] as? String ?? "")
            let deadline = Date().addingTimeInterval(Double(r["timeout"] as? Int ?? 240))
            try? await Task.sleep(nanoseconds: 500_000_000)
            while chat.running, Date() < deadline {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            return ["running": chat.running, "entries": chat.entries.map { "\($0.kind): \($0.text)\($0.image == nil ? "" : " [image]")" }]
        case "cb-start":
            // Classic testing must not expose a second, unrelated LE HID entry.
            hid.stop()
            bridge.logHandler = { [weak self] line in self?.log.info("classic bridge: \(line, privacy: .public)") }
            bridge.start()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return ["power": bridge.powerState(), "state": bridge.managerState(), "discoverable": bridge.isDiscoverable(), "connectable": bridge.isConnectable()]
        case "cb-authorize":
            bridge.requestBluetoothAuthorization()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return bridge.authorizationState()
        case "cb-auth-state":
            return bridge.authorizationState()
        case "bluetooth-prepare":
            guard let address = r["address"] as? String,
                  address.range(of: "^[0-9A-F]{2}(:[0-9A-F]{2}){5}$", options: .regularExpression) != nil else {
                return ["error": "invalid address"]
            }
            let ok = await bluetooth.prepare(address: address)
            return ["prepared": ok, "status": bluetooth.status ?? "", "ready": bluetooth.readyAddresses.contains(address)]
        case "cb-state":
            return ["power": bridge.powerState(), "state": bridge.managerState(), "discoverable": bridge.isDiscoverable(), "connectable": bridge.isConnectable(),
                    "paired": bridge.pairedPeers().map { "\($0)" }, "known": bridge.knownPeers().map { "\($0)" }]
        case "cb-sdp":
            return ["sdp": bridge.describeLocalSDP()]
        case "cb-discoverable":
            let on = r["on"] as? Bool ?? true
            bridge.setDiscoverable(on, connectable: on)
            try? await Task.sleep(nanoseconds: 500_000_000)
            return ["discoverable": bridge.isDiscoverable(), "connectable": bridge.isConnectable()]
        case "cb-add-hid":
            let record = SDPRecord.buildHID(reportDescriptor: HIDProfile.reportMapData, name: r["name"] as? String ?? (Host.current().localizedName ?? "Taplyne"),
                                            serviceDescription: "Keyboard and mouse", providerName: "Taplyne")
            let handle = bridge.addServiceData(record as NSDictionary)
            return ["handle": Int(handle)]
        case "cb-add-hid-bin":
            let data = SDPEncoder.hidRecord(reportDescriptor: HIDProfile.reportMapData, name: r["name"] as? String ?? (Host.current().localizedName ?? "Taplyne"))
            let handle = bridge.addServiceData(data as NSData)
            return ["handle": Int(handle), "bytes": data.count]
        case "cb-cod":
            IOBluetoothHostController.default()?.setClassOfDevice(UInt32(r["cod"] as? Int ?? 0x25C0), forTimeInterval: Double(r["seconds"] as? Int ?? 600))
            return ["cod": IOBluetoothHostController.default()?.classOfDevice() ?? 0]
        case "cb-remove":
            bridge.removeServiceHandle(UInt32(r["handle"] as? Int ?? 0))
            return ["ok": true]
        case "cb-peer":
            return ["peer": bridge.describePeer(r["address"] as? String ?? "")]
        case "cb-connect":
            return ["ok": bridge.connectAddress(r["address"] as? String ?? "")]
        case "cb-open":
            let ok = bridge.openPSM(UInt16(r["psm"] as? Int ?? 0x11), address: r["address"] as? String ?? "")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return ["ok": ok, "has": bridge.hasChannelPSM(UInt16(r["psm"] as? Int ?? 0x11), address: r["address"] as? String)]
        case "cb-send":
            let hex = r["hex"] as? String ?? ""
            var bytes = Data()
            var i = hex.startIndex
            while i < hex.endIndex, let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
                if let b = UInt8(hex[i ..< next], radix: 16) { bytes.append(b) }
                i = next
            }
            return ["ok": bridge.send(bytes, psm: UInt16(r["psm"] as? Int ?? 0x13), address: r["address"] as? String)]
        case "cb-listen":
            bridge.prepareIncomingPairing(r["address"] as? String ?? "")
            return ["ok": true]
        case "cb-pair-ready":
            bridge.offerPairAddress(r["address"] as? String ?? "")
            return ["ok": true]
        case "cb-pair":
            bridge.pairAddress(r["address"] as? String ?? "")
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            return ["peer": bridge.describePeer(r["address"] as? String ?? "")]
        case "classic-pair":
            guard let phone else { return ["error": "no phone"] }
            let address = await classicPairer.pair(phoneName: phone.config.name, classic: classic)
            return ["address": address ?? "", "status": classicPairer.status ?? ""]
        case "classic-connect":
            guard let phone, let device = ClassicPairer.pairedDevice(named: phone.config.name),
                  let address = device.addressString else { return ["error": "not classic-paired"] }
            classic.connect(to: PairedDevice(id: address.lowercased().filter(\.isHexDigit), name: phone.config.name, isConnected: false))
            return ["ready": classic.isReady, "error": classic.lastError ?? ""]
        case "classic-mouse":
            let n = r["repeat"] as? Int ?? 1
            for _ in 0 ..< n {
                classic.sendMouse(MouseReport(buttons: MouseButtons(rawValue: UInt8(r["buttons"] as? Int ?? 0)),
                                              dX: Int8(clamping: r["dx"] as? Int ?? 0), dY: Int8(clamping: r["dy"] as? Int ?? 0)))
                try? await Task.sleep(nanoseconds: UInt64((r["intervalMs"] as? Int ?? 10) * 1_000_000))
            }
            return ["ready": classic.isReady, "error": classic.lastError ?? ""]
        case "classic-home":
            classic.sendConsumer(.acHome)
            try? await Task.sleep(nanoseconds: 60_000_000)
            classic.sendConsumer(.zero)
            return ["ready": classic.isReady, "error": classic.lastError ?? ""]
        case "service-changed":
            hid.forceServiceChanged()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            return ["subscribed": Array(hid.subscribedCentrals.keys.map(\.uuidString))]
        case "link":
            guard let phone else { return ["error": "no phone"] }
            await connectBluetooth(phone)
            return ["status": bluetooth.status ?? "", "ready": !bluetooth.readyAddresses.isEmpty]
        case "calibrate":
            guard let phone else { return ["error": "no phone"] }
            await calibrate(phone)
            return ["status": calibrationStatus ?? ""]
        case "raw-mouse":
            guard let phone, let driver = registry.driver(for: phone) else { return ["error": "no driver"] }
            do {
                try await driver.moveUnits(r["dx"] as? Int ?? 0, r["dy"] as? Int ?? 0,
                                        buttons: MouseButtons(rawValue: UInt8(r["buttons"] as? Int ?? 0)))
                return ["ok": true]
            } catch { return ["error": "\(error)"] }
        case "anchor":
            guard let phone, let driver = registry.driver(for: phone) else { return ["error": "no driver"] }
            try? await driver.anchor()
            return ["ok": true]
        case "action":
            guard let phone else { return ["error": "no phone"] }
            guard let data = try? JSONSerialization.data(withJSONObject: r["action"] ?? [:]),
                  let action = DebugAction.decode(data) else { return ["error": "bad action"] }
            do {
                try await AppPhoneService.perform(action, on: phone, registry: registry)
                return ["ok": true]
            } catch {
                return ["error": "\(error)"]
            }
        default:
            return ["error": "unknown cmd \(cmd)"]
        }
    }
    #endif
}

#if DEBUG
/// Parses `{"type":"tap","x":1,"y":2}` style actions for the development console.
private enum DebugAction {
    static func decode(_ data: Data) -> PhoneAction? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func i(_ k: String, _ d: Int = 0) -> Int { o[k] as? Int ?? d }
        switch o["type"] as? String {
        case "tap": return .tap(x: i("x"), y: i("y"))
        case "double_tap": return .doubleTap(x: i("x"), y: i("y"))
        case "long_press": return .tapAndHold(x: i("x"), y: i("y"), durationMs: i("duration", 1000))
        case "flick": return .flick(x: i("x"), y: i("y"), direction: Direction(rawValue: o["direction"] as? String ?? "up") ?? .up)
        case "drag": return .drag(fromX: i("from_x"), fromY: i("from_y"), toX: i("to_x"), toY: i("to_y"), speed: .medium)
        case "type": return .type(text: o["text"] as? String ?? "")
        case "key": return .keypress(key: KeyName(rawValue: o["key"] as? String ?? "enter") ?? .enter, modifiers: [], repeatCount: 1)
        case "home": return .home
        default: return nil
        }
    }
}
#endif
