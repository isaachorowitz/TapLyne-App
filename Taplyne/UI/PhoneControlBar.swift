import SwiftUI
import TaplyneServer

struct PhoneControlBar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var phone: Phone
    @State private var showingTools = false

    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: phone.controlState.mode == .automatic ? "sparkles" : "hand.raised")
                .font(.callout.weight(.medium))
                .foregroundStyle(phone.controlState.mode == .automatic ? Color.secondary : .orange)
            if let result = phone.lastVerification {
                Label(result.status == .verified ? "Text checked" : result.status == .failed ? "Text mismatch" : "Check text",
                      systemImage: result.status == .verified ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(result.status == .verified ? Color.green : .orange)
                    .help(result.detail)
            }
            Spacer(minLength: 0)
            Button("Tools", systemImage: "text.viewfinder") {
                model.control(phone, .takeover)
                showingTools = true
            }
                .help("Describe the screen, navigate, or fill a field")
            if phone.controlState.mode == .automatic {
                Button("Pause", systemImage: "pause.fill") { model.control(phone, .pause) }
                Button("Take over", systemImage: "hand.raised.fill") { model.control(phone, .takeover) }
            } else {
                Button("Resume", systemImage: "play.fill") { model.control(phone, .resume) }
                    .help("Resume the agent using a fresh screen observation")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showingTools) { PhoneToolsView(phone: phone) }
    }

    private var title: String {
        switch phone.controlState.mode {
        case .automatic: "Automation ready"
        case .paused: "Automation paused"
        case .manual: "Manual control"
        }
    }
}
