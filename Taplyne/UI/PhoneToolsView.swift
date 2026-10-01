import SwiftUI
import TaplyneServer

/// Local tools for the person controlling the phone. Opening this panel takes over from agents.
struct PhoneToolsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var phone: Phone
    @State private var screen: ScreenDescription?
    @State private var busy = false
    @State private var status = ""
    @State private var replacement = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Phone tools").font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Manual control is active. Resume automation when you finish.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                ForEach(NavigationCommand.allCases, id: \.self) { command in
                    Button(navigationTitle(command)) { navigate(command) }
                }
            }
            .controlSize(.small)
            .disabled(busy || phone.readiness != .ready)
            Divider()
            HStack {
                Text("Visible text").font(.headline)
                Spacer()
                Button("Describe screen", systemImage: "text.viewfinder", action: describe)
                    .disabled(busy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let screen {
                        ForEach(screen.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        ForEach(screen.elements) { element in
                            HStack {
                                Text(element.text).textSelection(.enabled)
                                Spacer()
                                Button("Tap") { tap(element) }.disabled(busy || phone.readiness != .ready)
                            }
                        }
                        if screen.elements.isEmpty { Text("No readable text found. Use the live screen to aim.").foregroundStyle(.secondary) }
                    } else { Text("Describe the screen to see labels you can tap.").foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 140, maxHeight: 280)
            Divider()
            Text("Replace focused field").font(.headline)
            Text("Tap the field first. English, Hebrew and emoji use Universal Clipboard. Handoff and the same Apple Account are required.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $replacement).frame(height: 65).border(.separator)
            Button("Replace and check") { run(.setText(text: replacement)) }
                .disabled(busy || phone.readiness != .ready || replacement.count > 1000)
            if busy { ProgressView().controlSize(.small) }
            if !status.isEmpty { Text(status).font(.callout).textSelection(.enabled) }
        }
        .padding(22)
        .frame(width: 680)
    }

    private func describe() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let image = try await model.service.screenshot(phoneID: phone.udid)
                guard Date().timeIntervalSince(image.capturedAt) <= 1 else { throw PhoneServiceError.failed("The screen is stale. Reconnect capture.") }
                screen = try await ScreenRecognition.describe(image)
                status = "Visible labels are recognized locally. Inspect the live screen before tapping."
            } catch { status = error.localizedDescription }
        }
    }

    private func tap(_ element: ScreenElement) {
        guard let screen, let image = phone.currentImage, screen.width == image.width,
              screen.height == image.height, Date().timeIntervalSince(screen.capturedAt) < 5 else {
            status = "Describe the screen again before tapping."; return
        }
        // Resolve the label again just before queuing manual input; reject changed or duplicate labels.
        busy = true
        Task {
            defer { busy = false }
            do {
                let current = try await ScreenRecognition.describe(image)
                let candidates = current.matches(element.text)
                guard candidates.count == 1, let match = candidates.first,
                      hypot(match.bounds.x - element.bounds.x, match.bounds.y - element.bounds.y) < 12 else {
                    throw PhoneServiceError.failed("The label moved or is ambiguous. Describe the screen again.")
                }
                _ = try await AppPhoneService.perform(.tap(x: Int(match.bounds.cgRect.midX), y: Int(match.bounds.cgRect.midY)),
                                                       on: phone, registry: model.registry, manualImage: image)
                self.screen = nil
                status = "Tap sent. Check the live screen for the result."
            } catch { status = (error as? PhoneServiceError)?.message ?? error.localizedDescription }
        }
    }

    private func navigate(_ command: NavigationCommand) { run(.navigate(command)) }

    private func run(_ action: PhoneAction) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await AppPhoneService.perform(action, on: phone, registry: model.registry)
                screen = nil
                status = result.textVerification?.detail ?? "Input sent. Check the live screen for the result."
            } catch { status = (error as? PhoneServiceError)?.message ?? error.localizedDescription }
        }
    }

    private func navigationTitle(_ command: NavigationCommand) -> String {
        switch command {
        case .home: "Home"
        case .back: "Back"
        case .appSwitcher: "Apps"
        case .dismissKeyboard: "Hide keyboard"
        case .notifications: "Notifications"
        case .controlCenter: "Control Center"
        }
    }
}
