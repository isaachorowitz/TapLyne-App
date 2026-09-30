import SwiftUI
import TaplyneServer

/// A mark drawn on the live screen where an action landed, in phone pixels.
struct TouchMark: Identifiable {
    enum Kind {
        case tap(count: Int)
        case hold
        case flick(Direction)
        case drag(to: CGPoint, holdFirst: Bool)
    }

    let id = UUID()
    let kind: Kind
    let point: CGPoint
    let byAgent: Bool

    init?(_ event: ActionEvent) {
        byAgent = event.byAgent
        switch event.action {
        case let .tap(x, y): kind = .tap(count: 1); point = CGPoint(x: x, y: y)
        case let .doubleTap(x, y): kind = .tap(count: 2); point = CGPoint(x: x, y: y)
        case let .tripleTap(x, y): kind = .tap(count: 3); point = CGPoint(x: x, y: y)
        case let .tapAndHold(x, y, _): kind = .hold; point = CGPoint(x: x, y: y)
        case let .flick(x, y, direction): kind = .flick(direction); point = CGPoint(x: x, y: y)
        case let .drag(fx, fy, tx, ty, _):
            kind = .drag(to: CGPoint(x: tx, y: ty), holdFirst: false); point = CGPoint(x: fx, y: fy)
        case let .holdAndDrag(fx, fy, tx, ty, _, _):
            kind = .drag(to: CGPoint(x: tx, y: ty), holdFirst: true); point = CGPoint(x: fx, y: fy)
        case .type, .setText, .keypress, .home, .navigate:
            return nil
        }
    }

    /// How long the mark stays before it is removed.
    var lifetime: Double {
        switch kind {
        case .tap: 1.1
        case .hold: 1.7
        case .flick: 1.0
        case let .drag(_, holdFirst): holdFirst ? 2.0 : 1.4
        }
    }
}

/// A drag in progress under the person's mouse, before anything is sent.
struct GesturePreview: Equatable {
    var start: CGPoint
    var current: CGPoint
    var gesture: ManualGesture

    /// The direction a flick would take, matching how the release is interpreted.
    var flickDirection: Direction? {
        let dx = current.x - start.x, dy = current.y - start.y
        guard hypot(dx, dy) > 20 else { return nil }
        return abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
    }
}

/// Draws marks, the drag preview, and the live-finger trail over the phone screen.
struct TouchMarksLayer: View {
    let marks: [TouchMark]
    let preview: GesturePreview?
    let trail: [CGPoint]
    let phoneSize: CGSize?

    var body: some View {
        GeometryReader { geometry in
            if let phoneSize, phoneSize.width > 0 {
                let scale = geometry.size.width / phoneSize.width
                ZStack(alignment: .topLeading) {
                    ForEach(marks) { mark in
                        TouchMarkView(mark: mark, scale: scale)
                    }
                    if let preview {
                        PreviewView(preview: preview, scale: scale)
                    }
                    LiveTrail(points: trail.map { CGPoint(x: $0.x * scale, y: $0.y * scale) })
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: max(12, geometry.size.width * 0.12), style: .continuous))
            }
        }
    }
}

private struct TouchMarkView: View {
    let mark: TouchMark
    let scale: CGFloat
    @State private var started = false
    @State private var fading = false

    private var tint: Color { mark.byAgent ? .accentColor : .white }
    private var point: CGPoint { CGPoint(x: mark.point.x * scale, y: mark.point.y * scale) }

    var body: some View {
        ZStack {
            switch mark.kind {
            case let .tap(count):
                ForEach(0 ..< count, id: \.self) { index in
                    Ripple(tint: tint, delay: Double(index) * 0.16)
                        .position(point)
                }
                dot.position(point)
                if count > 1 {
                    chip(Text(verbatim: "×\(count)")).position(x: point.x + 30, y: point.y - 24)
                }
            case .hold:
                HoldRing(tint: tint, duration: 1.0, haptic: !mark.byAgent).position(point)
                dot.position(point)
            case let .flick(direction):
                FlickStreak(tint: tint, direction: direction).position(point)
                chip(Label(direction.rawValue.capitalized, systemImage: "arrow.\(direction.rawValue)"))
                    .position(x: point.x + 36, y: point.y + 4)
            case let .drag(to, holdFirst):
                let end = CGPoint(x: to.x * scale, y: to.y * scale)
                if holdFirst {
                    HoldRing(tint: tint, duration: 0.5, haptic: false).position(point)
                }
                DragLine(from: point, to: end, tint: tint, delay: holdFirst ? 0.5 : 0)
                dot.position(point)
            }
            if mark.byAgent {
                chip(Label("Agent", systemImage: "sparkle"), filled: true)
                    .position(x: point.x + 34, y: point.y - 26)
            }
        }
        .opacity(fading ? 0 : 1)
        .onAppear {
            withAnimation(Motion.pop) { started = true }
            let fadeAt = max(0.3, mark.lifetime - 0.42)
            withAnimation(Motion.adapt(.easeIn(duration: 0.42)).delay(fadeAt)) { fading = true }
        }
    }

    private var dot: some View {
        Circle()
            .fill(tint.opacity(0.9))
            .frame(width: 22, height: 22)
            .overlay(Circle().stroke(.white.opacity(mark.byAgent ? 0.85 : 0), lineWidth: 2.5))
            .shadow(color: .black.opacity(0.35), radius: 4)
            .scaleEffect(started ? 1 : 0.2)
    }

    private func chip(_ content: some View, filled: Bool = false) -> some View {
        content
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(filled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.black.opacity(0.5))))
            .fixedSize()
            .scaleEffect(started ? 1 : 0.6)
            .opacity(started ? 1 : 0)
    }
}

/// A ring that expands from the touch point and fades.
private struct Ripple: View {
    let tint: Color
    let delay: Double
    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(tint, lineWidth: 2)
            .frame(width: 40, height: 40)
            .scaleEffect(expanded ? 2.4 : 0.35)
            .opacity(expanded ? 0 : 0.9)
            .onAppear {
                withAnimation(Motion.adapt(.easeOut(duration: 0.6)).delay(delay)) { expanded = true }
            }
    }
}

/// A ring that fills over the length of a long press.
private struct HoldRing: View {
    let tint: Color
    let duration: Double
    let haptic: Bool
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 46, height: 46)
        .onAppear {
            withAnimation(.linear(duration: duration)) { progress = 1 }
            if haptic {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                    Haptics.tick()
                }
            }
        }
    }
}

/// A short streak that shoots in the flick's direction.
private struct FlickStreak: View {
    let tint: Color
    let direction: Direction
    @State private var gone = false

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [tint.opacity(0), tint], startPoint: .bottom, endPoint: .top))
            .frame(width: 12, height: 46)
            .rotationEffect(angle)
            .offset(gone ? offset : .zero)
            .opacity(gone ? 0 : 1)
            .onAppear {
                withAnimation(Motion.adapt(.timingCurve(0.2, 0, 0, 1, duration: 0.55))) { gone = true }
            }
    }

    private var angle: Angle {
        switch direction {
        case .up: .zero
        case .right: .degrees(90)
        case .down: .degrees(180)
        case .left: .degrees(-90)
        }
    }

    private var offset: CGSize {
        switch direction {
        case .up: CGSize(width: 0, height: -120)
        case .down: CGSize(width: 0, height: 120)
        case .left: CGSize(width: -120, height: 0)
        case .right: CGSize(width: 120, height: 0)
        }
    }
}

/// The path of a drag, drawn from start to end, with a ring where it lands.
private struct DragLine: View {
    let from: CGPoint
    let to: CGPoint
    let tint: Color
    let delay: Double
    @State private var drawn: CGFloat = 0
    @State private var landed = false

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: from)
                path.addLine(to: to)
            }
            .trim(from: 0, to: drawn)
            .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 6]))
            .shadow(color: .black.opacity(0.3), radius: 2)
            Circle()
                .strokeBorder(tint, lineWidth: 2.5)
                .frame(width: 22, height: 22)
                .scaleEffect(landed ? 1 : 0.2)
                .opacity(landed ? 1 : 0)
                .position(to)
        }
        .onAppear {
            withAnimation(Motion.adapt(.timingCurve(0.4, 0, 0.2, 1, duration: 0.4)).delay(delay)) { drawn = 1 }
            withAnimation(Motion.pop.delay(delay + 0.35)) { landed = true }
        }
    }
}

/// What a drag or flick will do, drawn while the mouse is still down.
private struct PreviewView: View {
    let preview: GesturePreview
    let scale: CGFloat

    var body: some View {
        let start = CGPoint(x: preview.start.x * scale, y: preview.start.y * scale)
        let current = CGPoint(x: preview.current.x * scale, y: preview.current.y * scale)
        ZStack {
            Circle().fill(.white.opacity(0.9)).frame(width: 18, height: 18).position(start)
            if preview.gesture == .flick {
                if let direction = preview.flickDirection {
                    Label(direction.rawValue.capitalized, systemImage: "arrow.\(direction.rawValue)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .fixedSize()
                        .position(x: start.x + 38, y: start.y + 4)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            } else {
                Path { path in
                    path.move(to: start)
                    path.addLine(to: current)
                }
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 6]))
                .shadow(color: .black.opacity(0.35), radius: 2)
                Circle()
                    .strokeBorder(.white, lineWidth: 2.5)
                    .frame(width: 22, height: 22)
                    .position(current)
            }
        }
        .animation(Motion.quick, value: preview.flickDirection)
    }
}

/// A fingertip with a short fading trail for Live mode.
private struct LiveTrail: View {
    let points: [CGPoint]

    var body: some View {
        ZStack {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                let age = CGFloat(points.count - 1 - index)
                let isTip = index == points.count - 1
                Circle()
                    .fill(.white.opacity(isTip ? 0.95 : max(0.08, 0.5 - age * 0.07)))
                    .frame(width: isTip ? 24 : max(6, 18 - age * 2), height: isTip ? 24 : max(6, 18 - age * 2))
                    .shadow(color: .black.opacity(isTip ? 0.35 : 0), radius: 4)
                    .overlay(isTip ? Circle().stroke(.white.opacity(0.25), lineWidth: 6).padding(-6) : nil)
                    .position(point)
            }
        }
    }
}
