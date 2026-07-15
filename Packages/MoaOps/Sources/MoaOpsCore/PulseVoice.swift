import Foundation
#if os(iOS) && canImport(AVFoundation)
import AVFoundation
import UIKit
#if canImport(Speech)
import Speech
#endif
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

public enum PulseAudioPlaybackStep: Equatable, Sendable { case activateSession, startEngine, schedule }
public enum PulseAudioPlaybackPlan {
    /// Session activation is always ordered before engine startup/scheduling.
    public static func steps(sessionIsActive: Bool, engineIsRunning: Bool) -> [PulseAudioPlaybackStep] {
        var steps: [PulseAudioPlaybackStep] = sessionIsActive ? [] : [.activateSession]
        if !engineIsRunning { steps.append(.startEngine) }
        steps.append(.schedule)
        return steps
    }
}

/// Tracks queued playback independently from microphone capture. A provider
/// can finish sending audio before the final scheduled buffer is audible.
public struct PulseAudioPlaybackDrain: Equatable, Sendable {
    public private(set) var pendingBuffers = 0
    public init() {}
    public mutating func schedule() { pendingBuffers += 1 }
    public mutating func finishBuffer() { pendingBuffers = max(0, pendingBuffers - 1) }
    public mutating func reset() { pendingBuffers = 0 }
    public var isDrained: Bool { pendingBuffers == 0 }
}

@MainActor
public protocol PulseVoiceControlling: AnyObject {
    var onTranscript: ((PulseVoiceCaptureToken, String, Bool) -> Void)? { get set }
    var onInterruption: ((PulseVoiceCaptureToken) -> Void)? { get set }
    var onAvailability: ((PulseVoiceCaptureToken, PulseVoiceAvailability) -> Void)? { get set }
    var onPCM16: ((PulseVoiceCaptureToken, Data) -> Void)? { get set }
    /// Stops narration before Speech permission/recording can begin, so the
    /// recognizer never receives Pulse's own spoken turn.
    func stopSpeakingForCapture()
    func beginPushToTalk(capture: PulseVoiceCaptureToken) async
    func beginReviewConfirmation(capture: PulseVoiceCaptureToken) async
    /// Releasing PTT ends audio but leaves the token live until Speech emits
    /// its final transcript. `invalidateCapture` is used for every abort.
    func endPushToTalk(capture: PulseVoiceCaptureToken)
    func invalidateCapture()
    func speak(_ text: String)
    func stopAll()
    func setMuted(_ muted: Bool)
    func setForegroundActive(_ active: Bool)
    func playPCM16(_ pcm: Data)
}

#if os(iOS) && canImport(AVFoundation)
@MainActor
public final class NativePulseVoiceController: NSObject, PulseVoiceControlling {
    public var onTranscript: ((PulseVoiceCaptureToken, String, Bool) -> Void)?
    public var onInterruption: ((PulseVoiceCaptureToken) -> Void)?
    public var onAvailability: ((PulseVoiceCaptureToken, PulseVoiceAvailability) -> Void)?
    public var onPCM16: ((PulseVoiceCaptureToken, Data) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var muted = false
    private var recording = false
    private var foreground = true
    private var audioSessionActive = false
    private var interruptionObserver: NSObjectProtocol?
    private var captureGate = PulseVoiceCaptureGate()
    private var playbackDrain = PulseAudioPlaybackDrain()
#if canImport(Speech)
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
#endif

    public override init() {
        super.init()
        audioEngine.attach(player)
        let output = audioEngine.mainMixerNode
        audioEngine.connect(player, to: output, format: output.outputFormat(forBus: 0))
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            guard let capture = self.captureGate.activeCapture else { return }
            self.player.stop()
            self.playbackDrain.reset()
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
        let microphoneGranted = await microphoneAuthorization()
        // Permission completion can be queued after an interruption, Stop, or
        // foreground loss. Do not start an old capture in that case.
        guard captureGate.accepts(capture) else { return }
        guard microphoneGranted else {
            captureGate.invalidate(capture)
            onAvailability?(capture, .unavailable)
            return
        }
        do {
            try configureAudioSession()
            let input = audioEngine.inputNode
            input.removeTap(onBus: 0)
            let sourceFormat = input.outputFormat(forBus: 0)
            guard let realtimeFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(OpenAIRealtimePCM16.sampleRate), channels: 1, interleaved: true), let converter = AVAudioConverter(from: sourceFormat, to: realtimeFormat) else { throw PulseCallError.decoding }
            input.installTap(onBus: 0, bufferSize: 1_024, format: sourceFormat) { [weak self] buffer, _ in
                guard let self, self.captureGate.accepts(capture), self.recording else { return }
                let ratio = realtimeFormat.sampleRate / sourceFormat.sampleRate
                let output = AVAudioPCMBuffer(pcmFormat: realtimeFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1))!
                var error: NSError?
                converter.convert(to: output, error: &error) { _, status in status.pointee = .haveData; return buffer }
                guard error == nil, let samples = output.int16ChannelData else { return }
                self.onPCM16?(capture, Data(bytes: samples[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size))
            }
            audioEngine.prepare()
            try audioEngine.start()
            recording = true
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

    public func beginReviewConfirmation(capture: PulseVoiceCaptureToken) async {
#if canImport(Speech)
        stopSpeakingForCapture(); captureGate.begin(capture)
        guard foreground, !recording, await microphoneAuthorization(), await speechAuthorization(),
              let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            captureGate.invalidate(capture); onAvailability?(capture, .unavailable); return
        }
        do {
            try configureAudioSession()
            let request = SFSpeechAudioBufferRecognitionRequest(); request.shouldReportPartialResults = true; request.requiresOnDeviceRecognition = true
            recognitionRequest = request
            let input = audioEngine.inputNode; input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1_024, format: input.outputFormat(forBus: 0)) { [weak request] buffer, _ in request?.append(buffer) }
            audioEngine.prepare(); try audioEngine.start(); recording = true
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self, self.captureGate.accepts(capture) else { return }
                    if let result { self.onTranscript?(capture, result.bestTranscription.formattedString, result.isFinal); if result.isFinal { self.finishRecording(cancel: false, invalidating: capture) } }
                    if error != nil { self.finishRecording(cancel: true, invalidating: capture) }
                }
            }
            onAvailability?(capture, .available)
        } catch { finishRecording(cancel: true, invalidating: capture); onAvailability?(capture, .unavailable) }
#else
        onAvailability?(capture, .unavailable)
#endif
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
        player.stop()
        playbackDrain.reset()
        stopAudioWhenIdle()
    }

    public func speak(_ text: String) {
        guard foreground, !muted, !text.isEmpty else { return }
        // Cloud narration arrives as PCM through playPCM16. Do not silently
        // replace it with local TTS, which would hide a failed Realtime path.
    }

    public func stopAll() {
        invalidateCapture()
        player.stop()
        playbackDrain.reset()
        stopAudioWhenIdle()
    }

    public func setMuted(_ muted: Bool) {
        self.muted = muted
        if muted {
            player.stop()
            playbackDrain.reset()
            stopAudioWhenIdle()
        }
    }

    public func setForegroundActive(_ active: Bool) {
        foreground = active
        if !active { stopAll() }
    }

    private func finishRecording(cancel: Bool, invalidating capture: PulseVoiceCaptureToken?) {
        guard recording || capture != nil else { return }
        recording = false
        audioEngine.inputNode.removeTap(onBus: 0)
#if canImport(Speech)
        recognitionRequest?.endAudio()
        if cancel { recognitionTask?.cancel() }
        recognitionTask = nil; recognitionRequest = nil
#endif
        if let capture { captureGate.invalidate(capture) }
        stopAudioWhenIdle()
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        audioSessionActive = true
    }

    private func configurePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        audioSessionActive = true
    }

    public func playPCM16(_ pcm: Data) {
        guard foreground, !muted, !pcm.isEmpty, pcm.count.isMultiple(of: 2), let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(OpenAIRealtimePCM16.sampleRate), channels: 1, interleaved: true) else { return }
        let frames = AVAudioFrameCount(pcm.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        pcm.withUnsafeBytes { raw in memcpy(buffer.int16ChannelData![0], raw.baseAddress!, pcm.count) }
        do {
            // PTT teardown deactivates the session; never start playback into
            // that inactive route.
            try configurePlaybackSession()
            if !audioEngine.isRunning { try audioEngine.start() }
        } catch {
            onAvailability?(captureGate.activeCapture ?? .init(generation: 0), .unavailable)
            return
        }
        playbackDrain.schedule()
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playbackDrain.finishBuffer()
                self.stopAudioWhenIdle()
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func stopAudioWhenIdle() {
        guard !recording, playbackDrain.isDrained else { return }
        player.stop()
        audioEngine.stop()
        guard audioSessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioSessionActive = false
    }

    private func microphoneAuthorization() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        if session.recordPermission == .granted { return true }
        if session.recordPermission == .denied { return false }
        return await withCheckedContinuation { continuation in
            session.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
#if canImport(Speech)
    private func speechAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        guard status == .notDetermined else { return false }
        return await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) } }
    }
#endif
}
#else
/// Package CI and macOS hosts deliberately get a truthful no-op rather than a
/// fake recorder. The Call scene keeps its text fallback visible.
@MainActor
public final class NativePulseVoiceController: PulseVoiceControlling {
    public var onTranscript: ((PulseVoiceCaptureToken, String, Bool) -> Void)?
    public var onInterruption: ((PulseVoiceCaptureToken) -> Void)?
    public var onAvailability: ((PulseVoiceCaptureToken, PulseVoiceAvailability) -> Void)?
    public var onPCM16: ((PulseVoiceCaptureToken, Data) -> Void)?
    public init() {}
    public func stopSpeakingForCapture() {}
    public func beginPushToTalk(capture: PulseVoiceCaptureToken) async { onAvailability?(capture, .unavailable) }
    public func beginReviewConfirmation(capture: PulseVoiceCaptureToken) async { onAvailability?(capture, .unavailable) }
    public func endPushToTalk(capture _: PulseVoiceCaptureToken) {}
    public func invalidateCapture() {}
    public func speak(_: String) {}
    public func stopAll() {}
    public func setMuted(_: Bool) {}
    public func setForegroundActive(_: Bool) {}
    public func playPCM16(_: Data) {}
}
#endif
