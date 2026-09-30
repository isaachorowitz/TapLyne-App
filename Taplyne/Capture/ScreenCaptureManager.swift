import AVFoundation
import CoreImage
import CoreMediaIO
import os
import TaplyneServer

/// Finds iPhones plugged in over USB and streams their screens.
///
/// macOS exposes a cabled iPhone's screen as a capture device (the path QuickTime
/// uses for iPhone screen recording) once `kCMIOHardwarePropertyAllowScreenCaptureDevices`
/// is set. That is why Taplyne needs the Camera permission.
@MainActor
final class ScreenCaptureManager: NSObject, ObservableObject {
    struct Device: Identifiable, Equatable {
        let id: String          // AVCaptureDevice.uniqueID
        let name: String
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    private var streams: [String: ScreenStream] = [:]
    private let log = Logger(subsystem: "agency.ziplyne.taplyne", category: "capture")
    private var observers: [NSObjectProtocol] = []

    func start() {
        Self.allowScreenCaptureDevices()
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func requestAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        if granted { refresh() }
        return granted
    }

    func refresh() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        )
        let found = session.devices
            .filter { $0.modelID.hasPrefix("iOS") || $0.manufacturer == "Apple Inc." }
            .map { Device(id: $0.uniqueID, name: $0.localizedName) }
        if found != devices {
            log.info("capture devices: \(found.map { "\($0.name) [\($0.id)]" }.joined(separator: ", "), privacy: .public)")
            devices = found
        }
        for id in streams.keys where !found.contains(where: { $0.id == id }) {
            streams[id]?.stop()
            streams[id] = nil
        }
    }

    /// The running stream for a capture device, starting it if needed.
    func stream(for deviceID: String) -> ScreenStream? {
        if let existing = streams[deviceID] { return existing }
        guard authorization == .authorized,
              let device = AVCaptureDevice(uniqueID: deviceID) else { return nil }
        do {
            let stream = try ScreenStream(device: device)
            streams[deviceID] = stream
            stream.start()
            return stream
        } catch {
            log.error("could not open \(device.localizedName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Replaces a stream that went silent, which happens when the iPhone re-enumerates
    /// on USB right after capture starts.
    func restartStream(for deviceID: String) -> ScreenStream? {
        stopStream(for: deviceID)
        return stream(for: deviceID)
    }

    func stopStream(for deviceID: String) {
        streams[deviceID]?.stop()
        streams[deviceID] = nil
    }

    /// Matches a capture device to a UDID. The capture device's unique ID carries
    /// the UDID without its hyphen on the iPhones we have seen; fall back to the name.
    func deviceID(forUDID udid: String, name: String) -> String? {
        let key = udid.replacingOccurrences(of: "-", with: "").uppercased()
        if let match = devices.first(where: { $0.id.replacingOccurrences(of: "-", with: "").uppercased().contains(key) }) {
            return match.id
        }
        return devices.first(where: { $0.name == name })?.id
    }

    static func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &allow
        )
    }
}

/// One phone's live screen. Keeps the newest frame and fans frames out to listeners.
final class ScreenStream: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "taplyne.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var latestAt: Date?
    private var listeners: [UUID: AsyncStream<ScreenImage>.Continuation] = [:]
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private(set) var frameCount = 0

    init(device: AVCaptureDevice) throws {
        super.init()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
        session.addOutput(output)
        session.commitConfiguration()
    }

    let startedAt = Date()

    func start() {
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        queue.async { [session] in session.stopRunning() }
        lock.withLock {
            listeners.values.forEach { $0.finish() }
            listeners.removeAll()
        }
    }

    var isRunning: Bool { session.isRunning }

    var lastFrameAt: Date? { lock.withLock { latestAt } }

    var frameSize: (width: Int, height: Int)? {
        lock.withLock {
            latest.map { (CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0)) }
        }
    }

    func latestImage() -> ScreenImage? {
        let (buffer, at) = lock.withLock { (latest, latestAt) }
        guard let buffer, let at else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return ScreenImage(image: cg, capturedAt: at)
    }

    /// Waits for a frame newer than `after`, up to `timeout`.
    func nextImage(after: Date, timeout: TimeInterval) async -> ScreenImage? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            if let at = lastFrameAt, at > after, let image = latestImage() { return image }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return nil
    }

    func frames(maxFPS: Double = 10) -> AsyncStream<ScreenImage> {
        let id = UUID()
        let interval = 1.0 / maxFPS
        return AsyncStream { continuation in
            let task = Task.detached { [weak self] in
                var last = Date.distantPast
                while !Task.isCancelled, let self {
                    if let at = self.lastFrameAt, at > last, let image = self.latestImage() {
                        last = at
                        continuation.yield(image)
                    }
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                continuation.finish()
            }
            lock.withLock { listeners[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.lock.withLock { _ = self?.listeners.removeValue(forKey: id) }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.withLock {
            latest = buffer
            latestAt = Date()
            frameCount += 1
        }
    }

    enum CaptureError: LocalizedError {
        case cannotAddInput, cannotAddOutput
        var errorDescription: String? {
            switch self {
            case .cannotAddInput: "The iPhone's screen could not be opened."
            case .cannotAddOutput: "The iPhone's screen could not be read."
            }
        }
    }
}
