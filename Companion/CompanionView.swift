import SwiftUI
import VisionKit

struct CompanionView: View {
    @ObservedObject var connection: CompanionConnection
    @ObservedObject var speech: ConversationSpeech
    @ObservedObject var realtime: RealtimeVoice
    @State private var scanPairing = false
    @State private var liveVoice = true
    @State private var draft = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if connection.connected { conversation } else { setup }
                if let error = connection.error ?? realtime.error ?? speech.error {
                    Text(error).font(.callout).foregroundStyle(.red).padding()
                }
            }
            .navigationTitle("Taplyne")
            .toolbar {
                if connection.connected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Disconnect") { realtime.stop(); speech.stop(); connection.disconnect() }
                    }
                }
            }
        }
        .sheet(isPresented: $scanPairing) {
            NavigationStack {
                PairingScanner { url in scanPairing = false; connection.acceptPairing(url) }
                    .navigationTitle("Scan Mac pairing code")
                    .toolbar { Button("Cancel") { scanPairing = false } }
            }
        }
        .onChange(of: connection.selectedDevice) { _, _ in realtime.stop(); speech.stop() }
        .onChange(of: connection.connected) { _, connected in
            if connected { realtime.dependencyReconnected() }
        }
        .onAppear {
            realtime.credentials = { try await connection.voiceCredential() }
            realtime.runTask = { try await connection.runVoiceTask($0) }
            realtime.interruptTask = { connection.interruptVoice() }

            speech.onUtterance = { connection.sendVoiceUtterance($0) }
            speech.onInterruption = { connection.interruptVoice() }
            connection.onReply = { speech.speak($0) }
            connection.onConnectionLost = { realtime.dependencyDisconnected(); speech.stop() }
        }
    }

    private var setup: some View {
        Form {
            Section("Connect to your Mac") {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    Button("Scan pairing code") { scanPairing = true }
                }
                if let pairing = connection.relayPairing {
                    Text("Encrypted relay: " + (pairing.configuration.endpoint.host ?? ""))
                    Button("Use a direct Mac address") { connection.useDirectConnection() }
                } else {
                TextField("https://your-mac or http://your-mac.local:7788", text: $connection.address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("Device companion key", text: $connection.token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button(connection.connecting ? "Connecting…" : "Connect") { Task { await connection.connect() } }.disabled(connection.connecting)
            }
            Section {
                Text("Keep Taplyne running on your Mac. Scan a relay pairing code to connect across networks without a public Mac port. A direct private-network connection is also available.")
                Text("Your iPhone or iPad stays unlocked. Remote control requires the signed Taplyne runner to stay active. Verify the connection after removing USB or changing networks.")
                Text("Live AI voice streams microphone audio to OpenAI and uses separately billed API access configured on the Mac. Native dictation uses on-device recognition where available and Apple speech services for other languages. Your selected AI provider receives your requests and screen evidence.")
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 12) {
            Picker("Device", selection: $connection.selectedDevice) {
                ForEach(connection.devices) { device in Text(device.displayName ?? device.name).tag(device.id) }
            }.padding(.horizontal).disabled(connection.sending || speech.listening || realtime.active || realtime.connecting)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(connection.snapshot?.messages ?? []) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.kind.capitalized).font(.caption).foregroundStyle(.secondary)
                                Text(message.text).textSelection(.enabled)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(message.kind == "user" ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                                .id(message.id)
                        }
                    }.padding()
                }.onChange(of: connection.snapshot?.messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            HStack {
                Text(connection.snapshot?.paused == true ? "Paused" : connection.snapshot?.running == true ? "Working" : "Ready")
                Spacer()
                Button("Stop", role: .destructive) { realtime.stop(); speech.stop(); connection.interruptVoice(); Task { await connection.send("stop") } }
                if connection.snapshot?.paused == true { Button("Resume") { Task { await connection.send("resume") } } }
            }
            if speech.listening { Text(speech.transcript.isEmpty ? "Listening…" : speech.transcript).font(.caption) }
            Picker("Voice mode", selection: $liveVoice) {
                Text("Live AI voice (API)").tag(true); Text("Native dictation").tag(false)
            }.pickerStyle(.segmented).disabled(speech.listening || realtime.active || realtime.connecting)
            if liveVoice {
                if realtime.microphoneState != .idle {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(realtime.microphoneStatus, systemImage: "mic.fill")
                            Spacer()
                            if realtime.providerSpeechDetected { Text("Speech received").foregroundStyle(.secondary) }
                        }.font(.caption)
                        ProgressView(value: Double(realtime.microphoneLevel))
                            .accessibilityLabel("Microphone input level")
                        if !realtime.microphoneName.isEmpty {
                            Text(realtime.microphoneName).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if !realtime.transcript.isEmpty { Text(realtime.transcript).font(.caption).lineLimit(3) }
                HStack {
                    Button(realtime.active ? "End live voice" : realtime.connecting ? "Cancel connection" : "Start live voice") {
                        if realtime.active || realtime.connecting { realtime.stop() } else { realtime.start() }
                    }
                    if realtime.active { Button("Interrupt") { realtime.interrupt() } }
                }
            } else {
                HStack {
                    Picker("Language", selection: $speech.localeIdentifier) { Text("English").tag("en-US"); Text("עברית").tag("he-IL") }.disabled(speech.listening)
                    Button(speech.listening ? "End voice" : "Start voice") {
                        if speech.listening { speech.stop(); connection.interruptVoice() } else { speech.start() }
                    }
                    if speech.speaking { Button("Interrupt") { speech.interrupt() } }
                }
            }
            HStack(alignment: .bottom) {
                TextField("Ask or steer the agent", text: $draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
                Button("Send") {
                    let text = draft; draft = ""
                    Task { await connection.send("send", text: text) }
                }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection.sending)
            }
        }.padding(.horizontal).padding(.bottom).frame(maxWidth: 900)
    }
}
