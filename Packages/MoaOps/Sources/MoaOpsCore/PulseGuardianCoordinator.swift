import Foundation

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
    private let attention: PulseAttentionWebSocket
    private let voice: any PulseVoiceControlling
    private let wakeWord: any PulseWakeWordDetecting
    private let hotWindow: TimeInterval
    private var call: (any PulseRealtimeCallControlling)?
    private var queue: [Pending] = []
    private var queuedIDs = Set<String>()
    private var spokenTerminationIDs = Set<String>()
    private var activeAcknowledgement: PulseGuardianAcknowledgement?
    private var pcmQueue: [Data] = []
    private var pcmTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var isRunning = false
    private var isOpeningRealtime = false
    private var isNarrating = false
    private var wakeAvailable = false
    private var privateRouteWasPresent = false
    private var announcementsPausedForRoute = false

    public init(service: any PulseCallServing, realtime: any PulseRealtimeCalling, attention: PulseAttentionWebSocket, voice: any PulseVoiceControlling, wakeWord: any PulseWakeWordDetecting, hotWindow: TimeInterval = 5) {
        self.service = service
        self.realtime = realtime
        self.attention = attention
        self.voice = voice
        self.wakeWord = wakeWord
        self.hotWindow = hotWindow
        configureAudioCallbacks()
    }

    deinit { pcmTask?.cancel(); closeTask?.cancel() }

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
        await attention.start(onEvent: { [weak self] message in
            Task { @MainActor [weak self] in self?.receive(message) }
        }, onState: { [weak self] socketState in
            Task { @MainActor [weak self] in self?.receive(socketState) }
        })
        state = .guardianStandby
    }

    public func stop() {
        isRunning = false
        wakeWord.stop()
        Task { await attention.stop() }
        closeTask?.cancel(); closeTask = nil
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
        voice.setRouteChangedHandler { [weak self] in self?.routeChanged() }
    }

    private func receive(_ socketState: PulseAttentionWebSocket.State) {
        guard isRunning else { return }
        switch socketState {
        case .connected: if state == .attentionReconnecting { state = .guardianStandby }
        case .connecting, .reconnecting: state = .attentionReconnecting
        case .inactive:
            closeRealtime()
            wakeWord.stop()
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

    private func openRealtimeForActivation() {
        guard isRunning, !isOpeningRealtime else { return }
        isOpeningRealtime = true
        state = .waking
        Task { [weak self] in
            guard let self else { return }
            do {
                let credential = try await self.service.mintRealtimeClientSecret()
                guard self.isRunning else { return }
                let executor = PulseGenericToolExecutor(service: self.service)
                let owner = self
                let opened = try await self.realtime.beginCall(credential: credential, configuration: .init(), executor: executor, initialContext: "", onState: { [weak owner] event in
                    let value = owner
                    Task { @MainActor in value?.receive(event) }
                }, onText: { [weak owner] text in
                    let value = owner
                    Task { @MainActor in value?.onText?(text) }
                }, onAudio: { [weak owner] pcm in
                    let value = owner
                    Task { @MainActor in value?.voice.playPCM16(pcm) }
                }, onBargeIn: { [weak owner] in
                    let value = owner
                    Task { @MainActor in value?.voice.flushPlayback() }
                })
                guard self.isRunning else { await opened.end(); return }
                self.call = opened
                self.isOpeningRealtime = false
                self.processQueue()
            } catch {
                self.isOpeningRealtime = false
                self.state = .failed
            }
        }
    }

    private func receive(_ realtimeState: PulseRealtimeCallState) {
        guard isRunning else { return }
        switch realtimeState {
        case .connecting: state = .waking
        case .responding: state = .speaking
        case .listening:
            if isNarrating { state = .draining }
            else { state = .listening; scheduleCloseAfterHotWindow() }
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
        wakeWord.stop()
        closeTask?.cancel(); closeTask = nil
        if call == nil { openRealtimeForActivation() } else { state = .listening }
    }

    private func receivePCM(_ pcm: Data) {
        guard isRunning else { return }
        wakeWord.appendPCM16(pcm)
        guard let call else { return }
        // Any owner speech extends the hot window; never tear down a socket in
        // the middle of a turn merely because the previous response was quiet.
        closeTask?.cancel()
        closeTask = nil
        if pcmQueue.count == 8 { pcmQueue.removeFirst() }
        pcmQueue.append(pcm)
        guard pcmTask == nil else { return }
        pcmTask = Task { [weak self] in
            guard let self else { return }
            while !self.pcmQueue.isEmpty, self.isRunning {
                let next = self.pcmQueue.removeFirst()
                do { try await call.appendPCM16(next) }
                catch { self.realtimeFailed(); break }
            }
            self.pcmTask = nil
        }
    }

    private func scheduleCloseAfterHotWindow() {
        guard call != nil, !isNarrating else { return }
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.hotWindow * 1_000_000_000))
            guard !Task.isCancelled, self.queue.isEmpty, !self.isNarrating else { return }
            self.closeRealtime()
            if self.isRunning && self.state != .inactive { self.state = .guardianStandby }
        }
    }

    private func closeRealtime() {
        closeTask?.cancel(); closeTask = nil
        let old = call; call = nil; isOpeningRealtime = false; isNarrating = false; activeAcknowledgement = nil
        pcmQueue.removeAll(); pcmTask?.cancel(); pcmTask = nil
        Task { await old?.end() }
    }

    private func temporarilyInterrupted() {
        guard isRunning else { return }
        state = .interrupted
        closeRealtime()
    }

    private func routeChanged() {
        let privateNow = voice.hasPrivateOutputRoute()
        if privateRouteWasPresent && !privateNow {
            // Never unexpectedly promote a locked-phone announcement to speaker.
            announcementsPausedForRoute = true
            closeRealtime()
            state = .guardianStandby
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
    }

    private func realtimeFailed() {
        closeRealtime()
        if isRunning && state != .inactive { state = .guardianStandby; processQueue() }
    }
}
