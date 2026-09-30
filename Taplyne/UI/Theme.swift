import AppKit
import SwiftUI

/// Shared spacing, shapes, and surfaces so every screen reads as one app.
enum Theme {
    static let spacing: CGFloat = 12
    static let cornerSmall: CGFloat = 8
    static let corner: CGFloat = 12
    static let cornerLarge: CGFloat = 18
    /// The signature spring: selection, toasts, panels. Settles without visible bounce.
    static var spring: Animation { Motion.adapt(.spring(response: 0.32, dampingFraction: 0.82)) }
}

/// Durations and curves from the motion system. With Reduce Motion on, every
/// movement becomes a short crossfade.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func adapt(_ animation: Animation) -> Animation {
        reduced ? .easeInOut(duration: 0.16) : animation
    }

    /// Hover and press feedback.
    static var quick: Animation { adapt(.easeOut(duration: 0.12)) }
    /// State changes: icons, colors, rows.
    static var standard: Animation { adapt(.spring(response: 0.3, dampingFraction: 0.85)) }
    /// Context shifts: sheets, the setup card, marks fading out.
    static var slow: Animation { adapt(.spring(response: 0.45, dampingFraction: 0.9)) }
    /// A small overshoot for moments of success.
    static var pop: Animation { adapt(.spring(response: 0.32, dampingFraction: 0.58)) }
}

/// Trackpad haptics, used only where a physical click would exist.
enum Haptics {
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func success() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}

// MARK: - Readiness presentation

extension Phone.Readiness {
    var tint: Color {
        switch self {
        case .ready: .green
        case .unplugged: .secondary
        default: .orange
        }
    }

    var shortLabel: String {
        switch self {
        case .ready: "Online"
        case .unplugged: "Unplugged"
        case .needsCamera: "Needs Camera access"
        case .locked: "Locked"
        case .waitingForScreen: "Waiting for screen"
        case .needsBluetooth: "Needs Bluetooth"
        case .needsCalibration: "Needs calibration"
        }
    }

    var symbol: String {
        switch self {
        case .unplugged: "cable.connector.slash"
        case .needsCamera: "video"
        case .locked: "lock"
        case .waitingForScreen: "iphone"
        case .needsBluetooth: "dot.radiowaves.left.and.right"
        case .needsCalibration: "scope"
        case .ready: "checkmark"
        }
    }
}

// MARK: - Surfaces

extension View {
    /// Liquid Glass on macOS 26 and later, a hairlined material before that.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        }
    }

    /// A quiet raised card for grouped content.
    func cardSurface(cornerRadius: CGFloat = Theme.corner) -> some View {
        background(.background.secondary, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            )
    }
}

/// Lets neighbouring glass shapes blend into each other on macOS 26 and later.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Controls

/// A borderless round icon button with hover and press feedback.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, selected: selected)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let selected: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: size, height: size)
                .background {
                    Circle().fill(fill)
                }
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .opacity(enabled ? 1 : 0.35)
                .animation(Theme.spring, value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(Theme.spring, value: selected)
                .onHover { hovering = $0 }
        }

        private var fill: AnyShapeStyle {
            if selected { return AnyShapeStyle(Color.accentColor.gradient) }
            if hovering && enabled { return AnyShapeStyle(.primary.opacity(0.1)) }
            return AnyShapeStyle(.clear)
        }
    }
}

/// A status light that breathes while `pulsing` is on.
struct StatusDot: View {
    var color: Color
    var pulsing = false
    var size: CGFloat = 8
    /// Errors draw a rounded square so color is never the only signal.
    var square = false
    @State private var animate = false

    var body: some View {
        RoundedRectangle(cornerRadius: square ? size * 0.3 : size / 2, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .background {
                if pulsing {
                    Circle()
                        .fill(color.opacity(0.35))
                        .scaleEffect(animate ? 2.4 : 1)
                        .opacity(animate ? 0 : 1)
                }
            }
            .shadow(color: color.opacity(pulsing ? 0.6 : 0), radius: 3)
            .onAppear { startPulse() }
            .onChange(of: pulsing) { startPulse() }
    }

    private func startPulse() {
        guard pulsing, !Motion.reduced else { animate = false; return }
        animate = false
        withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { animate = true }
    }
}

/// A button whose label flips to a checkmark for a moment after copying.
struct CopyButton: View {
    let text: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(Theme.spring) { copied = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                withAnimation(Theme.spring) { copied = false }
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .help("Copy to the clipboard")
    }
}
