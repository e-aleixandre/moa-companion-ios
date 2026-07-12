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

/// A capture token belongs to one explicit PTT gesture. It is supplied by the
/// call model and echoed by the voice implementation so a delayed Speech
/// callback can never be mistaken for a later gesture.
public struct PulseVoiceCaptureToken: Equatable, Hashable, Sendable {
    public let generation: UInt64

    public init(generation: UInt64) {
        self.generation = generation
    }
}

/// Small deterministic gate shared by the native implementation's async
/// permission/recognition paths and exercised on non-iOS package builds.
/// Invalidating a token is final: queued callbacks for it must be ignored.
public struct PulseVoiceCaptureGate: Equatable, Sendable {
    public private(set) var activeCapture: PulseVoiceCaptureToken?

    public init() {}

    public mutating func begin(_ capture: PulseVoiceCaptureToken) {
        activeCapture = capture
    }

    public mutating func invalidate(_ capture: PulseVoiceCaptureToken? = nil) {
        guard capture == nil || activeCapture == capture else { return }
        activeCapture = nil
    }

    public func accepts(_ capture: PulseVoiceCaptureToken) -> Bool {
        activeCapture == capture
    }
}

@MainActor
public protocol PulseVoiceControlling: AnyObject {
    var onTranscript: ((PulseVoiceCaptureToken, String, Bool) -> Void)? { get set }
    var onInterruption: ((PulseVoiceCaptureToken) -> Void)? { get set }
    var onAvailability: ((PulseVoiceCaptureToken, PulseVoiceAvailability) -> Void)? { get set }
    /// Stops narration before Speech permission/recording can begin, so the
    /// recognizer never receives Pulse's own spoken turn.
    func stopSpeakingForCapture()
    func beginPushToTalk(capture: PulseVoiceCaptureToken) async
    /// Releasing PTT ends audio but leaves the token live until Speech emits
    /// its final transcript. `invalidateCapture` is used for every abort.
    func endPushToTalk(capture: PulseVoiceCaptureToken)
    func invalidateCapture()
    func speak(_ text: String)
    func stopAll()
    func setMuted(_ muted: Bool)
    func setForegroundActive(_ active: Bool)
}

#if os(iOS) && canImport(Speech) && canImport(AVFoundation)
@MainActor
public final class NativePulseVoiceController: NSObject, PulseVoiceControlling, AVSpeechSynthesizerDelegate {
    public var onTranscript: ((PulseVoiceCaptureToken, String, Bool) -> Void)?
    public var onInterruption: ((PulseVoiceCaptureToken) -> Void)?
    public var onAvailability: ((PulseVoiceCaptureToken, PulseVoiceAvailability) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var muted = false
    private var recording = false
    private var foreground = true
    private var interruptionObserver: NSObjectProtocol?
    private var captureGate = PulseVoiceCaptureGate()

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
            guard let capture = self.captureGate.activeCapture else { return }
            self.finishRecording(cancel: true, invalidating: capture)
            self.onInterruption?(capture)
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    public func beginPushToTalk(capture: PulseVoiceCaptureToken) async {
        // Keep this defensive stop inside the native controller too: callers
        // can never accidentally request recognition while narration is live.
        stopSpeakingForCapture()
        captureGate.begin(capture)
        guard foreground, !recording else {
            captureGate.invalidate(capture)
            onAvailability?(capture, .unavailable)
            return
        }
        let speechStatus = await speechAuthorization()
        let microphoneGranted = await microphoneAuthorization()
        // Permission completion can be queued after an interruption, Stop, or
        // foreground loss. Do not start an old capture in that case.
        guard captureGate.accepts(capture) else { return }
        guard speechStatus == .authorized, microphoneGranted, recognizer?.isAvailable == true else {
            captureGate.invalidate(capture)
            onAvailability?(capture, .unavailable)
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
                    // Speech can call its result handler after cancel(). The
                    // token gate makes every such callback inert.
                    guard self.captureGate.accepts(capture) else { return }
                    if let result {
                        self.onTranscript?(capture, result.bestTranscription.formattedString, result.isFinal)
                        if result.isFinal { self.finishRecording(cancel: false, invalidating: capture) }
                    }
                    if error != nil { self.finishRecording(cancel: true, invalidating: capture) }
                }
            }
            guard captureGate.accepts(capture) else {
                finishRecording(cancel: true, invalidating: nil)
                return
            }
            onAvailability?(capture, .available)
        } catch {
            finishRecording(cancel: true, invalidating: capture)
            onAvailability?(capture, .unavailable)
        }
    }

    public func endPushToTalk(capture: PulseVoiceCaptureToken) {
        guard captureGate.accepts(capture) else { return }
        // Keep `capture` live until the final recognition callback arrives.
        finishRecording(cancel: false, invalidating: nil)
    }

    public func invalidateCapture() {
        finishRecording(cancel: true, invalidating: captureGate.activeCapture)
    }

    public func stopSpeakingForCapture() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    public func speak(_ text: String) {
        guard foreground, !muted, !text.isEmpty else { return }
        invalidateCapture()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "es-ES")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    public func stopAll() {
        invalidateCapture()
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

    private func finishRecording(cancel: Bool, invalidating capture: PulseVoiceCaptureToken?) {
        guard recording || request != nil || capture != nil else { return }
        recording = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        if cancel { recognitionTask?.cancel() }
        recognitionTask = nil
        request = nil
        if let capture { captureGate.invalidate(capture) }
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
    public var onTranscript: ((PulseVoiceCaptureToken, String, Bool) -> Void)?
    public var onInterruption: ((PulseVoiceCaptureToken) -> Void)?
    public var onAvailability: ((PulseVoiceCaptureToken, PulseVoiceAvailability) -> Void)?
    public init() {}
    public func stopSpeakingForCapture() {}
    public func beginPushToTalk(capture: PulseVoiceCaptureToken) async { onAvailability?(capture, .unavailable) }
    public func endPushToTalk(capture _: PulseVoiceCaptureToken) {}
    public func invalidateCapture() {}
    public func speak(_: String) {}
    public func stopAll() {}
    public func setMuted(_: Bool) {}
    public func setForegroundActive(_: Bool) {}
}
#endif
