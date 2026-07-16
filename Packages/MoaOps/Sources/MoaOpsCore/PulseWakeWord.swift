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
    private var active = false
    private var didFire = false

    public init(locale: Locale = .current) { self.locale = locale }

    public func start() async -> Bool {
        stop()
        let authorization = await requestAuthorization()
        guard authorization == .authorized else { return false }
        let recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { return false }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.recognizer = recognizer
        self.request = request
        didFire = false
        active = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor [weak self] in self?.recognize(text) }
        }
        return true
    }

    public func stop() {
        active = false
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
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
