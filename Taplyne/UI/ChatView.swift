import SwiftUI
import TaplyneServer

/// The built-in agent's conversation for the selected phone.
struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var chat: AgentChat
    @ObservedObject var phone: Phone
    @State private var draft = ""
    @State private var lightbox: LightboxItem?
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(blocks) { block in
                            blockView(block)
                                .id(block.id)
                                .transition(.asymmetric(
                                    insertion: .offset(y: 8).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                        if chat.running {
                            WorkingRow()
                                .id("working")
                                .transition(.opacity)
                        }
                    }
                    .padding(16)
                    .animation(Motion.standard, value: chat.entries.count)
                }
                .overlay { if chat.entries.isEmpty { emptyState.transition(.opacity) } }
                .onChange(of: chat.entries.count) {
                    if let last = blocks.last { withAnimation(Motion.standard) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            composer
        }
        .sheet(item: $lightbox) { item in
            LightboxView(images: screenshots, index: item.index)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.gradient))
                .symbolEffect(.pulse, options: .repeating, isActive: chat.running)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent").font(.headline)
                HStack(spacing: 5) {
                    if chat.running {
                        StatusDot(color: .accentColor, pulsing: true, size: 6)
                    }
                    Text(chat.paused ? "Paused for manual control" : chat.running ? "Working on \(phone.title)" : "Claude Code")
                        .contentTransition(.opacity)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if chat.paused {
                Button("Resume") { model.control(phone, .resume) }
                    .buttonStyle(.borderedProminent)
                    .disabled(chat.running)
            } else if chat.running {
                Button { model.control(phone, .pause) } label: { Image(systemName: "pause.fill") }
                    .buttonStyle(IconButtonStyle(size: 30)).help("Pause the agent")
                .accessibilityLabel("Pause the agent")
            }
            Button {
                withAnimation(Motion.standard) { chat.reset() }
            } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(IconButtonStyle(size: 30))
                .help("New conversation")
                .disabled(chat.running || chat.entries.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .animation(Motion.standard, value: chat.running)
    }

    // MARK: - Thread

    /// Consecutive tool calls and screenshots read as one timeline card.
    private enum Block: Identifiable {
        case single(AgentChat.Entry)
        case timeline([AgentChat.Entry])

        var id: UUID {
            switch self {
            case let .single(entry): entry.id
            case let .timeline(entries): entries[0].id
            }
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var run: [AgentChat.Entry] = []
        for entry in chat.entries {
            if entry.kind == .tool || entry.kind == .image {
                run.append(entry)
            } else {
                if !run.isEmpty { result.append(.timeline(run)); run = [] }
                result.append(.single(entry))
            }
        }
        if !run.isEmpty { result.append(.timeline(run)) }
        return result
    }

    private var screenshots: [NSImage] {
        chat.entries.compactMap { $0.kind == .image ? $0.image : nil }
    }

    @ViewBuilder private func blockView(_ block: Block) -> some View {
        switch block {
        case let .single(entry): row(entry)
        case let .timeline(entries): timeline(entries)
        }
    }

    @ViewBuilder private func row(_ entry: AgentChat.Entry) -> some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(entry.text)
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16,
                                               bottomTrailingRadius: 5, topTrailingRadius: 16, style: .continuous)
                            .fill(Color.accentColor.gradient)
                    )
            }
        case .assistant:
            Text(LocalizedStringKey(entry.text))
                .textSelection(.enabled)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .status:
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .tool, .image:
            timeline([entry])
        }
    }

    private func timeline(_ entries: [AgentChat.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entries) { entry in
                if entry.kind == .image, let image = entry.image {
                    ScreenshotThumbnail(image: image) {
                        if let index = screenshots.firstIndex(where: { $0 === image }) {
                            lightbox = LightboxItem(index: index)
                        }
                    }
                    .padding(.leading, 37)
                    .padding(.vertical, 4)
                } else {
                    toolRow(entry, running: chat.running && entry.id == chat.entries.last?.id)
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func toolRow(_ entry: AgentChat.Entry, running: Bool) -> some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary)
                if running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: Self.symbol(for: entry.text))
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .frame(width: 22, height: 22)
            Text(entry.text)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(running ? .primary : .secondary)
                .fontWeight(running ? .medium : .regular)
                .lineLimit(2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    /// Picks an icon from `AgentChat.describeTool`'s wording.
    static func symbol(for text: String) -> String {
        let lower = text.lowercased()
        if lower.hasPrefix("flick") {
            for direction in ["up", "down", "left", "right"] where lower.hasPrefix("flick \(direction)") {
                return "arrow.\(direction)"
            }
            return "arrow.up.and.down.and.arrow.left.and.right"
        }
        let prefixes: [(String, String)] = [
            ("tap", "hand.tap"), ("double tap", "hand.tap"), ("triple tap", "hand.tap"),
            ("long press", "timer"), ("drag", "hand.draw"), ("hold and drag", "square.grid.2x2"),
            ("type", "keyboard"), ("press", "command"), ("home", "house"),
            ("screenshot", "camera.viewfinder"), ("list phones", "iphone.gen3"), ("list apps", "square.grid.3x3"),
        ]
        return prefixes.last { lower.hasPrefix($0.0) }?.1 ?? "wrench.and.screwdriver"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 52, height: 52)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("What should I do on \(phone.title)?")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The agent sees the screen and taps, types and swipes for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                SuggestionButton(symbol: "checklist", text: "Add eggs to my Groceries list in Reminders", fill: fill)
                SuggestionButton(symbol: "battery.75percent", text: "Open Settings and tell me my battery health", fill: fill)
                SuggestionButton(symbol: "cloud.sun", text: "Check the weather for tomorrow", fill: fill)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func fill(_ text: String) {
        draft = text
        composerFocused = true
    }

    // MARK: - Composer

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty && !chat.running
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Tell the agent what to do on \(phone.title)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 6)
                .focused($composerFocused)
                .onSubmit(send)
            HStack {
                Text(chat.running ? "⌘. to stop" : "Claude Code · ⌘↩ to send")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .contentTransition(.opacity)
                Spacer()
                sendStopButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 8)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(composerFocused ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: composerFocused ? 1 : 0.5)
        }
        .shadow(color: composerFocused ? .accentColor.opacity(0.18) : .black.opacity(0.06), radius: composerFocused ? 6 : 10, y: composerFocused ? 0 : 3)
        .animation(Motion.quick, value: composerFocused)
        .padding(12)
    }

    private var sendStopButton: some View {
        Button {
            if chat.running { chat.stop() } else { send() }
        } label: {
            ZStack {
                Circle().fill(chat.running ? AnyShapeStyle(Color.primary)
                              : canSend ? AnyShapeStyle(Color.accentColor.gradient)
                              : AnyShapeStyle(Color.secondary.opacity(0.3)))
                Image(systemName: chat.running ? "stop.fill" : "arrow.up")
                    .font(.system(size: chat.running ? 10 : 12, weight: .bold))
                    .foregroundStyle(chat.running ? Color(nsColor: .windowBackgroundColor) : .white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(PressableStyle())
        .disabled(!chat.running && !canSend)
        .keyboardShortcut(chat.running ? KeyboardShortcut(".", modifiers: .command) : KeyboardShortcut(.return, modifiers: .command))
        .help(chat.running ? "Stop the agent (⌘.)" : "Send (⌘↩)")
        .animation(Motion.standard, value: chat.running)
        .animation(Motion.standard, value: canSend)
    }

    private func send() {
        let text = draft
        draft = ""
        chat.send(text)
    }
}

/// Three dots that ripple while the agent is thinking or acting.
private struct WorkingRow: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .offset(y: phase ? -3 : 1)
                    .opacity(phase ? 1 : 0.4)
                    .animation(
                        Motion.reduced ? nil : .easeInOut(duration: 0.5).repeatForever().delay(Double(index) * 0.15),
                        value: phase
                    )
            }
            Text("Working").font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
        }
        .padding(.leading, 4)
        .onAppear { phase = true }
    }
}

private struct LightboxItem: Identifiable {
    let index: Int
    var id: Int { index }
}

/// One suggested task in the empty agent panel.
private struct SuggestionButton: View {
    let symbol: String
    let text: String
    let fill: (String) -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            fill(text)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                Text(text)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovering ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.1), lineWidth: hovering ? 1 : 0.5)
            }
            .offset(y: hovering ? -1 : 0)
            .shadow(color: .black.opacity(hovering ? 0.08 : 0), radius: 6, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// A screenshot the agent took, clickable to enlarge.
private struct ScreenshotThumbnail: View {
    let image: NSImage
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(hovering ? 0.22 : 0.12), radius: hovering ? 10 : 5, y: hovering ? 5 : 2)
                .scaleEffect(hovering ? 1.03 : 1, anchor: .topLeading)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Motion.standard, value: hovering)
        .help("Enlarge")
    }
}

/// The agent's screenshots, one at a time, large.
private struct LightboxView: View {
    let images: [NSImage]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                Button {
                    withAnimation(Motion.standard) { index -= 1 }
                } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(IconButtonStyle(size: 36))
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(index <= 0)
                    .help("Previous screenshot")
                if images.indices.contains(index) {
                    Image(nsImage: images[index])
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
                        .id(index)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
                Button {
                    withAnimation(Motion.standard) { index += 1 }
                } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(IconButtonStyle(size: 36))
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(index >= images.count - 1)
                    .help("Next screenshot")
            }
            HStack(spacing: 10) {
                Text("Screenshot \(index + 1) of \(images.count)").fontWeight(.semibold)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .font(.callout)
        }
        .padding(22)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 620, idealHeight: 760)
    }
}
