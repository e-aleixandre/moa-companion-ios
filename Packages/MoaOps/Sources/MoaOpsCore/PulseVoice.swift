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
    func playPCM16(_ pcm: Data, completion: @escaping @Sendable () -> Void)
    func flushPlayback()
    func stopAll()
    func setMuted(_ muted: Bool)
    func setPlaybackDrainedHandler(_ handler: @escaping () -> Void)
    func setTemporaryInterruptionHandler(_ handler: @escaping () -> Void)
    func setCaptureResumedHandler(_ handler: @escaping () -> Void)
    func setRouteChangedHandler(_ handler: @escaping () -> Void)
    func hasPrivateOutputRoute() -> Bool
}

public extension PulseVoiceControlling {
    func playPCM16(_ pcm: Data, completion: @escaping @Sendable () -> Void) {
        playPCM16(pcm)
        completion()
    }
    func setPlaybackDrainedHandler(_: @escaping () -> Void) {}
    func setTemporaryInterruptionHandler(_: @escaping () -> Void) {}
    func setCaptureResumedHandler(_: @escaping () -> Void) {}
    func setRouteChangedHandler(_: @escaping () -> Void) {}
    func hasPrivateOutputRoute() -> Bool { true }
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

private enum PulseCaptureSetupError: Error {
    case unavailableInputFormat
}

@MainActor
public final class NativePulseVoiceController: NSObject, PulseVoiceControlling {
    public var onPCM16: ((Data) -> Void)?
    public var onInterruption: (() -> Void)?
    public var onPlaybackFailure: (() -> Void)?
    public private(set) var isVoiceProcessingActive = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    // Keep-alive: a silent looping node that keeps the output active while we
    // capture. iOS reaps a recording-only session when the screen locks (more
    // aggressively on iOS 26.x); a running output node signals "actively doing
    // audio" so the guardian survives in the pocket. We are genuinely recording
    // the whole time — this is the standard keep-alive node, not a fake-activity
    // trick.
    private let keepAlive = AVAudioPlayerNode()
    private var keepAliveRunning = false
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(OpenAIRealtimePCM16.sampleRate), channels: 1)!
    private var muted = false
    private var capturing = false
    private var interrupted = false
    private var captureRebuildTask: Task<Void, Never>?
    private var captureRebuildScheduled = false
    private var captureRebuildAttempts = 0
    private let capturedPCM = PulsePCMDeliveryBuffer()
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var engineConfigObserver: NSObjectProtocol?
    private var playbackDrainedHandler: (() -> Void)?
    private var temporaryInterruptionHandler: (() -> Void)?
    private var captureResumedHandler: (() -> Void)?
    private var routeChangedHandler: (() -> Void)?
    private var queuedPlaybackBuffers = 0
    private var playbackGeneration: UInt64 = 0

    public override init() {
        super.init()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.attach(keepAlive)
        engine.connect(keepAlive, to: engine.mainMixerNode, format: format)
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        routeChangeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleCaptureRebuild()
            self?.routeChangedHandler?()
        }
        engineConfigObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.scheduleCaptureRebuild()
        }
    }

    deinit {
        captureRebuildTask?.cancel()
        for observer in [interruptionObserver, routeChangeObserver, engineConfigObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
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
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
            try session.setActive(true)
            try startEngineWithCurrentInputFormat()
            capturing = true
            interrupted = false
            return true
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            return false
        }
    }

    private func startEngineWithCurrentInputFormat() throws {
        // Enabling VPIO is an I/O-unit reconfiguration. AVAudioEngine requires
        // it to happen while stopped, before a tap reads the new input format.
        engine.stop()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        configureVoiceProcessing(for: input)
        try installCaptureTap(on: input)
        engine.prepare()
        try engine.start()
        startKeepAlive()
    }

    // Schedules an endless buffer of silence on the keep-alive node so the
    // output stays active for as long as we are capturing. Without a running
    // output, iOS treats the session as idle recording and kills the app after
    // ~50s in the background on recent releases. Idempotent and safe to call
    // after every engine (re)start, since engine.stop() also stops this node.
    private func startKeepAlive() {
        guard engine.isRunning else { return }
        let frames = AVAudioFrameCount(format.sampleRate / 10) // 100 ms of silence
        guard frames > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        silence.frameLength = frames // zero-filled: silent
        keepAlive.scheduleBuffer(silence, at: nil, options: .loops, completionHandler: nil)
        if !keepAlive.isPlaying { keepAlive.play() }
        keepAliveRunning = true
    }

    private func stopKeepAlive() {
        guard keepAliveRunning else { return }
        keepAlive.stop()
        keepAliveRunning = false
    }

    private func configureVoiceProcessing(for input: AVAudioInputNode) {
        guard !engine.isRunning else {
            assertionFailure("Voice processing must be configured with a stopped engine")
            return
        }
        guard !input.isVoiceProcessingEnabled else {
            isVoiceProcessingActive = true
            return
        }
        do {
            try input.setVoiceProcessingEnabled(true)
            isVoiceProcessingActive = input.isVoiceProcessingEnabled
            if !isVoiceProcessingActive { NSLog("Pulse voice processing could not be enabled") }
        } catch {
            isVoiceProcessingActive = false
            NSLog("Pulse voice processing unavailable: \(error.localizedDescription)")
        }
    }

    private func installCaptureTap(on input: AVAudioInputNode) throws {
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(OpenAIRealtimePCM16.sampleRate), channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw PulseCaptureSetupError.unavailableInputFormat
        }
        let capturedPCM = self.capturedPCM
        input.installTap(onBus: 0, bufferSize: 1_024, format: source) { [weak self, capturedPCM] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / source.sampleRate + 1)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            let result = converter.convert(to: output, error: nil) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard result != .error, output.frameLength > 0, let samples = output.int16ChannelData else { return }
            capturedPCM.enqueue(Data(bytes: samples[0], count: Int(output.frameLength) * 2)) { [weak self] pcm in
                guard let self, !self.muted else { return }
                self.onPCM16?(pcm)
            }
        }
    }

    private func scheduleCaptureRebuild() {
        guard capturing, !interrupted, !captureRebuildScheduled else { return }
        captureRebuildScheduled = true
        capturedPCM.removeAll()
        player.stop()
        stopKeepAlive()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        captureRebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, let self else { return }
            self.captureRebuildTask = nil
            self.captureRebuildScheduled = false
            self.rebuildCaptureAfterConfigurationChange()
        }
    }

    private func rebuildCaptureAfterConfigurationChange() {
        guard capturing, !interrupted else { return }
        do {
            try startEngineWithCurrentInputFormat()
            captureRebuildAttempts = 0
            captureResumedHandler?()
        } catch PulseCaptureSetupError.unavailableInputFormat {
            captureRebuildAttempts += 1
            if captureRebuildAttempts < 5 {
                scheduleCaptureRebuild()
            } else {
                failCapture()
            }
        } catch {
            failCapture()
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            guard capturing else { return }
            interrupted = true
            captureRebuildTask?.cancel()
            captureRebuildTask = nil
            captureRebuildScheduled = false
            capturedPCM.removeAll()
            stopKeepAlive()
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            temporaryInterruptionHandler?()
        case .ended:
            guard interrupted else { return }
            interrupted = false
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            guard options.contains(.shouldResume) else {
                failCapture()
                return
            }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                scheduleCaptureRebuild()
            } catch {
                failCapture()
            }
        @unknown default:
            break
        }
    }

    private func failCapture() {
        capturing = false
        interrupted = false
        captureRebuildTask?.cancel()
        captureRebuildTask = nil
        captureRebuildScheduled = false
        capturedPCM.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onInterruption?()
    }

    public func stopContinuousCapture() {
        capturing = false
        interrupted = false
        captureRebuildTask?.cancel()
        captureRebuildTask = nil
        captureRebuildScheduled = false
        capturedPCM.removeAll()
        stopKeepAlive()
        engine.inputNode.removeTap(onBus: 0)
    }

    public func setMuted(_ muted: Bool) {
        self.muted = muted
        if muted { capturedPCM.removeAll() }
    }

    public func flushPlayback() {
        playbackGeneration &+= 1
        queuedPlaybackBuffers = 0
        player.stop()
    }

    public func stopAll() {
        stopContinuousCapture()
        flushPlayback()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    public func playPCM16(_ pcm: Data) { playPCM16(pcm, completion: {}) }

    public func playPCM16(_ pcm: Data, completion: @escaping @Sendable () -> Void) {
        guard let samples = OpenAIRealtimePCM16.float32Samples(pcm),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { samples in
            buffer.floatChannelData?[0].assign(from: samples.baseAddress!, count: samples.count)
        }
        do {
            if !engine.isRunning, !interrupted, captureRebuildTask == nil { try engine.start(); startKeepAlive() }
        } catch {
            onPlaybackFailure?()
            return
        }
        queuedPlaybackBuffers += 1
        let generation = playbackGeneration
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                completion()
                self.queuedPlaybackBuffers = max(0, self.queuedPlaybackBuffers - 1)
                if self.queuedPlaybackBuffers == 0 { self.playbackDrainedHandler?() }
            }
        }
        if !player.isPlaying { player.play() }
    }

    public func setPlaybackDrainedHandler(_ handler: @escaping () -> Void) { playbackDrainedHandler = handler }
    public func setTemporaryInterruptionHandler(_ handler: @escaping () -> Void) { temporaryInterruptionHandler = handler }
    public func setCaptureResumedHandler(_ handler: @escaping () -> Void) { captureResumedHandler = handler }
    public func setRouteChangedHandler(_ handler: @escaping () -> Void) { routeChangedHandler = handler }
    public func hasPrivateOutputRoute() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
        }
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
    public func flushPlayback() {}
    public func stopAll() {}
    public func setMuted(_: Bool) {}
}
#endif

// TODO(background/reconnect): add background-audio entitlement handling and
// reconnect a dropped call with a fresh broker credential plus new overview.
