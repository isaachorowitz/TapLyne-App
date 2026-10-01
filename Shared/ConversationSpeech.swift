import Foundation
import AVFoundation
import Speech
import Combine

/// Native speech with continuous recognition, acoustic echo cancellation and transcript echo filtering.
@MainActor
final class ConversationSpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var listening = false
    @Published private(set) var transcript = ""
    @Published private(set) var speaking = false
    @Published var error: String?
    @Published var localeIdentifier = "en-US"

    var onUtterance: (String) -> Void = { _ in }
    var onInterruption: () -> Void = {}

    private var engine = AVAudioEngine()
    private var synthesizer = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?
    private var ambiguousSpeech: Task<Void, Never>?
    private var routeRecovery: Task<Void, Never>?
    private var generation = UUID()
    private var tapped = false
    private var userSpeechDetected = false
    private var systemInterrupted = false
    private var echoGate = VoiceEchoGate()
    private var observers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?

    override init() {
        super.init()
        synthesizer.delegate = self
        observeAudioSystem()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
    }

    func start() {
        guard !listening else { return }
        error = nil
        let attempt = UUID()
        generation = attempt
        Task {
            let authorized = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
            let microphone = await AVCaptureDevice.requestAccess(for: .audio)
            guard generation == attempt else { return }
            guard authorized, microphone else {
                error = "Allow Microphone and Speech Recognition in system Settings to use voice."
                return
            }
            listening = true
            beginRecognition()
        }
    }

    func stop() {
        generation = UUID()
        listening = false
        systemInterrupted = false
        routeRecovery?.cancel(); routeRecovery = nil
        stopRecognition()
        synthesizer.stopSpeaking(at: .immediate)
        echoGate.assistantStopped()
        speaking = false
        deactivateAudioSession()
    }

    /// Stops both the audible response and any device work associated with that response.
    func interrupt() {
        synthesizer.stopSpeaking(at: .immediate)
        echoGate.assistantStopped()
        speaking = false
        onInterruption()
        if listening, !engine.isRunning, !systemInterrupted { beginRecognition() }
    }

    func speak(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard listening, !value.isEmpty else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        echoGate.assistantStarted(value)
        let utterance = AVSpeechUtterance(string: value)
        utterance.voice = AVSpeechSynthesisVoice(language: localeIdentifier)
        speaking = true
        synthesizer.speak(utterance)
    }

    private func beginRecognition() {
        stopRecognition()
        guard listening, !systemInterrupted else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), recognizer.isAvailable else {
            error = "Speech recognition is unavailable for this language or connection. You can still type."
            listening = false
            return
        }
        do {
            try configureAudioSession()
            let input = engine.inputNode
            // Apple's voice-processing I/O subtracts device output from microphone input. Some
            // external routes cannot enable it; the transcript gate remains as a bounded fallback.
            if !input.isVoiceProcessingEnabled { try? input.setVoiceProcessingEnabled(true) }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request
            transcript = ""
            userSpeechDetected = false
            let id = UUID()
            generation = id
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechFailure() }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapped = true
            engine.prepare()
            try engine.start()
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, failure in
                Task { @MainActor in
                    guard let self, self.generation == id, self.listening else { return }
                    if let result {
                        self.receive(result.bestTranscription.formattedString, isFinal: result.isFinal, generation: id)
                    } else if failure != nil, !self.systemInterrupted {
                        self.stopRecognition()
                        self.listening = false
                        self.error = "Speech recognition stopped. Check the microphone and connection, then start voice again."
                        self.onInterruption()
                    }
                }
            }
        } catch {
            stopRecognition()
            listening = false
            self.error = "The microphone could not start. Check system permission and audio input."
            onInterruption()
        }
    }

    private func receive(_ text: String, isFinal: Bool, generation id: UUID) {
        switch echoGate.classify(text) {
        case .empty:
            return
        case .echo:
            ambiguousSpeech?.cancel(); ambiguousSpeech = nil
        case .ambiguous:
            ambiguousSpeech?.cancel()
            ambiguousSpeech = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard let self, self.generation == id else { return }
                let userText = self.echoGate.removingEchoPrefix(from: text)
                self.acceptUserSpeech(userText, isFinal: isFinal, generation: id)
            }
        case .userSpeech:
            ambiguousSpeech?.cancel(); ambiguousSpeech = nil
            let userText = echoGate.removingEchoPrefix(from: text)
            acceptUserSpeech(userText, isFinal: isFinal, generation: id)
        }
    }

    private func acceptUserSpeech(_ text: String, isFinal: Bool, generation id: UUID) {
        if !userSpeechDetected {
            userSpeechDetected = true
            if synthesizer.isSpeaking || speaking {
                synthesizer.stopSpeaking(at: .immediate)
                echoGate.assistantStopped()
                speaking = false
            }
            // Pause the old device operation before the corrected request can dispatch.
            onInterruption()
        }
        transcript = text
        silence?.cancel()
        if isFinal {
            finishUtterance()
        } else {
            silence = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(1100)) } catch { return }
                guard let self, self.generation == id else { return }
                self.finishUtterance()
            }
        }
    }

    private func finishUtterance() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopRecognition()
        if !text.isEmpty { onUtterance(text) }
        if listening, !systemInterrupted { beginRecognition() }
    }

    private func stopRecognition() {
        generation = UUID()
        silence?.cancel(); silence = nil
        ambiguousSpeech?.cancel(); ambiguousSpeech = nil
        recognition?.cancel(); recognition = nil
        request?.endAudio(); request = nil
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        engine.reset()
    }

    private func configureAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        if #available(iOS 18.2, *), session.isEchoCancelledInputAvailable {
            try? session.setPrefersEchoCancelledInput(true)
        }
        try session.setActive(true)
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func observeAudioSystem() {
        observeEngineConfiguration()
        #if os(iOS)
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.recoverRoute() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        })
        #endif
    }

    private func observeEngineConfiguration() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.engine.isRunning else { return }
                self.recoverRoute()
            }
        }
    }

    private func recoverRoute() {
        guard listening, !systemInterrupted else { return }
        routeRecovery?.cancel()
        routeRecovery = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, self.listening, !self.systemInterrupted else { return }
            self.beginRecognition()
        }
    }

    #if os(iOS)
    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            systemInterrupted = true
            stopRecognition()
            synthesizer.pauseSpeaking(at: .immediate)
            onInterruption()
            return
        }
        let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
        systemInterrupted = false
        guard listening, shouldResume else { return }
        if speaking { _ = synthesizer.continueSpeaking() }
        beginRecognition()
    }

    private func handleMediaServicesReset() {
        guard listening || speaking else { return }
        onInterruption()
        stopRecognition()
        synthesizer.stopSpeaking(at: .immediate)
        engine = AVAudioEngine()
        observeEngineConfiguration()
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        echoGate.assistantStopped()
        listening = false
        speaking = false
        error = "System audio restarted. Start voice again to reconnect the microphone. Device work remains paused."
    }
    #endif

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !self.synthesizer.isSpeaking else { return }
            self.echoGate.assistantStopped()
            self.speaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !self.synthesizer.isSpeaking else { return }
            self.echoGate.assistantStopped()
            self.speaking = false
        }
    }

    private struct SpeechFailure: Error {}
}
