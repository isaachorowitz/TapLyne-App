import SwiftUI
import SystemConfiguration
import TaplyneServer
import CoreImage.CIFilterBuiltins

struct CompanionTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var key: String?
    @State private var keyPhoneID: String?
    @State private var address = ""
    @State private var showCode = false
    @State private var status = ""
    var body: some View {
        Form {
            Section("Pair the phone or iPad companion") {
                Text("Install the companion with Xcode first, then scan this Mac’s pairing code from the companion. The companion is not yet distributed through the App Store.").font(.caption).foregroundStyle(.secondary)
                Link("Companion installation guide", destination: URL(string: "https://github.com/isaachorowitz/TapLyne-App/blob/main/docs/GETTING-STARTED.md#install-the-companion")!)
                if let phone = model.selectedPhone {
                    Text("Selected device: \(phone.title)")
                    Text("This companion key can view and control only this device, including pausing and resuming it. Your regular agent API key cannot use these controls.").font(.caption).foregroundStyle(.secondary)
                    Button("Create a new companion key") {
                        do {
                            let value = try model.rotateCompanionPairing(for: phone)
                            key = value
                            keyPhoneID = phone.udid
                            status = "Pair using this key. Previous companion keys for this device have stopped working."
                        } catch { status = error.localizedDescription }
                    }
                    if phone.config.relayEnabled == true {
                        Text("This device uses the encrypted relay. Scan the code from either Wi-Fi or cellular.")
                        Button("Load relay pairing code") {
                            key = Keychain.read("companion-" + phone.udid)
                            keyPhoneID = key == nil ? nil : phone.udid
                            showCode = key != nil
                        }
                    } else {
                        TextField("Mac address", text: $address, prompt: Text("https://your-mac or http://your-mac.local:7788"))
                    }
                    if let key, keyPhoneID == phone.udid {
                        CopyButton(text: key).help("Copy companion key")
                        Button(showCode ? "Hide pairing code" : "Show pairing code") { showCode.toggle() }
                        if showCode, let pairing = pairingURL(key), let qr = qrImage(pairing) {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 200, height: 200)
                            Text("Scan in the companion, check the connection address, then tap Connect. This code grants control of the selected device; keep it private.").font(.caption)
                        }
                    }
                    Text(status).font(.caption)
                } else { Text("Select a device in the main window first.") }
            }
            Section("Connection") {
                Text("Use the native Taplyne companion on iPhone or iPad. Relay pairing works without exposing the Mac server. For a direct connection, enable private network access in Server settings and use a trusted network or HTTPS.")
                Text("USB mode still requires the controlled device beside your Mac. Wireless device control requires a configured remote transport.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
            .onChange(of: model.selectedPhoneID) { key = nil; keyPhoneID = nil; showCode = false; status = "" }
            .onChange(of: model.selectedPhone?.udid) {
                if keyPhoneID != model.selectedPhone?.udid {
                    key = nil; keyPhoneID = nil; showCode = false; status = ""
                }
            }
            .onAppear { if address.isEmpty { address = "http://" + ((SCDynamicStoreCopyLocalHostName(nil) as String?) ?? "your-mac") + ".local:" + String(model.serverPortSetting) } }
    }
    private func pairingURL(_ key: String) -> String? {
        guard let phone = model.selectedPhone, keyPhoneID == phone.udid else { return nil }
        if phone.config.relayEnabled == true { return try? model.relayPairing(for: phone).absoluteString }
        guard let endpoint = URL(string: address), EndpointPolicy.allows(endpoint) else { return nil }
        var url = URLComponents(); url.scheme = "taplyne"; url.host = "pair"
        url.queryItems = [URLQueryItem(name: "server", value: address), URLQueryItem(name: "key", value: key)]
        return url.url?.absoluteString
    }
    private func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
