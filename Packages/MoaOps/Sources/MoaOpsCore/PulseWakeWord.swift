import Foundation
#if os(iOS) && canImport(Speech) && canImport(AVFoundation)
import AVFoundation
import Speech
import os
#endif

/// On-device wake-word recognition. Audio is never sent to OpenAI until the
/// recognizer sees "Pulse". If the selected locale lacks offline recognition,
/// `start()` returns false and the caller keeps the explicit talk button as a
/// fallback. TODO: surface that fallback prominently in the redesign.
/// On-screen diagnostics for the wake word, so the "Pulse va sordo" bug can be
/// reproduced without diving into Console.app logs (which drop `.info`).
public struct PulseWakeWordDiagnostics: Equatable, Sendable {
    /// True while a recognition task is installed and hasn't fired yet, i.e.
    /// `appendPCM16` will actually feed the recognizer instead of early-returning.
    public var armed: Bool
    public var active: Bool
    public var didFire: Bool
    public var generation: Int
    /// Total PCM buffers that reached the recognizer (passed the `active/didFire`
    /// guard). If this freezes while the coordinator keeps receiving mic audio,
    /// the recognizer is desarmado; if it climbs but "Pulse" never matches, the
    /// recognizer is fed but deaf.
    public var appendedBuffers: Int
    /// Why the recognizer could/couldn't arm, captured on the last `start()`.
    /// Lets the on-screen panel show the exact reason for
    /// "on-device recognition unavailable" (locale, nil recognizer, service
    /// availability, on-device support, authorization) instead of a dead end.
    public var localeIdentifier: String
    public var recognizerIsNil: Bool
    public var recognizerAvailable: Bool
    public var supportsOnDevice: Bool
    public var authorization: String
    /// Whether `locale` is in `SFSpeechRecognizer.supportedLocales()`.
    public var localeSupported: Bool

    public init(armed: Bool = false, active: Bool = false, didFire: Bool = false, generation: Int = 0, appendedBuffers: Int = 0, localeIdentifier: String = "?", recognizerIsNil: Bool = false, recognizerAvailable: Bool = false, supportsOnDevice: Bool = false, authorization: String = "?", localeSupported: Bool = false) {
        self.armed = armed
        self.active = active
        self.didFire = didFire
        self.generation = generation
        self.appendedBuffers = appendedBuffers
        self.localeIdentifier = localeIdentifier
        self.recognizerIsNil = recognizerIsNil
        self.recognizerAvailable = recognizerAvailable
        self.supportsOnDevice = supportsOnDevice
        self.authorization = authorization
        self.localeSupported = localeSupported
    }
}

@MainActor
public protocol PulseWakeWordDetecting: AnyObject {
    var onWakeWord: (() -> Void)? { get set }
    var diagnostics: PulseWakeWordDiagnostics { get }
    func start() async -> Bool
    func stop()
    func appendPCM16(_ pcm: Data)
}

#if os(iOS) && canImport(Speech) && canImport(AVFoundation)
@MainActor
public final class PulseWakeWordDetector: NSObject, PulseWakeWordDetecting {
    public var onWakeWord: (() -> Void)?
    private let locale: Locale
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recycleTask: Task<Void, Never>?
    private var active = false
    private var didFire = false
    // Identifies the current recognition task. Every stop()/start()/recycle
    // bumps it, so a late callback from a cancelled SFSpeechRecognitionTask can
    // be recognized as stale and ignored instead of tearing down the live task
    // that replaced it (the root cause of "Pulse" going deaf after the first
    // activation).
    private var recognitionGeneration = 0
    private var retryTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.moa.pulse", category: "wakeword")
    private var appendedBuffers = 0
    private var lastHeartbeat = Date.distantPast
    // Captured on each start() so the on-screen panel can explain exactly why the
    // recognizer did or didn't arm (locale / nil recognizer / availability /
    // on-device support / authorization).
    private var lastRecognizerIsNil = false
    private var lastRecognizerAvailable = false
    private var lastSupportsOnDevice = false
    private var lastAuthorization: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    // SFSpeechRecognitionRequest stops delivering results after ~1 min on
    // device, so the recognition task is recreated well before that ceiling.
    private let recycleInterval: TimeInterval

    public init(locale: Locale = .current, recycleInterval: TimeInterval = 50) {
        self.locale = locale
        self.recycleInterval = recycleInterval
    }

    public var diagnostics: PulseWakeWordDiagnostics {
        PulseWakeWordDiagnostics(
            armed: active && !didFire && task != nil,
            active: active,
            didFire: didFire,
            generation: recognitionGeneration,
            appendedBuffers: appendedBuffers,
            localeIdentifier: locale.identifier,
            recognizerIsNil: lastRecognizerIsNil,
            recognizerAvailable: lastRecognizerAvailable,
            supportsOnDevice: lastSupportsOnDevice,
            authorization: Self.authorizationLabel(lastAuthorization),
            localeSupported: SFSpeechRecognizer.supportedLocales().contains { $0.identifier == locale.identifier }
        )
    }

    private static func authorizationLabel(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    /// Idempotent (re)arm: every call resets `didFire` and installs a fresh
    /// recognition task, so the coordinator can rearm after each activation.
    public func start() async -> Bool {
        stop()
        // Capture the generation across the authorization await: if stop() runs
        // while suspended, this arm is stale and must not revive active/didFire.
        let generation = recognitionGeneration
        let authorization = await requestAuthorization()
        lastAuthorization = authorization
        guard authorization == .authorized else {
            log.info("wake arm failed: authorization=\(authorization.rawValue, privacy: .public)")
            return false
        }
        guard generation == recognitionGeneration else {
            log.info("wake arm abandoned: stopped during authorization")
            return false
        }
        let recognizer = SFSpeechRecognizer(locale: locale)
        lastRecognizerIsNil = recognizer == nil
        lastRecognizerAvailable = recognizer?.isAvailable ?? false
        lastSupportsOnDevice = recognizer?.supportsOnDeviceRecognition ?? false
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            log.info("wake arm failed: on-device recognition unavailable nil=\(recognizer == nil, privacy: .public) available=\(self.lastRecognizerAvailable, privacy: .public) locale=\(self.locale.identifier, privacy: .public)")
            return false
        }
        self.recognizer = recognizer
        didFire = false
        active = true
        startRecognitionTask()
        return true
    }

    public func stop() {
        active = false
        recognitionGeneration &+= 1
        retryTask?.cancel()
        retryTask = nil
        recycleTask?.cancel()
        recycleTask = nil
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
    }

    /// Recreates the underlying request/task while preserving `active` and
    /// `didFire`, so a long standby never silently stops hearing "Pulse".
    private func startRecognitionTask() {
        guard active, !didFire, let recognizer else { return }
        retryTask?.cancel()
        retryTask = nil
        request?.endAudio()
        task?.cancel()
        recognitionGeneration &+= 1
        let generation = recognitionGeneration
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        log.info("wake task armed gen=\(generation, privacy: .public)")
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let ended = (result?.isFinal ?? false) || error != nil
            let errorInfo = error.map { "\(($0 as NSError).domain)#\(($0 as NSError).code)" }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A callback from a task other than the current one is stale
                // (e.g. the cancellation error of the task we just replaced). It
                // must never recycle or wake, or it would tear down the live task.
                guard generation == self.recognitionGeneration else {
                    self.log.info("wake callback ignored: stale gen=\(generation, privacy: .public) current=\(self.recognitionGeneration, privacy: .public) err=\(errorInfo ?? "nil", privacy: .public)")
                    return
                }
                if let text { self.recognize(text) }
                if ended {
                    self.log.info("wake task ended gen=\(generation, privacy: .public) err=\(errorInfo ?? "nil", privacy: .public)")
                    if error != nil { self.scheduleRetry() } else { self.recycleRecognition() }
                }
            }
        }
        scheduleRecycle()
    }

    private func scheduleRecycle() {
        recycleTask?.cancel()
        let interval = recycleInterval
        recycleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.recycleRecognition()
        }
    }

    /// A task that ended with an error is not recreated synchronously: a
    /// permanent error would spin a hot create/cancel loop. A short cancellable
    /// delay recovers from transient Speech errors without churning.
    private func scheduleRetry() {
        guard active, !didFire else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.retryTask = nil
                self.recycleRecognition()
            }
        }
    }

    private func recycleRecognition() {
        guard active, !didFire else { return }
        startRecognitionTask()
    }

    public func appendPCM16(_ pcm: Data) {
        guard active, !didFire, !pcm.isEmpty, pcm.count.isMultiple(of: 2),
              let request,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(OpenAIRealtimePCM16.sampleRate), channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count / 2)) else { return }
        buffer.frameLength = buffer.frameCapacity
        pcm.withUnsafeBytes { raw in
            guard let source = raw.baseAddress, let destination = buffer.int16ChannelData?[0] else { return }
            destination.assign(from: source.assumingMemoryBound(to: Int16.self), count: Int(buffer.frameLength))
        }
        request.append(buffer)
        // Heartbeat: confirms on device whether audio still reaches the wake
        // word after the first activation cycle (distinguishes a dead tap from a
        // dead recognizer). One line every ~5s while armed, not per buffer.
        appendedBuffers &+= 1
        let now = Date()
        if now.timeIntervalSince(lastHeartbeat) >= 5 {
            lastHeartbeat = now
            log.info("wake pcm heartbeat gen=\(self.recognitionGeneration, privacy: .public) buffers=\(self.appendedBuffers, privacy: .public)")
        }
    }

    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private func recognize(_ value: String) {
        guard active, !didFire else { return }
        let text = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard words.contains(where: { $0.caseInsensitiveCompare("pulse") == .orderedSame }) else { return }
        didFire = true
        log.info("wake matched gen=\(self.recognitionGeneration, privacy: .public)")
        onWakeWord?()
    }
}
#else
@MainActor
public final class PulseWakeWordDetector: PulseWakeWordDetecting {
    public var onWakeWord: (() -> Void)?
    public var diagnostics: PulseWakeWordDiagnostics { PulseWakeWordDiagnostics() }
    public init(locale _: Locale = .current) {}
    public func start() async -> Bool { false }
    public func stop() {}
    public func appendPCM16(_: Data) {}
}
#endif
