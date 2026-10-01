import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            ConnectTab().tabItem { Label("Connect AI", systemImage: "point.3.connected.trianglepath.dotted") }
            ServerTab().tabItem { Label("Server", systemImage: "server.rack") }
            RemoteDeviceTab().tabItem { Label("Remote device", systemImage: "network") }
            CompanionTab().tabItem { Label("Phone & iPad", systemImage: "iphone.gen3") }
            AgentTab().tabItem { Label("Agent", systemImage: "sparkles") }
        }
        .frame(width: 620, height: 500)
    }
}

/// Monospaced text on a quiet panel with a copy button beside it.
private struct CodeBlock: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: text)
                .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}

private struct ConnectTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Text("Run this once in a terminal to give Claude Code your iPhones.")
                    .font(.callout).foregroundStyle(.secondary)
                CodeBlock(text: model.claudeCodeCommand)
            } header: {
                Label("Claude Code", systemImage: "terminal")
            }
            Section {
                Text("Streamable HTTP. The API key goes in the X-API-Key header.")
                    .font(.callout).foregroundStyle(.secondary)
                CodeBlock(text: model.mcpConfigJSON)
            } header: {
                Label("Any MCP client", systemImage: "point.3.connected.trianglepath.dotted")
            }
            Section {
                LabeledContent("Base URL") {
                    Text(verbatim: "http://127.0.0.1:\(model.serverPort.map(String.init) ?? "7788")/v1")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let url = model.dashboardURL {
                    Link(destination: url) {
                        Label("Open the live dashboard in a browser", systemImage: "arrow.up.right.square")
                    }
                }
            } header: {
                Label("REST API", systemImage: "network")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ServerTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var revealKey = false
    @State private var confirmNewKey = false
    @State private var keyChanged = 0

    var body: some View {
        Form {
            Section {
                TextField("Port", value: $model.serverPortSetting, format: .number.grouping(.never))
                    .font(.body.monospacedDigit())
                Toggle(isOn: $model.listenOnNetwork) {
                    Text("Allow other devices on the network")
                    Text("Off keeps the server on this Mac only. On lets anything that can reach this Mac and has the API key control your phones.")
                }
                .toggleStyle(.switch)
                HStack {
                    if let port = model.serverPort {
                        Label {
                            Text(verbatim: "Running on port \(port)")
                        } icon: {
                            StatusDot(color: .green, pulsing: true)
                        }
                        .foregroundStyle(.green)
                    } else if let error = model.serverError {
                        Label {
                            Text(error)
                        } icon: {
                            StatusDot(color: .red, square: true)
                        }
                        .foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Restart Server") { model.startServer() }
                }
                .animation(Motion.standard, value: model.serverPort)
            } header: {
                Label("Local server", systemImage: "server.rack")
            }
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "key").foregroundStyle(.secondary)
                    Text(revealKey ? model.apiKey : String(repeating: "•", count: 24))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .contentTransition(.opacity)
                        .id(keyChanged)
                        .transition(.opacity)
                    Spacer()
                    Button {
                        withAnimation(Motion.standard) { revealKey.toggle() }
                    } label: {
                        Label(revealKey ? "Hide" : "Show", systemImage: revealKey ? "eye.slash" : "eye")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    CopyButton(text: model.apiKey)
                }
                HStack {
                    Text("A new key stops the old one immediately. Update any agent that used it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Generate New Key…") { confirmNewKey = true }
                }
            } header: {
                Label("API key", systemImage: "key")
            }
        }
        .formStyle(.grouped)
        .alert("Generate a new API key?", isPresented: $confirmNewKey) {
            Button("Generate New Key", role: .destructive) {
                model.regenerateAPIKey()
                withAnimation(Motion.standard) { keyChanged += 1 }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current key stops working immediately. Every agent that uses it, including Claude Code, needs the new key.")
        }
    }
}

private struct AgentTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var apiKey = ""
    @State private var voiceKey = ""
    @ObservedObject private var chatGPT = ChatGPTAuth.shared
    @State private var keyConfigured = Keychain.contains(Keychain.Account.openAI)
    @State private var voiceOverrideConfigured = Keychain.contains(Keychain.Account.openAIVoiceOverride)
    @State private var keyStatus = Keychain.contains(Keychain.Account.openAI) ? "Key saved in Keychain. Validate it before the first run." : "No OpenAI API key saved."
    @State private var validatingKey = false
    @State private var confirmingKeyRemoval = false

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $model.agentProvider) {
                    Text("OpenAI API key (BYOK)").tag("openai")
                    Text("ChatGPT plan").tag("chatgpt")
                    Text("Claude Code login").tag("claude")
                }.onChange(of: model.agentProvider) { model.stopConversations(); model.agentModel = "" }
                if model.agentProvider != "chatgpt" {
                    TextField("Model", text: $model.agentModel,
                              prompt: Text(model.agentProvider == "openai" ? "gpt-5.4" : "Claude Code's default"))
                }
                if model.agentProvider == "claude" {
                    Text("Runs through your existing Claude Code login and exposes only Taplyne's phone tools.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Claude Code") {
                        if let path = AgentChat.claudeExecutable?.path {
                            Label(path, systemImage: "checkmark.circle.fill")
                                .font(.system(.callout, design: .monospaced)).foregroundStyle(.green).textSelection(.enabled)
                        } else {
                            Label("Not found", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
            } header: {
                Label("Reasoning provider", systemImage: "sparkles")
            } footer: {
                Text("Taplyne runs the agent on this Mac and limits it to the selected phone. Screen evidence and requests go only to the provider you choose.")
            }

            if model.agentProvider == "openai" {
                Section {
                    SecureField("OpenAI API key", text: $apiKey)
                    HStack {
                        Button("Save key") { savePrimaryKey() }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button(validatingKey ? "Validating…" : "Validate saved key") { validatePrimaryKey() }
                            .disabled(!keyConfigured || validatingKey)
                        Spacer()
                        if keyConfigured { Button("Remove key…", role: .destructive) { confirmingKeyRemoval = true } }
                    }
                    Label(keyStatus, systemImage: keyConfigured ? "key.fill" : "key.slash")
                        .font(.caption).foregroundStyle(keyConfigured ? Color.secondary : Color.orange)
                } header: {
                    Label("Your OpenAI API key", systemImage: "key")
                } footer: {
                    Text("Stored in this Mac's Keychain. API usage is billed to your OpenAI project. Taplyne caps each model response and never bundles a shared key.")
                }
            }

            if model.agentProvider == "chatgpt" {
                Section {
                    if !chatGPT.profiles.isEmpty {
                        Picker("Active account", selection: Binding(
                            get: { chatGPT.activeProfileID ?? "" },
                            set: { id in model.stopConversations(); model.agentModel = ""; Task { await chatGPT.selectProfile(id) } }
                        )) {
                            ForEach(chatGPT.profiles) { profile in
                                Text(profile.label + (profile.connected ? "" : " — signed out")).tag(profile.id)
                            }
                        }
                    }
                    if let profile = chatGPT.activeProfile {
                        LabeledContent("Status") {
                            if profile.connected && profile.sharingEnabled { Label("Plan usage enabled", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                            else if profile.connected { Label("Connected; plan usage off", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                            else { Label("Signed out", systemImage: "person.crop.circle.badge.xmark").foregroundStyle(.secondary) }
                        }
                        if profile.connected && profile.sharingEnabled {
                            Picker("ChatGPT model", selection: $model.agentModel) {
                                Text("First eligible model").tag("")
                                ForEach(chatGPT.models) { Text($0.name).tag($0.id) }
                            }
                        }
                        HStack {
                            if profile.connected {
                                Button(profile.sharingEnabled ? "Reconnect" : "Enable plan usage") {
                                    model.stopConversations(); chatGPT.reauthorize(profile.id)
                                }
                                Button("Sign out") { model.stopConversations(); Task { await chatGPT.signOut(profileID: profile.id) } }
                            } else {
                                Button("Reconnect") { model.stopConversations(); chatGPT.reauthorize(profile.id) }
                                Button("Forget registration", role: .destructive) { chatGPT.forgetProfile(profile.id) }
                            }
                        }
                    } else {
                        Text("Connect an eligible ChatGPT account to use its plan for reasoning.").foregroundStyle(.secondary)
                    }
                    if chatGPT.signingIn { Button("Cancel sign-in") { chatGPT.cancelSignIn() } }
                    else { Button(chatGPT.profiles.isEmpty ? "Continue with ChatGPT" : "Add another account") { model.stopConversations(); chatGPT.addAccount() } }
                    if let error = chatGPT.error { Text(error).font(.caption).foregroundStyle(.red) }
                } header: {
                    Label("ChatGPT accounts", systemImage: "person.2")
                } footer: {
                    Text("ChatGPT plan usage is optional and account-specific. Switching accounts stops active conversations; a run keeps the account it started with.")
                }
            }

            Section {
                LabeledContent("Voice billing") {
                    Text(voiceOverrideConfigured ? "Separate voice key" : keyConfigured ? "Primary OpenAI key" : "Not configured")
                        .foregroundStyle((voiceOverrideConfigured || keyConfigured) ? Color.secondary : Color.orange)
                }
                SecureField("Optional voice-only OpenAI key", text: $voiceKey)
                HStack {
                    Button("Save voice override") { saveVoiceKey() }
                        .disabled(voiceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if voiceOverrideConfigured {
                        Button("Use primary key") { Keychain.delete(Keychain.Account.openAIVoiceOverride); voiceOverrideConfigured = false; voiceKey = "" }
                    }
                }
            } header: {
                Label("Live AI voice", systemImage: "waveform")
            } footer: {
                Text("Voice uses the primary OpenAI key by default, regardless of the reasoning provider. Add an override only when voice should bill a different OpenAI project.")
            }
        }
        .formStyle(.grouped)
        .alert("Remove the OpenAI API key?", isPresented: $confirmingKeyRemoval) {
            Button("Remove Key", role: .destructive) {
                model.stopConversations()
                Keychain.delete(Keychain.Account.openAI)
                keyConfigured = false
                keyStatus = voiceOverrideConfigured ? "Primary key removed. The separate voice key remains saved." : "No OpenAI API key saved."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Direct OpenAI reasoning stops until you save another key. A separate voice override remains available.")
        }
        .task {
            if model.agentProvider == "chatgpt", chatGPT.sharingEnabled, chatGPT.models.isEmpty { try? await chatGPT.loadModels() }
        }
    }

    private func savePrimaryKey() {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if Keychain.write(value, account: Keychain.Account.openAI) {
            keyConfigured = true; apiKey = ""; keyStatus = "Key saved in Keychain. Validate it before the first run."
        } else { keyStatus = "Keychain could not save the key." }
    }

    private func validatePrimaryKey() {
        guard let value = Keychain.openAIKey() else { keyConfigured = false; keyStatus = "No OpenAI API key saved."; return }
        validatingKey = true
        Task {
            do {
                let result = try await OpenAIKeyValidator.validate(value)
                keyStatus = "Validated with OpenAI. \(result.modelCount) models are visible to this project."
            } catch { keyStatus = error.localizedDescription }
            validatingKey = false
        }
    }

    private func saveVoiceKey() {
        let value = voiceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if Keychain.write(value, account: Keychain.Account.openAIVoiceOverride) { voiceOverrideConfigured = true; voiceKey = "" }
    }
}
