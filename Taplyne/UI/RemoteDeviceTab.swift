import SwiftUI
import TaplyneServer

struct RemoteDeviceTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var relayAddress = UserDefaults.standard.string(forKey: "relayAddress") ?? ""
    @State private var team = UserDefaults.standard.string(forKey: "runnerTeam") ?? ""
    @State private var enrollment = ""
    @State private var status: String?
    @State private var directAddress = ""
    @State private var checking = false
    var body: some View {
        Form {
            Section("Remote runner") {
                Link("Step-by-step remote setup", destination: URL(string: "https://github.com/isaachorowitz/TapLyne-App/blob/main/docs/GETTING-STARTED.md#remote-control-and-phone-voice")!)
                if let phone = model.selectedPhone {
                    Text("Device: \(phone.title)")
                    Text("Before starting: install Xcode and uv, add your Apple Developer account in Xcode, and connect this unlocked device by USB. Enable Developer Mode on the device. You also need your own deployed relay.")
                    TextField("Apple team ID", text: $team)
                    TextField("Relay address", text: $relayAddress, prompt: Text("wss://relay.example.com"))
                    SecureField("Relay enrollment token", text: $enrollment)
                    Text("The relay forwards encrypted traffic. Both endpoints connect outward; your Mac does not need a public port. Deploy the included Relay service to a host you control before using this address.").font(.caption).foregroundStyle(.secondary)
                    Button(phone.config.relayEnabled == true ? "Reinstall and renew runner" : "Install and pair runner") {
                        do {
                            guard let endpoint = URL(string: relayAddress.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw RelayFailure("Enter a relay URL.") }
                            let normalizedTeam = team.trimmingCharacters(in: .whitespacesAndNewlines)
                            let runnerTools = Bundle.main.resourceURL?.appendingPathComponent("RunnerTools")
                            try RunnerSetup.validatePreflight(
                                phoneID: phone.udid,
                                team: normalizedTeam,
                                runnerToolsAvailable: runnerTools.map { FileManager.default.fileExists(atPath: $0.path) } == true
                            )
                            let profile: RelayDeviceProfile
                            if let saved = RelayDeviceProfile.load(phone.udid), phone.config.relayEnabled == true {
                                guard saved.runnerHost.endpoint == endpoint else { throw RelayFailure("Revoke the existing pairing before changing relay hosts.") }
                                profile = saved
                            } else { profile = try model.createRelay(for: phone, endpoint: endpoint, enrollment: enrollment) }
                            try model.runnerSetup.start(phoneID: phone.udid, team: normalizedTeam, configuration: profile.runnerDevice)
                            UserDefaults.standard.set(relayAddress, forKey: "relayAddress")
                            UserDefaults.standard.set(team, forKey: "runnerTeam")
                            enrollment = ""; status = nil
                        } catch { status = error.localizedDescription }
                    }.disabled(model.runnerSetup.running || phone.udid.hasPrefix("remote-"))
                    RunnerSetupStatus(setup: model.runnerSetup)
                    if phone.config.relayEnabled == true {
                        RelayDeviceStatus(phone: phone)
                        Button("Revoke relay and companion pairing", role: .destructive) {
                            model.runnerSetup.stop(); model.revokeRelay(phone)
                            status = "Pairing revoked on this Mac. Install and pair again to reconnect."
                        }
                    }
                } else { Text("Connect and select your iPhone or iPad first.") }
                if let status { Text(status).font(.caption) }
            }
            Section("Verify before leaving the Mac") {
                Text("Setup finishes after launching the runner in the background on your device. Keep your Mac running for AI requests. Check the Device connection, open a fresh screen and try a harmless action, then repeat after disconnecting USB and changing networks. If iOS stops the runner, reconnect and run setup again.")
                Text("The signing profile's expiry appears after a successful build. Reinstall and renew before it expires. Next, open Settings > Phone & iPad, load the relay pairing code and scan it in the companion for text and voice.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Existing private runner") {
                Text("For an existing WebDriverAgent on a trusted private network, enter its endpoint. It must remain private because WebDriverAgent does not authenticate callers.").font(.caption)
                TextField("Runner URL", text: $directAddress, prompt: Text("http://device.local:8100"))
                Button(checking ? "Checking…" : "Verify and add private runner") {
                    let requested = directAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                    checking = true
                    Task {
                        defer { checking = false }
                        do {
                            guard let url = URL(string: requested), EndpointPolicy.allows(url) else {
                                throw RelayFailure("Use HTTPS or the HTTP address of a trusted private runner, such as http://device.local:8100.")
                            }
                            let connection = try WebDriverConnection(endpoint: url)
                            _ = try await connection.screenshot(); await connection.close()
                            guard directAddress.trimmingCharacters(in: .whitespacesAndNewlines) == requested else { return }
                            let phone = try model.registry.addRemote(name: "Private runner", endpoint: url)
                            model.selectedPhoneID = phone.udid; model.startServer()
                            status = "Fresh screen verified and device added."
                        } catch { status = error.localizedDescription }
                    }
                }.disabled(checking)
            }
        }.formStyle(.grouped)
    }
}

private struct RunnerSetupStatus: View {
    @ObservedObject var setup: RunnerSetup
    var body: some View {
        if !setup.status.isEmpty { Text(setup.status).font(.caption) }
        if let expiry = setup.profileExpiry { Text("Signing profile expires: \(expiry)").font(.caption) }
        if setup.running { Button("Cancel setup") { setup.stop() } }
    }
}
private struct RelayDeviceStatus: View {
    @ObservedObject var phone: Phone
    var body: some View {
        if let peer = phone.runnerRelay { RelayPeerStatus(peer: peer, label: "Device") }
        if let peer = phone.conversationRelay { RelayPeerStatus(peer: peer, label: "Companion") }
        if let error = phone.lastError { Text(error).font(.caption).foregroundStyle(.secondary) }
    }
}
private struct RelayPeerStatus: View {
    @ObservedObject var peer: RelayPeer
    let label: String
    var body: some View { Text(label + ": " + peer.message).font(.caption) }
}
