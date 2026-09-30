import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            ConnectTab().tabItem { Label("Connect AI", systemImage: "point.3.connected.trianglepath.dotted") }
            ServerTab().tabItem { Label("Server", systemImage: "server.rack") }
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

    var body: some View {
        Form {
            Section {
                TextField("Model", text: $model.agentModel, prompt: Text("Claude Code's default"))
                Text("Any model name Claude Code accepts, such as opus or sonnet. The agent runs through Claude Code with your existing login and can only use Taplyne's phone tools.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Claude Code") {
                    if let path = AgentChat.claudeExecutable?.path {
                        Label {
                            Text(path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    } else {
                        Label("Not found", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Label("Built-in agent", systemImage: "sparkles")
            }
        }
        .formStyle(.grouped)
    }
}
