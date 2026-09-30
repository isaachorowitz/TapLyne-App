import SwiftUI
import TaplyneServer

enum ManualGesture: String, CaseIterable, Identifiable {
    case tap = "Tap"
    case doubleTap = "Double"
    case tripleTap = "Triple"
    case hold = "Hold"
    case flick = "Flick"
    case drag = "Drag"
    case holdAndDrag = "Hold & drag"
    case live = "Live"

    var id: String { rawValue }

    var help: String {
        switch self {
        case .tap: "Click to tap."
        case .doubleTap: "Click to double tap."
        case .tripleTap: "Click to triple tap."
        case .hold: "Click to tap and hold for one second."
        case .flick: "Drag in a direction to flick that way from where you pressed."
        case .drag: "Drag from one point to another."
        case .holdAndDrag: "Drag to long press, then move, like rearranging icons."
        case .live: "Press and move like a finger."
        }
    }
}

extension ManualGesture {
    var symbol: String {
        switch self {
        case .tap, .doubleTap, .tripleTap: "hand.tap"
        case .hold: "timer"
        case .flick: "arrow.up.and.down.and.arrow.left.and.right"
        case .drag: "hand.draw"
        case .holdAndDrag: "square.grid.2x2"
        case .live: "hand.point.up.left"
        }
    }

    /// A small count drawn on the symbol for multi-taps.
    var badge: String? {
        switch self {
        case .doubleTap: "2"
        case .tripleTap: "3"
        default: nil
        }
    }

    var title: String {
        switch self {
        case .doubleTap: "Double tap"
        case .tripleTap: "Triple tap"
        default: rawValue
        }
    }
}

struct PhoneDetailView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var phone: Phone
    @State private var gesture: ManualGesture = .tap
    @State private var dragStart: CGPoint?
    @State private var manualImage: ScreenImage?
    @State private var live: LiveTouch?
    @State private var typeText = ""
    @State private var renaming = false
    @State private var newName = ""
    @AppStorage("showAgent") private var showAgent = true
    @State private var marks: [TouchMark] = []
    @State private var preview: GesturePreview?
    @State private var trail: [CGPoint] = []
    @State private var homePresses = 0
    @State private var confirmRestart = false
    @State private var confirmDisconnect = false
    @State private var onlineToast = false
    @State private var shakes = 0
    @FocusState private var renameFocused: Bool
    @Namespace private var palette

    var body: some View {
        HSplitView {
            stage
            if showAgent {
                ChatView(chat: model.chat, phone: phone)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 560)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: showAgent)
        .navigationTitle(phone.title)
        .navigationSubtitle(phone.readiness == .ready ? "Online" : (phone.plugged ? "Not ready" : "Unplugged"))
        .toolbar { toolbar }
        .sheet(isPresented: $renaming) { renameSheet }
        .alert("Restart \(phone.title)?", isPresented: $confirmRestart) {
            Button("Restart", role: .destructive) { Task { await model.restartPhone(phone) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The iPhone goes offline until it finishes booting. Unlock it afterwards so Taplyne can see the screen again.")
        }
        .alert("Disconnect Bluetooth input?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { model.registry.forgetBluetooth(phone) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Taplyne stops controlling \(phone.title) until you pair it again.")
        }
        .onChange(of: phone.lastAction) { _, event in addMark(event) }
        .onChange(of: phone.readiness) { old, new in
            if new == .ready, old != .ready { announceOnline() }
        }
        .onChange(of: phone.lastError) { _, error in
            if error != nil { withAnimation(Motion.adapt(.linear(duration: 0.36))) { shakes += 1 } }
        }
    }

    private var stage: some View {
        VStack(spacing: 14) {
            PhoneControlBar(phone: phone)
            if let step = calibrationStep {
                CalibrationCard(step: step)
                    .frame(maxWidth: 520)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if phone.readiness != .ready {
                ReadinessBanner(phone: phone) { confirmRestart = true }
                    .frame(maxWidth: 620)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack(alignment: .center, spacing: 20) {
                gesturePalette
                phoneStage
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            hint
            typeBar
                .frame(maxWidth: 520)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(minWidth: 480, idealWidth: 500, maxWidth: .infinity)
        .background(StageBackground())
        .animation(Motion.slow, value: phone.readiness)
        .animation(Motion.slow, value: calibrationStep)
    }

    /// The calibration step running right now, if any.
    private var calibrationStep: Int? {
        model.calibrationStatus.flatMap { CalibrationCard.steps.firstIndex(of: $0) }
    }

    // MARK: - Stage

    private var phoneStage: some View {
        PhoneScreenView(session: phone.stream?.session, phoneSize: phone.screenSize) { event in
            updatePreview(event)
            handle(event)
        }
        .aspectRatio(phone.screenSize.map { $0.width / $0.height } ?? 0.46, contentMode: .fit)
        .overlay {
            TouchMarksLayer(marks: marks, preview: preview, trail: trail, phoneSize: phone.screenSize)
                .allowsHitTesting(false)
        }
        .overlay { screenPlaceholder.allowsHitTesting(false) }
        .padding(7)
        .background { DeviceBezel() }
        .overlay(alignment: .top) { toasts.padding(.top, 18) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Covers the black screen with a reason when there is no picture yet.
    @ViewBuilder private var screenPlaceholder: some View {
        if phone.stream == nil || phone.readiness == .locked || phone.readiness == .waitingForScreen {
            VStack(spacing: 10) {
                Image(systemName: phone.readiness == .ready ? "iphone" : phone.readiness.symbol)
                    .font(.system(size: 30, weight: .light))
                    .symbolEffect(.pulse, options: .repeating, isActive: phone.readiness == .waitingForScreen)
                Text(phone.readiness == .ready ? "Waiting for screen" : phone.readiness.shortLabel)
                    .font(.callout.weight(.medium))
            }
            .foregroundStyle(.white.opacity(0.55))
            .transition(.opacity)
        }
    }

    private var gesturePalette: some View {
        VStack(spacing: 4) {
            ForEach(Array(ManualGesture.allCases.enumerated()), id: \.element) { index, item in
                if item == .live {
                    Divider().frame(width: 22).padding(.vertical, 3)
                }
                PaletteButton(item: item, selected: gesture == item, namespace: palette) {
                    guard gesture != item else { return }
                    Haptics.tick()
                    withAnimation(Theme.spring) { gesture = item }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .help("\(item.title) (⌘\(index + 1)): \(item.help)")
            }
        }
        .padding(6)
        .glassSurface(in: Capsule())
    }

    private var hint: some View {
        let index = (ManualGesture.allCases.firstIndex(of: gesture) ?? 0) + 1
        return HStack(spacing: 6) {
            Image(systemName: gesture.symbol)
            Text(gesture.title).fontWeight(.semibold)
            Text(gesture.help).foregroundStyle(.secondary)
            Text(verbatim: "⌘\(index)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .font(.caption)
        .id(gesture)
        .transition(.opacity.combined(with: .offset(y: 3)))
        .animation(Motion.standard, value: gesture)
    }

    private var toasts: some View {
        VStack(spacing: 8) {
            if onlineToast {
                Toast(symbol: "checkmark.circle.fill", tint: .green, text: "\(phone.title) is online")
                    .transition(toastTransition)
            }
            if let activity = phone.activity {
                Toast(spinner: true, text: activity)
                    .transition(toastTransition)
            } else if let error = phone.lastError {
                Button {
                    withAnimation(Motion.standard) { phone.lastError = nil }
                } label: {
                    Toast(symbol: "exclamationmark.triangle.fill", tint: .red, text: error, closable: true)
                }
                .buttonStyle(.plain)
                .modifier(Shake(animatableData: CGFloat(shakes)))
                .help("Dismiss")
                .transition(toastTransition)
            }
        }
        .padding(.horizontal, 16)
        .animation(Motion.standard, value: phone.activity)
        .animation(Motion.standard, value: phone.lastError)
        .animation(Motion.standard, value: onlineToast)
    }

    private var toastTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(y: -12).combined(with: .opacity).combined(with: .scale(scale: 0.96)),
            removal: .offset(y: -6).combined(with: .opacity)
        )
    }

    private var typeBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            TextField("Type on the iPhone", text: $typeText)
                .textFieldStyle(.plain)
                .onSubmit(sendText)
            Button {
                run(.keypress(key: .enter, modifiers: [], repeatCount: 1))
            } label: { Image(systemName: "return") }
                .buttonStyle(IconButtonStyle(size: 28))
                .help("Press Return on the iPhone")
            Button {
                run(.keypress(key: .backspace, modifiers: [], repeatCount: 1))
            } label: { Image(systemName: "delete.left") }
                .buttonStyle(IconButtonStyle(size: 28))
                .help("Press Delete on the iPhone")
            Button(action: sendText) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(typeText.isEmpty ? AnyShapeStyle(Color.secondary.opacity(0.35)) : AnyShapeStyle(Color.accentColor.gradient)))
                    .scaleEffect(typeText.isEmpty ? 0.86 : 1)
            }
            .buttonStyle(PressableStyle())
            .disabled(typeText.isEmpty)
            .help("Type this text on the iPhone")
            .animation(Motion.pop, value: typeText.isEmpty)
        }
        .padding(5)
        .glassSurface(in: Capsule())
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                homePresses += 1
                run(.home)
            } label: {
                Label("Home", systemImage: "house")
                    .symbolEffect(.bounce, value: homePresses)
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .help("Go to the Home Screen (⇧⌘H)")
            Menu {
                Section("Pointer") {
                    Button("Calibrate Pointer", systemImage: "scope") { Task { await model.calibrate(phone) } }
                    Button("Reset AssistiveTouch", systemImage: "circle.dashed") { Task { await model.resetAssistiveTouch(phone) } }
                }
                Section("Phone") {
                    Button("Refresh Apps", systemImage: "arrow.clockwise") { Task { _ = try? await model.service.apps(phoneID: phone.udid, refresh: true) } }
                    Button("Rename…", systemImage: "pencil") { newName = phone.title; renaming = true }
                }
                Divider()
                Button("Disconnect Bluetooth Input…", systemImage: "wave.3.right.circle") { confirmDisconnect = true }
                Button("Restart iPhone…", systemImage: "restart", role: .destructive) { confirmRestart = true }
            } label: { Label("More", systemImage: "ellipsis") }
                .help("More actions")
        }
        ToolbarItem {
            Button {
                withAnimation(Theme.spring) { showAgent.toggle() }
            } label: { Label("Agent", systemImage: "sidebar.right") }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .help(showAgent ? "Hide the agent (⌥⌘A)" : "Show the agent (⌥⌘A)")
        }
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rename iPhone").font(.headline)
                    Text("Agents see this name.").font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .frame(width: 320)
                    .focused($renameFocused)
                    .onSubmit(saveName)
            }
            HStack {
                Spacer()
                Button("Cancel") { renaming = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: saveName)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(22)
        .onAppear { renameFocused = true }
    }

    private func saveName() {
        Task { _ = try? await model.service.rename(phoneID: phone.udid, displayName: newName) }
        renaming = false
    }

    // MARK: - Feedback

    private func addMark(_ event: ActionEvent?) {
        guard let event, let mark = TouchMark(event) else { return }
        marks.append(mark)
        Task {
            try? await Task.sleep(nanoseconds: UInt64(mark.lifetime * 1_000_000_000))
            marks.removeAll { $0.id == mark.id }
        }
    }

    private func announceOnline() {
        Haptics.success()
        onlineToast = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            onlineToast = false
        }
    }

    /// Draws what a drag, flick, or live press will do while the mouse is down.
    private func updatePreview(_ event: PhoneScreenView.Event) {
        switch gesture {
        case .drag, .holdAndDrag, .flick:
            switch event {
            case let .down(p): preview = GesturePreview(start: p, current: p, gesture: gesture)
            case let .moved(p): preview?.current = p
            case .up: withAnimation(Motion.quick) { preview = nil }
            }
        case .live:
            switch event {
            case let .down(p): trail = [p]
            case let .moved(p):
                trail.append(p)
                if trail.count > 8 { trail.removeFirst(trail.count - 8) }
            case .up: withAnimation(Motion.standard) { trail = [] }
            }
        default:
            break
        }
    }

    // MARK: - Input

    private func sendText() {
        let text = typeText
        guard !text.isEmpty else { return }
        typeText = ""
        run(.type(text: text))
    }

    private func run(_ action: PhoneAction, image: ScreenImage? = nil) {
        let registry = model.registry
        Task {
            do {
                try await AppPhoneService.perform(action, on: phone, registry: registry, manualImage: image)
            } catch let error as PhoneServiceError {
                phone.lastError = error.message
            } catch {
                phone.lastError = error.localizedDescription
            }
        }
    }

    private func handle(_ event: PhoneScreenView.Event) {
        if gesture == .live {
            handleLive(event)
            return
        }
        switch event {
        case let .down(p):
            if phone.controlState.mode == .automatic { phone.control(.takeover) }
            manualImage = phone.stream?.latestImage()
            dragStart = p
        case .moved:
            break
        case let .up(end):
            guard let start = dragStart else { return }
            dragStart = nil
            let image = manualImage
            manualImage = nil
            let s = (x: Int(start.x), y: Int(start.y)), e = (x: Int(end.x), y: Int(end.y))
            switch gesture {
            case .tap: run(.tap(x: s.x, y: s.y), image: image)
            case .doubleTap: run(.doubleTap(x: s.x, y: s.y), image: image)
            case .tripleTap: run(.tripleTap(x: s.x, y: s.y), image: image)
            case .hold: run(.tapAndHold(x: s.x, y: s.y, durationMs: 1000), image: image)
            case .flick:
                let dx = end.x - start.x, dy = end.y - start.y
                guard hypot(dx, dy) > 20 else { return }
                let direction: Direction = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
                run(.flick(x: s.x, y: s.y, direction: direction), image: image)
            case .drag: run(.drag(fromX: s.x, fromY: s.y, toX: e.x, toY: e.y, speed: .medium), image: image)
            case .holdAndDrag: run(.holdAndDrag(fromX: s.x, fromY: s.y, toX: e.x, toY: e.y, holdDurationMs: 500, speed: .medium), image: image)
            case .live: break
            }
        }
    }

    private func handleLive(_ event: PhoneScreenView.Event) {
        switch event {
        case let .down(p):
            guard phone.readiness == .ready, let driver = model.registry.driver(for: phone) else {
                phone.lastError = phone.readiness.reason
                return
            }
            let touch = LiveTouch(start: p)
            live = touch
            Task { try? await phone.enqueue { try await touch.run(driver) } }
        case let .moved(p):
            live?.target = p
        case let .up(p):
            live?.target = p
            live?.ended = true
            live = nil
        }
    }
}

/// One finger-like press in Live mode. Mouse moves arrive faster than Bluetooth
/// can send them, so only the newest position is chased.
@MainActor
final class LiveTouch {
    var target: CGPoint { didSet { lastMotionAt = Date() } }
    private var lastMotionAt = Date()
    var ended = false
    private let start: CGPoint

    init(start: CGPoint) {
        self.start = start
        target = start
    }

    func run(_ driver: PhoneDriver) async throws {
        var sent = start
        let deadline = Date().addingTimeInterval(30)
        do {
            try await driver.touchDown(Int(start.x), Int(start.y))
            while true {
                try Task.checkCancellation()
                guard Date() < deadline, Date().timeIntervalSince(lastMotionAt) < 10 else {
                    throw PhoneServiceError.failed("Live input ended after its idle or hold limit.")
                }
                if target != sent {
                    sent = target
                    try await driver.touchMove(Int(sent.x), Int(sent.y))
                } else if ended {
                    break
                } else {
                    try await Task.sleep(nanoseconds: 8_000_000)
                }
            }
            try await driver.touchUp()
        } catch {
            await driver.releaseInput()
            throw error
        }
    }
}

/// One tool in the gesture palette; the accent selection slides between them.
private struct PaletteButton: View {
    let item: ManualGesture
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if selected {
                    Circle()
                        .fill(Color.accentColor.gradient)
                        .shadow(color: .accentColor.opacity(0.4), radius: 5, y: 2)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if hovering {
                    Circle().fill(.primary.opacity(0.09))
                }
                Image(systemName: item.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .overlay(alignment: .bottomTrailing) {
                        if let badge = item.badge {
                            Text(badge)
                                .font(.system(size: 8, weight: .heavy, design: .rounded))
                                .offset(x: 5, y: 4)
                        }
                    }
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Scales down while pressed and springs back on release.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

/// A short horizontal shake for errors.
struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard !Motion.reduced else { return ProjectionTransform(.identity) }
        return ProjectionTransform(CGAffineTransform(translationX: 6 * sin(animatableData * .pi * 3), y: 0))
    }
}

/// A glass capsule that floats over the phone screen.
private struct Toast: View {
    var symbol: String?
    var tint: Color = .primary
    var spinner = false
    let text: String
    var closable = false

    var body: some View {
        HStack(spacing: 8) {
            if spinner {
                ProgressView().controlSize(.mini)
            } else if let symbol {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            Text(text).font(.caption.weight(.semibold)).lineLimit(3)
            if closable {
                Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 7)
        .contentShape(Capsule())
        .glassSurface(in: Capsule(), tint: symbol == nil ? nil : tint.opacity(0.14), interactive: closable)
    }
}

/// The dark frame and soft shadow that make the live screen read as a device.
private struct DeviceBezel: View {
    var body: some View {
        GeometryReader { geometry in
            let radius = max(18, (geometry.size.width - 14) * 0.12 + 7)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape
                .fill(Color(white: 0.05))
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [Color(white: 0.58), Color(white: 0.24), Color(white: 0.42)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                )
                .shadow(color: .black.opacity(0.28), radius: 26, y: 14)
                .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
        }
    }
}

/// Shows the pointer calibration moving through its measured steps.
struct CalibrationCard: View {
    /// The progress messages `PointerCalibrator` reports, in order.
    static let steps = ["Going to the Home Screen", "Measuring pointer speed", "Checking accuracy"]
    let step: Int
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Calibrating pointer").font(.callout.weight(.semibold))
                Spacer()
                Text("Keep hands off the iPhone").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, title in
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule()
                            .fill(index < step ? AnyShapeStyle(Color.green.gradient)
                                  : index == step ? AnyShapeStyle(Color.accentColor.gradient)
                                  : AnyShapeStyle(.quaternary))
                            .opacity(index == step && pulse ? 0.55 : 1)
                            .frame(height: 4)
                        Text(title)
                            .font(.caption2.weight(index == step ? .semibold : .regular))
                            .foregroundStyle(index > step ? .secondary : .primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .animation(Motion.standard, value: step)
        }
        .padding(16)
        .glassSurface(in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .onAppear {
            guard !Motion.reduced else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true }
        }
    }
}

/// Walks the user through the one thing standing between them and a working phone,
/// with the rest of the setup shown as a checklist.
struct ReadinessBanner: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var phone: Phone
    var onRestart: () -> Void

    private static let steps: [(Phone.Readiness, String)] = [
        (.needsCamera, "Camera"),
        (.locked, "Unlock"),
        (.waitingForScreen, "Screen"),
        (.needsBluetooth, "Bluetooth"),
        (.needsCalibration, "Pointer"),
    ]

    private var current: Int {
        Self.steps.firstIndex { $0.0 == phone.readiness } ?? Self.steps.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if phone.readiness != .unplugged {
                stepper
                Divider()
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: phone.readiness.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(phone.readiness == .unplugged ? Color.gray.gradient : Color.orange.gradient))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 10) {
                    Text(phone.readiness.reason ?? "")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    detail
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .glassSurface(in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .onChange(of: current) { old, new in
            if new > old { Haptics.success() }
        }
    }

    private var stepper: some View {
        ViewThatFits(in: .horizontal) {
            stepperRow(labels: true)
            stepperRow(labels: false)
        }
    }

    private func stepperRow(labels: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(Color.green.opacity(0.75))
                            .scaleEffect(x: index <= current ? 1 : 0.001, anchor: .leading)
                    }
                    .frame(height: 2)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6)
                }
                stepBadge(step.1, state: index < current ? .done : (index == current ? .current : .pending), label: labels || index == current)
            }
        }
        .animation(Motion.adapt(.timingCurve(0.2, 0, 0, 1, duration: 0.42)), value: current)
    }

    private enum StepState { case done, current, pending }

    private func stepBadge(_ title: String, state: StepState, label: Bool) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(state == .done ? AnyShapeStyle(Color.green.gradient)
                          : state == .current ? AnyShapeStyle(Color.orange.gradient)
                          : AnyShapeStyle(.quaternary))
                    .frame(width: 18, height: 18)
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .transition(.scale(scale: 0.2).combined(with: .opacity).animation(Motion.pop.delay(0.12)))
                } else if state == .current {
                    Circle().fill(.white).frame(width: 6, height: 6).transition(.scale)
                }
            }
            .background {
                if state == .current {
                    Circle().fill(Color.orange.opacity(0.2)).frame(width: 26, height: 26)
                }
            }
            if label {
                Text(title)
                    .font(.caption.weight(state == .current ? .semibold : .regular))
                    .foregroundStyle(state == .pending ? .secondary : .primary)
                    .fixedSize()
            }
        }
        .help(title)
    }

    @ViewBuilder private var detail: some View {
        switch phone.readiness {
        case .needsCamera:
            Button("Allow Camera") { Task { _ = await model.capture.requestAccess() } }
                .buttonStyle(.borderedProminent)
        case .waitingForScreen:
            HStack {
                Button("Restart iPhone…", action: onRestart)
                Text("if the screen never appears.").font(.caption).foregroundStyle(.secondary)
            }
        case .needsBluetooth:
            BluetoothStep(phone: phone, bluetooth: model.bluetooth)
        case .needsCalibration:
            HStack {
                Button("Calibrate Pointer") { Task { await model.calibrate(phone) } }
                    .buttonStyle(.borderedProminent)
                if let status = model.calibrationStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        default:
            EmptyView()
        }
    }
}

private struct BluetoothStep: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var phone: Phone
    @ObservedObject var bluetooth: ClassicHIDTransport

    @ViewBuilder private var buttons: some View {
        Button {
            Task { await model.connectBluetooth(phone) }
        } label: {
            ZStack {
                // Holds the button's width while the label changes.
                Text("Prepare Bluetooth Pairing").hidden()
                HStack(spacing: 6) {
                    if bluetooth.busy { ProgressView().controlSize(.mini) }
                    Text(bluetooth.busy ? "Preparing…" : "Prepare Bluetooth Pairing")
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(bluetooth.busy)
        Button("Turn On AssistiveTouch") { Task { await model.enableAssistiveTouch(phone) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading) { buttons }
            }
            if let status = bluetooth.status {
                Label(status, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
            Text("On the iPhone: Settings > Bluetooth, then select “\(Host.current().localizedName ?? "this Mac")”. Keep this window open and approve the matching code on both devices.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(Motion.standard, value: bluetooth.status)
        .animation(Motion.standard, value: bluetooth.busy)
    }
}
