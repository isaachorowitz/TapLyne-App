import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        RootView(registry: model.registry)
        #if DEBUG
            .task {
                // UI review: TAPLYNE_SETTINGS opens the Settings window at launch.
                if ProcessInfo.processInfo.environment["TAPLYNE_SETTINGS"] != nil { openSettings() }
            }
        #endif
    }
}

private struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var registry: PhoneRegistry

    var body: some View {
        NavigationSplitView {
            PhoneList()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            if let phone = model.selectedPhone {
                PhoneDetailView(phone: phone).id(phone.udid)
            } else {
                EmptyStage()
            }
        }
    }
}

/// Shown before any iPhone has ever been plugged in.
private struct EmptyStage: View {
    @State private var ring = false

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                    .scaleEffect(ring ? 1.5 : 0.8)
                    .opacity(ring ? 0 : 0.6)
                Circle()
                    .fill(.quaternary.opacity(0.6))
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 50, weight: .thin))
                    .foregroundStyle(Color.accentColor.gradient)
                    .symbolEffect(.breathe, options: .repeating)
            }
            .frame(width: 124, height: 124)
            VStack(spacing: 6) {
                Text("Plug in an iPhone")
                    .font(.title2.weight(.bold))
                Text("Connect it to this Mac with a USB data cable and unlock it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                step(1, "USB data cable")
                step(2, "Unlock, tap Trust")
                step(3, "Auto-Lock: Never")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StageBackground())
        .onAppear {
            guard !Motion.reduced else { return }
            withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) { ring = true }
        }
    }

    private func step(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(number)")
                .font(.caption2.weight(.bold))
                .frame(width: 18, height: 18)
                .background(.quaternary, in: Circle())
            Text(title).font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .cardSurface(cornerRadius: 10)
    }
}

struct PhoneList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        RegistryList(registry: model.registry, selection: $model.selectedPhoneID)
            .safeAreaInset(edge: .bottom) { ServerStatusCard().padding(10) }
    }
}

/// The local server's state, pinned to the bottom of the sidebar.
private struct ServerStatusCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false

    var body: some View {
        SettingsLink {
            HStack(spacing: 10) {
                StatusDot(color: model.serverPort != nil ? .green : .red, pulsing: model.serverPort != nil, square: model.serverPort == nil)
                VStack(alignment: .leading, spacing: 1) {
                    if let port = model.serverPort {
                        Text("Server running").font(.callout.weight(.medium))
                        Text(verbatim: "127.0.0.1:\(port)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Server stopped").font(.callout.weight(.medium))
                        Text(model.serverError ?? "Starting…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .offset(x: hovering ? 2 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassSurface(in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous), interactive: true)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help("Open Settings to connect AI agents (⌘,)")
    }
}

private struct RegistryList: View {
    @ObservedObject var registry: PhoneRegistry
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            Section("iPhones") {
                ForEach(registry.phones) { phone in
                    PhoneRow(phone: phone).tag(phone.udid)
                }
                if registry.phones.isEmpty {
                    Text("None yet").font(.callout).foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct PhoneRow: View {
    @ObservedObject var phone: Phone

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(phone.plugged ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 30, height: 30)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                StatusDot(color: phone.readiness.tint, pulsing: phone.readiness == .ready, size: 9)
                    .overlay(Circle().stroke(.background, lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(phone.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .animation(Theme.spring, value: phone.readiness)
    }

    private var subtitle: String {
        phone.readiness == .ready ? (phone.activity ?? "Online") : phone.readiness.shortLabel
    }
}

/// A soft backdrop that lifts the phone off the window.
struct StageBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Color.primary.opacity(0.015)
        }
        .ignoresSafeArea()
    }
}
