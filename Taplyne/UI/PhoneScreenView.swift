import AVFoundation
import SwiftUI

/// Shows a phone's live screen and reports mouse input in phone pixels.
struct PhoneScreenView: NSViewRepresentable {
    enum Event {
        case down(CGPoint)
        case moved(CGPoint)
        case up(CGPoint)
    }

    let session: AVCaptureSession?
    var remoteImage: CGImage? = nil
    let phoneSize: CGSize?
    let onEvent: (Event) -> Void

    func makeNSView(context: Context) -> ScreenNSView {
        let view = ScreenNSView()
        view.onEvent = onEvent
        return view
    }

    func updateNSView(_ view: ScreenNSView, context: Context) {
        view.onEvent = onEvent
        view.phoneSize = phoneSize
        view.attach(session)
        view.showRemote(remoteImage)
    }
}

final class ScreenNSView: NSView {
    var onEvent: ((PhoneScreenView.Event) -> Void)?
    var phoneSize: CGSize?
    private var pressedOnVideo = false
    private var preview: AVCaptureVideoPreviewLayer?
    private let remoteLayer = CALayer()
    private weak var attached: AVCaptureSession?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        remoteLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(remoteLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func attach(_ session: AVCaptureSession?) {
        guard session !== attached else { return }
        preview?.removeFromSuperlayer()
        preview = nil
        attached = session
        guard let session else { return }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        preview = layer
    }

    func showRemote(_ image: CGImage?) { remoteLayer.contents = image; remoteLayer.isHidden = image == nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Match the rounded corners of a modern iPhone display.
        layer?.cornerRadius = max(12, bounds.width * 0.12)
        preview?.frame = bounds
        remoteLayer.frame = bounds
        CATransaction.commit()
    }

    /// The rectangle the video occupies inside the view (aspect fit).
    private var videoRect: CGRect? {
        guard let size = phoneSize, size.width > 0, size.height > 0 else { return nil }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func phonePoint(_ event: NSEvent, clamping: Bool = false) -> CGPoint? {
        guard let rect = videoRect, let size = phoneSize else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        guard clamping || rect.contains(p) else { return nil }
        let x = (p.x - rect.minX) / rect.width * size.width
        let y = (p.y - rect.minY) / rect.height * size.height
        return CGPoint(x: max(0, min(size.width - 1, x)), y: max(0, min(size.height - 1, y)))
    }

    override func mouseDown(with event: NSEvent) {
        if let p = phonePoint(event) { pressedOnVideo = true; onEvent?(.down(p)) }
    }

    override func mouseDragged(with event: NSEvent) {
        if pressedOnVideo, let p = phonePoint(event, clamping: true) { onEvent?(.moved(p)) }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressedOnVideo else { return }
        pressedOnVideo = false
        onEvent?(.up(phonePoint(event, clamping: true) ?? .zero))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}
