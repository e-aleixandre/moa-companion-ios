import Foundation
#if os(iOS) && canImport(Speech) && canImport(AVFoundation)
import AVFoundation
import Speech
#endif

/// On-device wake-word recognition. Audio is never sent to OpenAI until the
/// recognizer sees "Pulse". If the selected locale lacks offline recognition,
/// `start()` returns false and the caller keeps the explicit talk button as a
/// fallback. TODO: surface that fallback prominently in the redesign.
@MainActor
public protocol PulseWakeWordDetecting: AnyObject {
    var onWakeWord: (() -> Void)? { get set }
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
    // SFSpeechRecognitionRequest stops delivering results after ~1 min on
    // device, so the recognition task is recreated well before that ceiling.
    private let recycleInterval: TimeInterval

    public init(locale: Locale = .current, recycleInterval: TimeInterval = 50) {
        self.locale = locale
        self.recycleInterval = recycleInterval
    }

    /// Idempotent (re)arm: every call resets `didFire` and installs a fresh
    /// recognition task, so the coordinator can rearm after each activation.
    public func start() async -> Bool {
        stop()
        let authorization = await requestAuthorization()
        guard authorization == .authorized else { return false }
        let recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { return false }
        self.recognizer = recognizer
        didFire = false
        active = true
        startRecognitionTask()
        return true
    }

    public func stop() {
        active = false
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
        request?.endAudio()
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let ended = (result?.isFinal ?? false) || error != nil
            Task { @MainActor [weak self] in
                if let text { self?.recognize(text) }
                if ended { self?.recycleRecognition() }
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
        onWakeWord?()
    }
}
#else
@MainActor
public final class PulseWakeWordDetector: PulseWakeWordDetecting {
    public var onWakeWord: (() -> Void)?
    public init(locale _: Locale = .current) {}
    public func start() async -> Bool { false }
    public func stop() {}
    public func appendPCM16(_: Data) {}
}
#endif
