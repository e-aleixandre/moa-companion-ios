import Foundation
#if os(iOS) && canImport(AVFoundation)
import AVFoundation
#endif

@MainActor
public protocol PulseVoiceControlling: AnyObject {
    var onPCM16: ((Data) -> Void)? { get set }
    var onInterruption: (() -> Void)? { get set }
    var onPlaybackFailure: (() -> Void)? { get set }
    func startContinuousCapture() async -> Bool
    func stopContinuousCapture()
    func playPCM16(_ pcm: Data)
    func stopAll()
    func setMuted(_ muted: Bool)
}

#if os(iOS) && canImport(AVFoundation)
private final class PulsePCMDeliveryBuffer: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var blocks: [Data] = []
    private var deliveryScheduled = false

    init(capacity: Int = 8) {
        self.capacity = capacity
    }

    func enqueue(_ block: Data, deliver: @escaping @MainActor @Sendable (Data) -> Void) {
        lock.lock()
        if blocks.count == capacity { blocks.removeFirst() }
        blocks.append(block)
        guard !deliveryScheduled else { lock.unlock(); return }
        deliveryScheduled = true
        lock.unlock()
        Task { [weak self] in
            while let next = self?.dequeue() {
                await deliver(next)
            }
        }
    }

    func removeAll() {
        lock.lock()
        blocks.removeAll()
        lock.unlock()
    }

    private func dequeue() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !blocks.isEmpty else {
            deliveryScheduled = false
            return nil
        }
        return blocks.removeFirst()
    }
}

@MainActor
public final class NativePulseVoiceController: NSObject, PulseVoiceControlling {
    public var onPCM16: ((Data) -> Void)?
    public var onInterruption: (() -> Void)?
    public var onPlaybackFailure: (() -> Void)?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(OpenAIRealtimePCM16.sampleRate), channels: 1)!
    private var muted = false
    private var capturing = false
    private let capturedPCM = PulsePCMDeliveryBuffer()
    private var interruptionObserver: NSObjectProtocol?

    public override init() {
        super.init()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in self?.onInterruption?() }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    public func startContinuousCapture() async -> Bool {
        guard !capturing else { return true }
        let session = AVAudioSession.sharedInstance()
        let granted: Bool
        if session.recordPermission == .granted { granted = true }
        else if session.recordPermission == .denied { granted = false }
        else { granted = await withCheckedContinuation { continuation in
            session.requestRecordPermission { continuation.resume(returning: $0) }
        } }
        guard granted else { return false }
        do {
            // voiceChat + allowBluetooth keeps duplex HFP routes available;
            // Pulse must not select A2DP because it has no microphone input.
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            let source = input.outputFormat(forBus: 0)
            guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(OpenAIRealtimePCM16.sampleRate), channels: 1, interleaved: true), let converter = AVAudioConverter(from: source, to: target) else { throw PulseCallError.decoding }
            let capturedPCM = self.capturedPCM
            input.installTap(onBus: 0, bufferSize: 1_024, format: source) { [weak self, capturedPCM] buffer, _ in
                let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / source.sampleRate + 1))!
                var supplied = false
                let result = converter.convert(to: output, error: nil) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return buffer
                }
                guard result != .error, output.frameLength > 0, let samples = output.int16ChannelData else { return }
                capturedPCM.enqueue(Data(bytes: samples[0], count: Int(output.frameLength) * 2)) { [weak self] pcm in
                    guard let self, !self.muted else { return }
                    self.onPCM16?(pcm)
                }
            }
            engine.prepare(); try engine.start(); capturing = true
            return true
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            return false
        }
    }

    public func stopContinuousCapture() { capturing = false; capturedPCM.removeAll(); engine.inputNode.removeTap(onBus: 0) }
    public func setMuted(_ muted: Bool) { self.muted = muted; if muted { capturedPCM.removeAll() } }
    public func stopAll() { stopContinuousCapture(); player.stop(); engine.stop(); try? AVAudioSession.sharedInstance().setActive(false) }
    public func playPCM16(_ pcm: Data) {
        guard let samples = OpenAIRealtimePCM16.float32Samples(pcm), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData?[0].assign(from: $0.baseAddress!, count: samples.count) }
        do { if !engine.isRunning { try engine.start() } } catch { onPlaybackFailure?(); return }
        player.scheduleBuffer(buffer); if !player.isPlaying { player.play() }
    }
}
#else
@MainActor
public final class NativePulseVoiceController: PulseVoiceControlling {
    public var onPCM16: ((Data) -> Void)?
    public var onInterruption: (() -> Void)?
    public var onPlaybackFailure: (() -> Void)?
    public init() {}
    public func startContinuousCapture() async -> Bool { true }
    public func stopContinuousCapture() {}
    public func playPCM16(_: Data) {}
    public func stopAll() {}
    public func setMuted(_: Bool) {}
}
#endif

// TODO(background/reconnect): add background-audio entitlement handling and
// reconnect a dropped call with a fresh broker credential plus new overview.
