import Foundation
import os

public enum PulseGuardianState: Equatable, Sendable {
    case idle, guardianStarting, guardianStandby, waking, listening, speaking, resolving, draining, attentionReconnecting, interrupted, inactive, failed

    public var spanishLabel: String {
        switch self {
        case .idle: "Guardia detenida"
        case .guardianStarting: "Iniciando Guardián"
        case .guardianStandby: "Guardián en espera"
        case .waking: "Activando Pulse"
        case .listening: "Pulse escucha"
        case .speaking: "Pulse anuncia"
        case .resolving: "Pulse resuelve"
        case .draining: "Terminando anuncio"
        case .attentionReconnecting: "Reconectando Guardián"
        case .interrupted: "Audio interrumpido"
        case .inactive: "Otro dispositivo es el Guardián"
        case .failed: "Guardián no disponible"
        }
    }
}

public struct PulseGuardianSnapshot: Equatable, Sendable {
    public var items: [PulseAttentionItem] = []
    public var sessions: [PulseSessionBrief] = []
    public var terminations: [PulseRunTermination] = []
    public init() {}
}

/// Coordinates three independent resources: the inexpensive attention socket,
/// local capture/wake word, and the short-lived Realtime socket. It deliberately
/// contains no policy gate for permissions; the Realtime prompt reads verbatim.
@MainActor
public final class PulseGuardianCoordinator {
    public typealias StateHandler = @Sendable (PulseGuardianState) -> Void
    public typealias SnapshotHandler = @Sendable (PulseGuardianSnapshot) -> Void
    public typealias TextHandler = @Sendable (String) -> Void

    private enum Pending: Sendable {
        case item(PulseAttentionItem)
        case briefing(PulseBriefing)
        case termination(PulseRunTermination)

        var acknowledgement: PulseGuardianAcknowledgement? {
            switch self {
            case let .item(item): return .item(item.id)
            case let .termination(termination): return .termination(termination.id)
            case .briefing: return nil
            }
        }

        func payload() throws -> String {
            let data: Data
            switch self {
            case let .item(item): data = try JSONEncoder.moaOps.encode(ItemEnvelope(item: item))
            case let .briefing(briefing): data = try JSONEncoder.moaOps.encode(BriefingEnvelope(briefing: briefing))
            case let .termination(termination): data = try JSONEncoder.moaOps.encode(TerminationEnvelope(termination: termination))
            }
            return String(decoding: data, as: UTF8.self)
        }

        var deduplicationID: String {
            switch self {
            case let .item(item): return "item:\(item.id)"
            case let .termination(termination): return "termination:\(termination.id)"
            case let .briefing(briefing): return "briefing:\(briefing.sessionID):\(briefing.kind.rawValue):\(briefing.spoken)"
            }
        }
    }

    private enum PulseGuardianAcknowledgement: Sendable { case item(String), termination(String) }
    private struct ItemEnvelope: Encodable { let type = "attention"; let item: PulseAttentionItem }
    private struct BriefingEnvelope: Encodable { let type = "briefing"; let briefing: PulseBriefing }
    private struct TerminationEnvelope: Encodable { let type = "termination"; let termination: PulseRunTermination }

    public private(set) var state: PulseGuardianState = .idle { didSet { onState?(state) } }
    public private(set) var snapshot = PulseGuardianSnapshot() { didSet { onSnapshot?(snapshot) } }
    public var onState: StateHandler?
    public var onSnapshot: SnapshotHandler?
    public var onText: TextHandler?

    private let service: any PulseCallServing
    private let realtime: any PulseRealtimeCalling
    private let attention: any PulseAttentionChanneling
    private let voice: any PulseVoiceControlling
    private let wakeWord: any PulseWakeWordDetecting
    private let hotWindow: TimeInterval
    private var call: (any PulseRealtimeCallControlling)?
    private var queue: [Pending] = []
    private var queuedIDs = Set<String>()
    private var spokenTerminationIDs = Set<String>()
    private var activeAcknowledgement: PulseGuardianAcknowledgement?
    private var pcmQueue: [Data] = []
    // Larger than the previous 8 (~300 ms): tolerate brief network hiccups
    // during warmup/flush without dropping the owner's opening words.
    private let pcmQueueCapacity = 40
    // BUG 2: owner speech captured between activation and socket-ready. At 24 kHz
    // mono 16-bit, ~100 frames of ~40 ms ≈ 4 s, enough to hold the phrase the
    // owner starts right after "Pulse".
    private var warmupBuffer: [Data] = []
    private let warmupCapacity = 100
    private var bufferingOwnerSpeech = false
    private var pcmTask: Task<Void, Never>?
    // Every open and close invalidates work owned by the previous socket. This
    // prevents a cancelled sender from draining PCM belonging to a new call.
    private var socketGeneration = 0
    private var closeTask: Task<Void, Never>?
    private var isRunning = false
    private var isOpeningRealtime = false
    private var isNarrating = false
    private var ownerSpeaking = false
    private var wakeAvailable = false
    private var wakeWordActive = false
    private var wakeWordGeneration = 0
    private var wakeRearmTask: Task<Void, Never>?
    private var wakeRearmTaskGeneration: Int?
    private var wakeRearmPending = false
    private var privateRouteWasPresent = false
    private var announcementsPausedForRoute = false
    private let log = Logger(subsystem: "com.moa.pulse", category: "guardian")
    private var activationStart: Date?

    public init(service: any PulseCallServing, realtime: any PulseRealtimeCalling, attention: any PulseAttentionChanneling, voice: any PulseVoiceControlling, wakeWord: any PulseWakeWordDetecting, hotWindow: TimeInterval = 25) {
        self.service = service
        self.realtime = realtime
        self.attention = attention
        self.voice = voice
        self.wakeWord = wakeWord
        self.hotWindow = hotWindow
        configureAudioCallbacks()
    }

    deinit { pcmTask?.cancel(); closeTask?.cancel(); wakeRearmTask?.cancel() }

    public func start() async {
        guard !isRunning else { return }
        state = .guardianStarting
        guard await voice.startContinuousCapture() else { state = .failed; return }
        isRunning = true
        privateRouteWasPresent = voice.hasPrivateOutputRoute()
        wakeWord.onWakeWord = { [weak self] in
            Task { @MainActor [weak self] in self?.wakeFromOwner() }
        }
        wakeAvailable = await wakeWord.start()
        wakeWordActive = wakeAvailable
        await attention.start(onEvent: { [weak self] message in
            Task { @MainActor [weak self] in self?.receive(message) }
        }, onState: { [weak self] socketState in
            Task { @MainActor [weak self] in self?.receive(socketState) }
        })
        state = .guardianStandby
    }

    public func stop() {
        isRunning = false
        disarmWakeWord()
        Task { await attention.stop() }
        closeTask?.cancel(); closeTask = nil
        socketGeneration &+= 1
        pcmTask?.cancel(); pcmTask = nil; pcmQueue.removeAll()
        let old = call; call = nil; isOpeningRealtime = false; isNarrating = false
        voice.stopAll()
        state = .idle
        Task { await old?.end() }
    }

    /// The UI fallback when on-device Speech is unavailable, and useful for
    /// testing while the device is locked.
    public func activateTalk() { wakeFromOwner() }
    public func reclaimAttention() { Task { await attention.reclaim() } }
    public var isWakeWordAvailable: Bool { wakeAvailable }

    private func configureAudioCallbacks() {
        voice.onPCM16 = { [weak self] pcm in self?.receivePCM(pcm) }
        voice.onInterruption = { [weak self] in self?.audioFailed() }
        voice.onPlaybackFailure = { [weak self] in self?.audioFailed() }
        voice.setPlaybackDrainedHandler { [weak self] in self?.playbackDrained() }
        voice.setTemporaryInterruptionHandler { [weak self] in self?.temporarilyInterrupted() }
        voice.setCaptureResumedHandler { [weak self] in self?.captureResumed() }
        voice.setRouteChangedHandler { [weak self] in self?.routeChanged() }
    }

    private func receive(_ socketState: PulseAttentionWebSocket.State) {
        guard isRunning else { return }
        switch socketState {
        case .connected: if state == .attentionReconnecting { state = .guardianStandby }
        case .connecting, .reconnecting: state = .attentionReconnecting
        case .inactive:
            closeRealtime()
            disarmWakeWord()
            state = .inactive
        case .failed: state = .failed
        case .stopped: break
        }
    }

    private func receive(_ message: PulseAttentionServerMessage) {
        guard isRunning else { return }
        switch message.type {
        case .initial:
            // The only legal reconciliation is replacement, never a merge.
            snapshot.items = message.items ?? []
            snapshot.sessions = message.sessions ?? []
            snapshot.terminations = message.terminations ?? []
            for termination in snapshot.terminations {
                if spokenTerminationIDs.contains(termination.id) {
                    Task { await attention.ackTermination(terminationID: termination.id) }
                } else { enqueue(.termination(termination)) }
            }
            for item in snapshot.items { enqueue(.item(item)) }
        case .attention:
            if let item = message.item {
                snapshot.items.removeAll { $0.id == item.id }
                snapshot.items.append(item)
                enqueue(.item(item))
            }
        case .itemUpdate:
            if let item = message.item {
                snapshot.items.removeAll { $0.id == item.id }
                if item.state != "resolved" { snapshot.items.append(item) }
            }
        case .briefing:
            if let briefing = message.briefing {
                if let termination = briefing.termination { enqueue(.termination(termination)) }
                else { enqueue(.briefing(briefing)) }
            }
        case .roster: snapshot.sessions = message.sessions ?? []
        case .inactive: receive(.inactive)
        case .error: break
        }
    }

    private func enqueue(_ pending: Pending) {
        guard queuedIDs.insert(pending.deduplicationID).inserted else { return }
        queue.append(pending)
        processQueue()
    }

    private func processQueue() {
        guard isRunning, !announcementsPausedForRoute, !queue.isEmpty else { return }
        closeTask?.cancel(); closeTask = nil
        if call == nil {
            guard !isOpeningRealtime else { return }
            openRealtimeForActivation()
            return
        }
        guard !isNarrating else { return }
        let pending = queue.removeFirst()
        queuedIDs.remove(pending.deduplicationID)
        activeAcknowledgement = pending.acknowledgement
        isNarrating = true
        state = .speaking
        Task { [weak self] in
            guard let self else { return }
            do { try await self.call?.requestGuardianNarration(pending.payload()) }
            catch { self.realtimeFailed() }
        }
    }

    /// Builds the `<estado_inicial_moa>` the prompt promises so Pulse can answer
    /// the first "¿qué pasa?" without cold tool calls. Untrusted snapshot text is
    /// framed against delimiter injection, preserving every character as data;
    /// this is anti-injection framing, never censorship.
    private func guardianInitialContext() -> String {
        Self.formatInitialContext(snapshot)
    }

    static func formatInitialContext(_ snapshot: PulseGuardianSnapshot) -> String {
        var lines: [String] = []
        if !snapshot.sessions.isEmpty {
            lines.append("sesiones:")
            for session in snapshot.sessions {
                var parts = ["- \(session.alias): \(session.title) [\(session.state)]"]
                if session.pendingAsks > 0 { parts.append("\(session.pendingAsks) preguntas") }
                if session.pendingPerms > 0 { parts.append("\(session.pendingPerms) permisos") }
                lines.append(parts.joined(separator: ", "))
            }
        }
        if !snapshot.items.isEmpty {
            lines.append("avisos:")
            for item in snapshot.items {
                lines.append("- [\(item.kind.rawValue)] \(item.alias): \(item.spoken)")
            }
        }
        guard !lines.isEmpty else { return "" }
        let content = lines.joined(separator: "\n")
        let neutralized = PulseRealtimeFraming.neutralizeClosingDelimiter(
            in: PulseRealtimeFraming.neutralizeClosingDelimiter(in: content, delimiter: "estado_inicial_moa"),
            delimiter: "guardian_event"
        )
        return "<estado_inicial_moa>\n\(neutralized)\n</estado_inicial_moa>"
    }

    private func openRealtimeForActivation() {
        guard isRunning, !isOpeningRealtime else { return }
        socketGeneration &+= 1
        let generation = socketGeneration
        isOpeningRealtime = true
        state = .waking
        Task { [weak self] in
            guard let self else { return }
            do {
                let credential = try await self.service.mintRealtimeClientSecret()
                guard self.isRunning, self.socketGeneration == generation else { return }
                let executor = PulseGenericToolExecutor(service: self.service)
                let owner = self
                let initialContext = self.guardianInitialContext()
                let opened = try await self.realtime.beginCall(credential: credential, configuration: .init(), executor: executor, initialContext: initialContext, onState: { [weak owner] event in
                    let value = owner
                    Task { @MainActor in value?.receive(event, generation: generation) }
                }, onText: { [weak owner] text in
                    let value = owner
                    Task { @MainActor in value?.onText?(text) }
                }, onAudio: { [weak owner] pcm in
                    let value = owner
                    Task { @MainActor in value?.notePulseAudio(); value?.voice.playPCM16(pcm) }
                }, onBargeIn: { [weak owner] in
                    let value = owner
                    Task { @MainActor in value?.voice.flushPlayback() }
                })
                guard self.isRunning, self.socketGeneration == generation else { await opened.end(); return }
                self.call = opened
                self.isOpeningRealtime = false
                // BUG 2: don't stream audio until the session is actually ready to
                // receive it, then flush everything the owner said during warmup so
                // the phrase started right after "Pulse" is not lost.
                await opened.awaitSessionReady()
                guard self.isRunning, self.socketGeneration == generation, self.call != nil else { return }
                self.flushWarmupBuffer()
                self.logActivation("socket ready")
                self.signalListeningReady()
                self.processQueue()
            } catch {
                guard self.socketGeneration == generation else { return }
                self.isOpeningRealtime = false
                self.bufferingOwnerSpeech = false
                self.warmupBuffer.removeAll()
                self.state = .failed
                self.rearmWakeWord()
            }
        }
    }

    private func flushWarmupBuffer() {
        guard call != nil else { bufferingOwnerSpeech = false; warmupBuffer.removeAll(); return }
        // Prepend the buffered frames to the single serialized send queue and stop
        // buffering, so warmup audio and freshly captured audio drain in one FIFO
        // and never interleave/reorder.
        if !warmupBuffer.isEmpty {
            logActivation("first owner audio sent (\(warmupBuffer.count) buffered frames)")
            pcmQueue.insert(contentsOf: warmupBuffer, at: 0)
            warmupBuffer.removeAll()
        }
        bufferingOwnerSpeech = false
        pumpPCMQueue()
    }

    private func pumpPCMQueue() {
        guard let call, pcmTask == nil, !pcmQueue.isEmpty else { return }
        let generation = socketGeneration
        pcmTask = Task { [weak self] in
            guard let self else { return }
            while true {
                guard self.isRunning, self.socketGeneration == generation, !self.pcmQueue.isEmpty else { break }
                let next = self.pcmQueue.removeFirst()
                do { try await call.appendPCM16(next) }
                catch {
                    if self.socketGeneration == generation { self.realtimeFailed() }
                    break
                }
            }
            if self.socketGeneration == generation { self.pcmTask = nil }
        }
    }

    private func receive(_ realtimeState: PulseRealtimeCallState, generation: Int? = nil) {
        guard isRunning else { return }
        guard generation == nil || generation == socketGeneration else { return }
        switch realtimeState {
        case .connecting: state = .waking
        case .responding: state = .speaking
        case .listening:
            if isNarrating { state = .draining }
            else { state = .listening; scheduleCloseAfterHotWindow() }
        case .speechStarted:
            // Real owner voice (server VAD): keep the call open through the turn.
            ownerSpeaking = true
            closeTask?.cancel(); closeTask = nil
            if !isNarrating { state = .listening }
        case .speechStopped:
            // Only genuine silence after real speech may start the close timer.
            ownerSpeaking = false
            if !isNarrating, queue.isEmpty { scheduleCloseAfterHotWindow() }
        case .ended, .failed: realtimeFailed()
        }
    }

    private func playbackDrained() {
        guard isRunning, isNarrating else { return }
        state = .draining
        let acknowledgement = activeAcknowledgement
        activeAcknowledgement = nil
        isNarrating = false
        switch acknowledgement {
        case let .item(id): Task { await attention.ack(itemID: id) }
        case let .termination(id):
            spokenTerminationIDs.insert(id)
            Task { await attention.ackTermination(terminationID: id) }
        case nil: break
        }
        processQueue()
        if queue.isEmpty { scheduleCloseAfterHotWindow() }
    }

    private func wakeFromOwner() {
        guard isRunning, state != .inactive else { return }
        disarmWakeWord()
        closeTask?.cancel(); closeTask = nil
        if call == nil {
            // Start capturing the owner's opening words immediately; the socket
            // is still ~1.5-3s away and this audio would otherwise be discarded.
            bufferingOwnerSpeech = true
            warmupBuffer.removeAll()
            logActivation("wake fired")
            openRealtimeForActivation()
        } else {
            state = .listening
        }
    }

    /// Re-arms on-device wake detection after the Realtime socket closes. Without
    /// this the detector stays `didFire`/inactive and "Pulse" never wakes again.
    private func rearmWakeWord() {
        guard isRunning, wakeAvailable, !wakeWordActive, state != .inactive, state != .idle else { return }
        if wakeRearmTask != nil {
            if wakeRearmTaskGeneration != wakeWordGeneration { wakeRearmPending = true }
            return
        }
        let generation = wakeWordGeneration
        wakeRearmTaskGeneration = generation
        wakeRearmTask = Task { [weak self] in
            guard let self else { return }
            let started = await self.wakeWord.start()
            guard self.wakeRearmTaskGeneration == generation else { return }
            self.wakeRearmTask = nil
            self.wakeRearmTaskGeneration = nil
            guard self.isRunning, self.state != .inactive, self.state != .idle,
                  self.wakeWordGeneration == generation else {
                self.wakeWord.stop()
                if self.wakeRearmPending {
                    self.wakeRearmPending = false
                    self.rearmWakeWord()
                }
                return
            }
            self.wakeWordActive = started
            if self.wakeRearmPending {
                self.wakeRearmPending = false
                self.rearmWakeWord()
            }
        }
    }

    private func disarmWakeWord() {
        wakeWordGeneration &+= 1
        wakeWordActive = false
        wakeWord.stop()
    }

    // Minimal per-activation timeline (wake -> socket ready -> first owner audio
    // -> first Pulse audio). Concise on purpose: enough to diagnose latency on
    // device without guessing.
    private func logActivation(_ event: String) {
        if activationStart == nil { activationStart = Date() }
        let elapsed = Date().timeIntervalSince(activationStart ?? Date())
        log.info("guardian activation +\(String(format: "%.2f", elapsed), privacy: .public)s: \(event, privacy: .public)")
    }

    private func notePulseAudio() {
        guard activationStart != nil else { return }
        logActivation("first Pulse audio")
        activationStart = nil
    }

    /// The "te escucho" moment: the socket is ready and listening for the owner.
    /// Only meaningful for owner activations (no pending narration to speak).
    private func signalListeningReady() {
        guard isRunning, state != .inactive, queue.isEmpty, !isNarrating else { return }
        state = .listening
        // TODO(ui): play a short earcon/tone here so the owner hears when to
        // speak. Sound synthesis belongs in the redesign UI branch; the explicit
        // .listening transition is the reliable signal in the meantime.
    }

    private func receivePCM(_ pcm: Data) {
        guard isRunning else { return }
        wakeWord.appendPCM16(pcm)
        // BUG 2: between activation and socket-ready there is no call yet. Instead
        // of discarding the owner's opening words, capture them in a bounded
        // buffer that is flushed once the session is ready.
        if bufferingOwnerSpeech {
            if warmupBuffer.count == warmupCapacity { warmupBuffer.removeFirst() }
            warmupBuffer.append(pcm)
            return
        }
        guard call != nil else { return }
        // Raw PCM must NOT extend the hot window: capture is continuous, so keying
        // off it would keep the expensive socket open forever. Only server-VAD
        // speech (speechStarted/speechStopped) governs the call lifetime.
        if pcmQueue.count >= pcmQueueCapacity { pcmQueue.removeFirst() }
        pcmQueue.append(pcm)
        pumpPCMQueue()
    }

    private func scheduleCloseAfterHotWindow() {
        guard call != nil, !isNarrating, !ownerSpeaking else { return }
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.hotWindow * 1_000_000_000))
            guard !Task.isCancelled, self.queue.isEmpty, !self.isNarrating, !self.ownerSpeaking else { return }
            self.closeRealtime()
            if self.isRunning && self.state != .inactive { self.state = .guardianStandby; self.rearmWakeWord() }
        }
    }

    private func closeRealtime() {
        closeTask?.cancel(); closeTask = nil
        socketGeneration &+= 1
        let old = call; call = nil; isOpeningRealtime = false; isNarrating = false; ownerSpeaking = false; activeAcknowledgement = nil
        bufferingOwnerSpeech = false; warmupBuffer.removeAll()
        pcmQueue.removeAll(); pcmTask?.cancel(); pcmTask = nil
        Task { await old?.end() }
    }

    private func temporarilyInterrupted() {
        guard isRunning else { return }
        state = .interrupted
        closeRealtime()
    }

    private func captureResumed() {
        guard isRunning, state == .interrupted else { return }
        state = .guardianStandby
        rearmWakeWord()
    }

    private func routeChanged() {
        let privateNow = voice.hasPrivateOutputRoute()
        if privateRouteWasPresent && !privateNow {
            // Never unexpectedly promote a locked-phone announcement to speaker.
            announcementsPausedForRoute = true
            closeRealtime()
            state = .guardianStandby
            rearmWakeWord()
        } else if announcementsPausedForRoute && privateNow {
            announcementsPausedForRoute = false
            processQueue()
        }
        privateRouteWasPresent = privateNow
    }

    private func audioFailed() {
        guard isRunning else { return }
        closeRealtime()
        state = .failed
        rearmWakeWord()
    }

    private func realtimeFailed() {
        closeRealtime()
        if isRunning && state != .inactive { state = .guardianStandby; rearmWakeWord(); processQueue() }
    }
}
