import Foundation
#if os(iOS) && canImport(Speech) && canImport(AVFoundation)
import AVFoundation
import Speech
import UIKit
#endif

public enum PulsePTTState: Equatable, Sendable {
    case idle
    case requestingPermission
    case listening
    case interrupted
    case unavailable
}

public enum PulsePTTEvent: Equatable, Sendable {
    case press
    case permission(granted: Bool)
    case release
    case interruption
    case foreground(active: Bool)
    case unavailable
}

public enum PulsePTTReducer {
    public static func reduce(_ state: PulsePTTState, event: PulsePTTEvent) -> PulsePTTState {
        switch event {
        case .press where state == .idle: return .requestingPermission
        case let .permission(granted) where state == .requestingPermission: return granted ? .listening : .unavailable
        case .release where state == .listening: return .idle
        case .interruption where state == .listening || state == .requestingPermission: return .interrupted
        case let .foreground(active) where !active: return state == .listening ? .interrupted : state
        case let .foreground(active) where active && state == .interrupted: return .idle
        case .unavailable: return .unavailable
        default: return state
        }
    }
}

public enum PulseVoiceAvailability: Equatable, Sendable {
    case available
    case unavailable
}

@MainActor
public protocol PulseVoiceControlling: AnyObject {
    var onTranscript: ((String, Bool) -> Void)? { get set }
    var onInterruption: (() -> Void)? { get set }
    var onAvailability: ((PulseVoiceAvailability) -> Void)? { get set }
    /// Stops narration before Speech permission/recording can begin, so the
    /// recognizer never receives Pulse's own spoken turn.
    func stopSpeakingForCapture()
    func beginPushToTalk() async
    func endPushToTalk()
    func speak(_ text: String)
    func stopAll()
    func setMuted(_ muted: Bool)
    func setForegroundActive(_ active: Bool)
}

#if os(iOS) && canImport(Speech) && canImport(AVFoundation)
@MainActor
public final class NativePulseVoiceController: NSObject, PulseVoiceControlling, AVSpeechSynthesizerDelegate {
    public var onTranscript: ((String, Bool) -> Void)?
    public var onInterruption: (() -> Void)?
    public var onAvailability: ((PulseVoiceAvailability) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var muted = false
    private var recording = false
    private var foreground = true
    private var interruptionObserver: NSObjectProtocol?

    public override init() {
        super.init()
        synthesizer.delegate = self
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self.finishRecording(cancel: true)
            self.onInterruption?()
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    public func beginPushToTalk() async {
        // Keep this defensive stop inside the native controller too: callers
        // can never accidentally request recognition while narration is live.
        stopSpeakingForCapture()
        guard foreground, !recording else { onAvailability?(.unavailable); return }
        let speechStatus = await speechAuthorization()
        let microphoneGranted = await microphoneAuthorization()
        guard speechStatus == .authorized, microphoneGranted, recognizer?.isAvailable == true else {
            onAvailability?(.unavailable)
            return
        }
        do {
            try configureAudioSession()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request
            let input = audioEngine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1_024, format: input.outputFormat(forBus: 0)) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            recording = true
            recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let result {
                        self.onTranscript?(result.bestTranscription.formattedString, result.isFinal)
                        if result.isFinal { self.finishRecording(cancel: false) }
                    }
                    if error != nil { self.finishRecording(cancel: true) }
                }
            }
            onAvailability?(.available)
        } catch {
            finishRecording(cancel: true)
            onAvailability?(.unavailable)
        }
    }

    public func endPushToTalk() { finishRecording(cancel: false) }

    public func stopSpeakingForCapture() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    public func speak(_ text: String) {
        guard foreground, !muted, !text.isEmpty else { return }
        finishRecording(cancel: false)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "es-ES")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    public func stopAll() {
        finishRecording(cancel: true)
        synthesizer.stopSpeaking(at: .immediate)
    }

    public func setMuted(_ muted: Bool) {
        self.muted = muted
        if muted { synthesizer.stopSpeaking(at: .immediate) }
    }

    public func setForegroundActive(_ active: Bool) {
        foreground = active
        if !active { stopAll() }
    }

    private func finishRecording(cancel: Bool) {
        guard recording || request != nil else { return }
        recording = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        if cancel { recognitionTask?.cancel() }
        recognitionTask = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status != .notDetermined { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private func microphoneAuthorization() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        if session.recordPermission == .granted { return true }
        if session.recordPermission == .denied { return false }
        return await withCheckedContinuation { continuation in
            session.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
}
#else
/// Package CI and macOS hosts deliberately get a truthful no-op rather than a
/// fake recorder. The Call scene keeps its text fallback visible.
@MainActor
public final class NativePulseVoiceController: PulseVoiceControlling {
    public var onTranscript: ((String, Bool) -> Void)?
    public var onInterruption: (() -> Void)?
    public var onAvailability: ((PulseVoiceAvailability) -> Void)?
    public init() {}
    public func stopSpeakingForCapture() {}
    public func beginPushToTalk() async { onAvailability?(.unavailable) }
    public func endPushToTalk() {}
    public func speak(_: String) {}
    public func stopAll() {}
    public func setMuted(_: Bool) {}
    public func setForegroundActive(_: Bool) {}
}
#endif
