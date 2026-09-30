import SwiftUI

@main
struct TaplyneApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Taplyne") {
            ContentView()
                .environmentObject(model)
                .task { start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.chat.stop()
                    model.bluetooth.stop()
                }
                .frame(minWidth: 1240, minHeight: 720)
        }
        .defaultSize(width: 1320, height: 900)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView().environmentObject(model)
        }
    }

    private func start() {
        #if DEBUG
        // TAPLYNE_PREVIEW=setup|ready|empty|calibrating|agent seeds fake phones for UI review
        // and starts nothing: no server, capture, or Bluetooth.
        let env = ProcessInfo.processInfo.environment
        if let scenario = env["TAPLYNE_PREVIEW"] {
            if let appearance = env["TAPLYNE_APPEARANCE"] {
                NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            }
            model.registry.seedPreview(scenario == "agent" ? "ready" : scenario)
            model.selectedPhoneID = model.registry.phones.first?.udid
            if scenario == "agent" { model.chat.seedPreview(running: true) }
            if scenario == "calibrating" { model.calibrationStatus = "Measuring pointer speed" }
            return
        }
        #endif
        model.start()
    }
}
