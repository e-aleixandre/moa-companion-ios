import Foundation
import os

public enum PulseGuardianState: Equatable, Sendable {
    case idle, guardianStarting, guardianStandby, waking, listening, speaking, resolving, draining, attentionReconnecting, conversationReconnecting, conversationLost, interrupted, inactive, failed

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
        case .conversationReconnecting: "Reconectando conversación"
        case .conversationLost: "Conversación cortada"
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
    public typealias AudioLevelHandler = @Sendable (Float) -> Void

    private enum Pending: Sendable {
        case item(PulseAttentionItem)
        case briefing(PulseBriefing)
        case termination(PulseRunTermination)
        /// A recovered conversation: Pulse takes the floor briefly to tell the
        /// owner it is back. The associated value only keeps it unique.
        case recovered(UInt64)
        /// One single spoken summary of everything that happened while the
        /// Guardián was away. Never one announcement per item. It carries the
        /// terminations it claimed so an interrupted briefing can be put back
        /// exactly as it was instead of being acked without having been heard.
        case catchUp(id: UInt64, envelope: CatchUpEnvelope, terminationIDs: [String])

        var acknowledgement: PulseGuardianAcknowledgement? {
            switch self {
            case let .item(item): return .item(item.id)
            case let .termination(termination): return .termination(termination.id)
            case let .catchUp(_, _, terminationIDs): return terminationIDs.isEmpty ? nil : .terminations(terminationIDs)
            case .briefing, .recovered: return nil
            }
        }

        var isCatchUp: Bool { if case .catchUp = self { return true }; return false }
        var isRecovered: Bool { if case .recovered = self { return true }; return false }

        func payload() throws -> String {
            let data: Data
            switch self {
            case let .item(item): data = try JSONEncoder.moaOps.encode(ItemEnvelope(item: item))
            case let .briefing(briefing): data = try JSONEncoder.moaOps.encode(BriefingEnvelope(briefing: briefing))
            case let .termination(termination): data = try JSONEncoder.moaOps.encode(TerminationEnvelope(termination: termination))
            case .recovered: data = try JSONEncoder.moaOps.encode(RecoveredEnvelope())
            case let .catchUp(_, envelope, _): data = try JSONEncoder.moaOps.encode(envelope)
            }
            return String(decoding: data, as: UTF8.self)
        }

        var deduplicationID: String {
            switch self {
            case let .item(item): return "item:\(item.id)"
            case let .termination(termination): return "termination:\(termination.id)"
            case let .briefing(briefing): return "briefing:\(briefing.sessionID):\(briefing.kind.rawValue):\(briefing.spoken)"
            case let .recovered(id): return "recovered:\(id)"
            case let .catchUp(id, _, _): return "catch_up:\(id)"
            }
        }
    }

    private enum PulseGuardianAcknowledgement: Sendable { case item(String), termination(String), terminations([String]) }
    private struct ItemEnvelope: Encodable { let type = "attention"; let item: PulseAttentionItem }
    private struct BriefingEnvelope: Encodable { let type = "briefing"; let briefing: PulseBriefing }
    private struct TerminationEnvelope: Encodable { let type = "termination"; let termination: PulseRunTermination }
    /// Data-only envelope: it states a fact (the previous conversation dropped),
    /// never an instruction, exactly like every other guardian event.
    private struct RecoveredEnvelope: Encodable {
        let type = "reconexion"
        let reason = "perdida_de_red"
        let spoken = "La conversación anterior se cortó por pérdida de red y acaba de restablecerse."
    }

    /// Data-only envelope for the catch-up: facts about what happened during the
    /// absence, plus how long that absence was. Every nested string comes from
    /// the server and is untrusted data, exactly like the other envelopes.
    struct CatchUpEnvelope: Encodable, Sendable {
        struct Finished: Encodable, Sendable {
            let sesion: String
            let estado: String
            let spoken: String
            let resumen: String
        }

        struct Pendiente: Encodable, Sendable {
            let sesion: String
            let tipo: String
            let spoken: String
        }

        let type = "catch_up"
        let spoken = "Esto ha pasado mientras el propietario no estaba escuchando."
        let hueco: String
        let huecoSegundos: Int
        let terminaciones: [Finished]
        let pendientes: [Pendiente]

        enum CodingKeys: String, CodingKey {
            case type, spoken, hueco, terminaciones, pendientes
            case huecoSegundos = "hueco_segundos"
        }
    }

    public private(set) var state: PulseGuardianState = .idle {
        didSet {
            onState?(state)
            // On leaving the voiced states the visual level returns to zero;
            // otherwise the last emitted level would stay frozen in the UI
            // (halo lit while the orb is asleep).
            switch state {
            case .listening, .waking, .speaking, .draining, .resolving: break
            default: onAudioLevel?(0)
            }
        }
    }
    public private(set) var snapshot = PulseGuardianSnapshot() { didSet { onSnapshot?(snapshot) } }
    public var onState: StateHandler?
    public var onSnapshot: SnapshotHandler?
    public var onText: TextHandler?
    /// 0..1 level of the "relevant" voice for the current state: the owner's
    /// while Pulse listens, Pulse's while it speaks. A single channel so the
    /// UI doesn't have to duplicate the logic of who is sounding.
    public var onAudioLevel: AudioLevelHandler?

    private let service: any PulseCallServing
    private let realtime: any PulseRealtimeCalling
    private let attention: any PulseAttentionChanneling
    private let voice: any PulseVoiceControlling
    private let wakeWord: any PulseWakeWordDetecting
    private let hotWindow: TimeInterval
    private let voiceReconnectDelay: @Sendable (Int) -> TimeInterval
    private let voiceReconnectBudget: TimeInterval
    private let presence: any PulseGuardianPresenceStore
    private let catchUpGapThreshold: TimeInterval
    private let presenceRefreshInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var call: (any PulseRealtimeCallControlling)?
    private var queue: [Pending] = []
    private var queuedIDs = Set<String>()
    private var spokenTerminationIDs = Set<String>()
    // Items (asks/permissions) already announced to the owner. Survives socket
    // reconnects so a blocking ask that arrived while away is announced once,
    // but a mere reconnection never re-reads the whole pending backlog.
    private var announcedItemIDs = Set<String>()
    // The narration that currently holds the floor, kept whole rather than just
    // its acknowledgement: a socket dying mid-briefing has to put it back in the
    // queue instead of losing it and acking it behind the owner's back.
    private var activePending: Pending?
    private var activeAcknowledgement: PulseGuardianAcknowledgement?
    // A narration is only over when the server closed the response it opened
    // (`response.created` -> `response.done`) AND its audio finished sounding.
    // Either signal alone is a lie: under jitter the local playback queue
    // empties between deltas, in the middle of a sentence, and a `response.done`
    // that was never preceded by a `response.created` belongs to something else.
    private var narrationResponseStarted = false
    private var narrationResponseDone = false
    // Terminations already acknowledged to the server. An `init` arriving before
    // the server purges them must not ack them a second time.
    private var ackedTerminationIDs = Set<String>()
    // How many times each announcement was already presented to the owner. The
    // first attempt counts: retrying is right, retrying forever is a loop, and a
    // session that keeps dying would reopen the expensive socket for the same
    // briefing indefinitely.
    private var narrationPresentations: [String: Int] = [:]
    // Total times one announcement may be presented, first attempt included.
    private let narrationPresentationLimit = 3
    // Last resort for a session that hangs while it holds the floor: without it
    // `isNarrating` / `isPlayingResponseAudio` would stay true forever, and a
    // stuck flag means a Guardián that never speaks nor closes its socket again.
    private enum StallKind: Sendable { case narration, playback }
    private var stallWatchdog: Task<Void, Never>?
    private var stallWatchdogKind: StallKind?
    private let narrationTimeout: TimeInterval
    private let playbackTimeout: TimeInterval
    // Bumped by every audio chunk of the response in flight. It is what tells a
    // dead hang from an answer that is merely long: a watchdog whose window saw
    // new audio is looking at a live session, not at a stuck one.
    private var responseAudioTicks: UInt64 = 0
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
    // A dropped conversation is retried instead of dying silently: the owner is
    // usually walking around and coverage comes back within seconds.
    private var voiceReconnectTask: Task<Void, Never>?
    private var isReconnectingVoice = false
    private var voiceReconnectAttempt = 0
    private var voiceReconnectDeadline: Date?
    private var recoveredCounter: UInt64 = 0
    private var catchUpCounter: UInt64 = 0
    // Terminations covered by a catch-up that has not finished playing yet: a
    // reconnection arriving mid-narration must not ack them behind its back.
    private var terminationsAwaitingCatchUp = Set<String>()
    private var attentionConnected = false
    private var presenceTask: Task<Void, Never>?
    private var isRunning = false
    private var isOpeningRealtime = false
    private var isNarrating = false
    private var isResponding = false
    private var isPlayingResponseAudio = false
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

    public init(service: any PulseCallServing, realtime: any PulseRealtimeCalling, attention: any PulseAttentionChanneling, voice: any PulseVoiceControlling, wakeWord: any PulseWakeWordDetecting, hotWindow: TimeInterval = 25, voiceReconnectDelay: @escaping @Sendable (Int) -> TimeInterval = { min(pow(2, Double(max(0, $0 - 1))), 8) }, voiceReconnectBudget: TimeInterval = 75, presence: any PulseGuardianPresenceStore = UserDefaultsPulseGuardianPresenceStore(), catchUpGapThreshold: TimeInterval = 120, presenceRefreshInterval: TimeInterval = 30, narrationTimeout: TimeInterval = 90, playbackTimeout: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.realtime = realtime
        self.attention = attention
        self.voice = voice
        self.wakeWord = wakeWord
        self.hotWindow = hotWindow
        self.voiceReconnectDelay = voiceReconnectDelay
        self.voiceReconnectBudget = voiceReconnectBudget
        self.presence = presence
        self.catchUpGapThreshold = catchUpGapThreshold
        self.presenceRefreshInterval = presenceRefreshInterval
        self.narrationTimeout = narrationTimeout
        self.playbackTimeout = playbackTimeout
        self.now = now
        configureAudioCallbacks()
    }

    deinit { pcmTask?.cancel(); closeTask?.cancel(); wakeRearmTask?.cancel(); voiceReconnectTask?.cancel(); presenceTask?.cancel(); stallWatchdog?.cancel() }

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
        startPresenceHeartbeat()
        state = .guardianStandby
        // A previous stop() may have put an unheard announcement back in the
        // queue. Nothing else would pick it up: the dedup marks keep a fresh
        // `init` from enqueueing it again, so without this drain it would wait
        // forever.
        processQueue()
    }

    public func stop() {
        // A clean stop is the last moment the Guardián was really listening: a
        // catch-up must measure the absence from here, not from the last tick.
        // Unconditional on purpose — this runs while the app is demonstrably
        // alive, so it is never the suspicious jump `recordPresenceIfListening`
        // guards against.
        if isRunning, attentionConnected { presence.recordListening(at: now()) }
        presenceTask?.cancel(); presenceTask = nil
        attentionConnected = false
        isRunning = false
        disarmWakeWord()
        Task { await attention.stop() }
        cancelVoiceReconnect()
        closeTask?.cancel(); closeTask = nil
        socketGeneration &+= 1
        pcmTask?.cancel(); pcmTask = nil; pcmQueue.removeAll()
        // A briefing the owner never got to hear goes back to the queue, so a
        // later start() tells it instead of acking it silently.
        requeueInterruptedNarration()
        let old = call; call = nil; isOpeningRealtime = false; isNarrating = false; isResponding = false; isPlayingResponseAudio = false
        narrationResponseStarted = false; narrationResponseDone = false
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
        voice.onInputLevel = { [weak self] level in self?.receiveAudioLevel(level, fromOutput: false) }
        voice.onOutputLevel = { [weak self] level in self?.receiveAudioLevel(level, fromOutput: true) }
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
        case .connected:
            // Presence is only recorded once the authoritative `init` arrives:
            // a bare connection has not caught up on anything yet, and writing
            // here would erase the very gap the briefing measures.
            if state == .attentionReconnecting { state = .guardianStandby }
            // Anything requeued while the socket was down (or while another
            // device held the Guardián) gets its consumer back here.
            processQueue()
        // A dropped voice conversation is the more specific problem: the cheap
        // attention socket reconnecting on its own must not mask it. A lost
        // conversation stays visible until the owner starts a new one (wake word
        // / Hablar) or a fresh announcement opens a session.
        case .connecting, .reconnecting:
            recordPresenceIfListening()
            attentionConnected = false
            if !isReconnectingVoice, state != .conversationLost { state = .attentionReconnecting }
        case .inactive:
            recordPresenceIfListening()
            attentionConnected = false
            cancelVoiceReconnect()
            closeRealtime()
            disarmWakeWord()
            state = .inactive
        case .failed:
            recordPresenceIfListening()
            attentionConnected = false
            state = .failed
        case .stopped:
            recordPresenceIfListening()
            attentionConnected = false
        }
    }

    /// Keeps "the Guardián was listening until now" fresh while the attention
    /// socket is up, so an absence is measured from the moment it really ended
    /// (app killed, suspended by iOS) and not from the last connect.
    private func startPresenceHeartbeat() {
        presenceTask?.cancel()
        guard presenceRefreshInterval > 0 else { return }
        let interval = presenceRefreshInterval
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.recordPresenceIfListening()
            }
        }
    }

    private func recordPresenceIfListening() {
        guard isRunning, attentionConnected else { return }
        let moment = now()
        guard let last = presence.lastListeningAt() else { presence.recordListening(at: moment); return }
        let elapsed = moment.timeIntervalSince(last)
        // Presence may only advance in small monotonic steps. A write landing far
        // later than the heartbeat schedule means the process was frozen in
        // between (iOS suspended the app, the device slept): that jump IS the
        // absence, so the old timestamp is kept instead of erasing the very gap
        // the catch-up measures. Ordering alone cannot fix this — both an overdue
        // heartbeat tick and the socket's own `reconnecting` callback are
        // delivered after the fact, while `attentionConnected` is still true.
        // The `init` handler is the only place that resets presence, and only
        // after having measured the gap.
        guard elapsed >= 0, elapsed < presenceStaleJump else {
            log.info("presence tick ignored: \(String(format: "%.0f", elapsed), privacy: .public)s jump looks like a suspension")
            return
        }
        presence.recordListening(at: moment)
    }

    /// How large a jump between two presence writes still counts as "we were
    /// here the whole time": two heartbeats absorb normal scheduling delay. With
    /// no heartbeat there is no independent evidence of liveness to compare
    /// against, so nothing is rejected.
    private var presenceStaleJump: TimeInterval { presenceRefreshInterval > 0 ? presenceRefreshInterval * 2 : .infinity }

    private func receive(_ message: PulseAttentionServerMessage) {
        guard isRunning else { return }
        switch message.type {
        case .initial:
            // The only legal reconciliation is replacement, never a merge.
            snapshot.items = message.items ?? []
            snapshot.sessions = message.sessions ?? []
            snapshot.terminations = message.terminations ?? []
            // A short socket reconnection must not narrate the backlog; a real
            // absence must. The gap since the Guardián last listened is what
            // tells them apart. No stored timestamp means first launch/pairing:
            // there is no absence to catch up on.
            let connectedAt = now()
            let gap = presence.lastListeningAt().map { connectedAt.timeIntervalSince($0) }
            attentionConnected = true
            presence.recordListening(at: connectedAt)
            if let gap, gap > catchUpGapThreshold {
                announceCatchUp(gap: gap)
            } else {
                // Terminations are informational: on a short reconnection mark
                // them seen silently so the server stops resending them.
                markTerminationsSeenSilently()
            }
            // Only asks/permissions block a worker, so those are announced, and
            // only the first time (announcedItemIDs) so a mere reconnection never
            // repeats one the owner already heard. Anything folded into the
            // catch-up is already marked announced and skipped here.
            for item in snapshot.items where !announcedItemIDs.contains(item.id) {
                announcedItemIDs.insert(item.id)
                enqueue(.item(item))
            }
            // An announcement put back by a previous teardown is never enqueued
            // again here (its dedup marks are kept on purpose), so the fresh
            // authoritative snapshot is also the moment to drain whatever is
            // already waiting.
            processQueue()
        case .attention:
            if let item = message.item {
                snapshot.items.removeAll { $0.id == item.id }
                snapshot.items.append(item)
                // A live ask/permission is a genuinely new event: announce it and
                // remember it so a later reconnection's initial snapshot doesn't
                // repeat it.
                announcedItemIDs.insert(item.id)
                enqueue(.item(item))
            }
        case .itemUpdate:
            if let item = message.item {
                snapshot.items.removeAll { $0.id == item.id }
                if item.state != "resolved" { snapshot.items.append(item) }
                else { announcedItemIDs.remove(item.id) }
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

    private func markTerminationsSeenSilently() {
        for termination in snapshot.terminations where !terminationsAwaitingCatchUp.contains(termination.id) {
            spokenTerminationIDs.insert(termination.id)
            acknowledgeTermination(termination.id)
        }
    }

    /// Single door for `ack_termination`: the server may still be resending a
    /// run it has not purged yet, and an ack per `init` would be pure noise.
    private func acknowledgeTermination(_ id: String) {
        guard ackedTerminationIDs.insert(id).inserted else { return }
        Task { await attention.ackTermination(terminationID: id) }
    }

    /// Composes the single spoken catch-up for a real absence. Terminations and
    /// still-pending asks/permissions travel together in one envelope: the model
    /// writes the summary, the coordinator only supplies the facts.
    private func announceCatchUp(gap: TimeInterval) {
        let terminations = snapshot.terminations.filter { !spokenTerminationIDs.contains($0.id) }
        let pendingItems = snapshot.items.filter { !announcedItemIDs.contains($0.id) }
        // Already-narrated terminations still in the backlog are acked anyway so
        // the server purges them.
        for termination in snapshot.terminations where spokenTerminationIDs.contains(termination.id) && !terminationsAwaitingCatchUp.contains(termination.id) {
            acknowledgeTermination(termination.id)
        }
        // Nothing happened while away: never pay for a Realtime session to say so.
        guard !terminations.isEmpty || !pendingItems.isEmpty else {
            log.info("catch-up skipped: nothing to report after \(String(format: "%.0f", gap), privacy: .public)s away")
            return
        }
        // Marked before the narration so a second init during playback cannot
        // duplicate the announcement, neither as a catch-up nor item by item.
        for termination in terminations { spokenTerminationIDs.insert(termination.id) }
        for item in pendingItems { announcedItemIDs.insert(item.id) }
        catchUpCounter &+= 1
        let terminationIDs = terminations.map(\.id)
        terminationsAwaitingCatchUp.formUnion(terminationIDs)
        let envelope = Self.catchUpEnvelope(gap: gap, terminations: terminations, pendingItems: pendingItems, sessions: snapshot.sessions)
        enqueue(.catchUp(id: catchUpCounter, envelope: envelope, terminationIDs: terminationIDs))
    }

    static func catchUpEnvelope(gap: TimeInterval, terminations: [PulseRunTermination], pendingItems: [PulseAttentionItem], sessions: [PulseSessionBrief]) -> CatchUpEnvelope {
        let stateBySession = Dictionary(sessions.map { ($0.sessionID, $0.state) }, uniquingKeysWith: { first, _ in first })
        return CatchUpEnvelope(
            hueco: describeGap(gap),
            huecoSegundos: Int(gap.rounded()),
            terminaciones: terminations.map {
                .init(sesion: $0.alias, estado: stateBySession[$0.sessionID] ?? "desconocido", spoken: $0.spoken, resumen: $0.summary)
            },
            pendientes: pendingItems.map { .init(sesion: $0.alias, tipo: $0.kind.rawValue, spoken: $0.spoken) }
        )
    }

    /// Approximate, spoken-friendly duration: the owner cares about "un rato",
    /// not about seconds.
    static func describeGap(_ gap: TimeInterval) -> String {
        let minutes = Int((gap / 60).rounded())
        if minutes < 60 { return "unos \(max(1, minutes)) minutos" }
        let hours = Int((gap / 3600).rounded())
        if hours < 24 { return hours == 1 ? "una hora" : "unas \(hours) horas" }
        let days = Int(gap / 86_400)
        return days == 1 ? "un día" : "\(days) días"
    }

    private func enqueue(_ pending: Pending) {
        // A catch-up and a "the conversation is back" are the same moment for the
        // owner, and hearing both in a row is two interventions for one event.
        // The catch-up wins: it already proves Pulse is back AND carries the
        // facts, while the recovery announcement carries none.
        if pending.isRecovered, hasPendingCatchUp {
            log.info("recovery announcement folded into the pending catch-up")
            processQueue()
            return
        }
        // A catch-up arriving while the recovery announcement is already being
        // told is deliberately NOT folded the other way round: the catch-up
        // carries the facts and must never be lost, and the recovery is one
        // short sentence that is already sounding. Cutting it mid-word would be
        // worse than hearing "he vuelto" immediately followed by the summary,
        // so the active one finishes and the catch-up takes the floor next.
        if pending.isCatchUp { dropQueuedRecoveryAnnouncements() }
        guard queuedIDs.insert(pending.deduplicationID).inserted else { return }
        queue.append(pending)
        processQueue()
    }

    private var hasPendingCatchUp: Bool {
        if activePending?.isCatchUp == true { return true }
        return queue.contains(where: \.isCatchUp)
    }

    private func dropQueuedRecoveryAnnouncements() {
        for pending in queue where pending.isRecovered { queuedIDs.remove(pending.deduplicationID) }
        queue.removeAll(where: \.isRecovered)
    }

    private func processQueue() {
        // `.inactive` means another device is the Guardián: announcing from here
        // would talk over it. Whatever is queued waits for this device to take
        // the floor back (a wake, a reclaim, or a fresh `init`).
        guard isRunning, state != .inactive, !announcementsPausedForRoute, !queue.isEmpty else { return }
        closeTask?.cancel(); closeTask = nil
        if call == nil {
            guard !isOpeningRealtime else { return }
            openRealtimeForActivation()
            return
        }
        guard !isNarrating else { return }
        // Never speak over a live turn: while the owner talks or a response is
        // still being generated/played, they own the floor. The announcement
        // stays queued and every drain point calls back here.
        guard !ownerSpeaking, !isResponding, !isPlayingResponseAudio else { return }
        let pending = queue.removeFirst()
        queuedIDs.remove(pending.deduplicationID)
        activePending = pending
        activeAcknowledgement = pending.acknowledgement
        isNarrating = true
        narrationResponseStarted = false
        narrationResponseDone = false
        armStallWatchdog(.narration)
        state = .speaking
        // Pin the narration to the socket that owns it: a narration failing late
        // belongs to a session that may already have been replaced by a
        // reconnection, and tearing down the recovered call would cut a
        // conversation that was just rescued.
        let narrating = call
        let generation = socketGeneration
        Task { [weak self] in
            guard let self else { return }
            do { try await narrating?.requestGuardianNarration(pending.payload()) }
            catch {
                guard self.socketGeneration == generation else { return }
                self.realtimeFailed()
            }
        }
    }

    /// Builds the `<estado_inicial_moa>` the prompt promises so Pulse can answer
    /// the first "¿qué pasa?" without cold tool calls. Untrusted snapshot text is
    /// framed against delimiter injection, preserving every character as data;
    /// this is anti-injection framing, never censorship.
    private func guardianInitialContext(recovered: Bool) -> String {
        Self.formatInitialContext(snapshot, recovered: recovered)
    }

    static func formatInitialContext(_ snapshot: PulseGuardianSnapshot, recovered: Bool = false) -> String {
        var lines: [String] = []
        // Tell the model why it is starting mid-conversation, so it does not
        // greet the owner as if this were a fresh activation.
        if recovered { lines.append("nota: la conversación de voz anterior se cortó por pérdida de red; el propietario puede continuar donde lo dejó.") }
        if !snapshot.sessions.isEmpty {
            lines.append("sesiones:")
            for session in snapshot.sessions {
                var parts = ["- \(session.alias): \(session.title) [\(session.state)]"]
                if let attempting = session.attempting, !attempting.isEmpty { parts.append("intenta: \(attempting)") }
                if let progress = session.progress, !progress.isEmpty { parts.append("va: \(progress)") }
                if let updated = session.updated { parts.append("brief actualizado: \(ISO8601DateFormatter.moaOps.string(from: updated))") }
                if session.pendingAsks > 0 { parts.append("\(session.pendingAsks) preguntas") }
                if session.pendingPerms > 0 { parts.append("\(session.pendingPerms) permisos") }
                if let activity = session.activity {
                    if activity.kind == "subagent" {
                        var current = "ahora: subagente"
                        if let model = activity.model, !model.isEmpty { current += " \(model)" }
                        if let detail = activity.detail, !detail.isEmpty { current += " — \(detail)" }
                        if let count = activity.count, count > 1 { current += " (\(count) activos)" }
                        parts.append(current)
                    } else if activity.kind == "tool" {
                        var current = "ahora: \(activity.tool ?? "herramienta")"
                        if let detail = activity.detail, !detail.isEmpty { current += " \(detail)" }
                        parts.append(current)
                    }
                }
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
        let recovering = isReconnectingVoice
        state = recovering ? .conversationReconnecting : .waking
        Task { [weak self] in
            guard let self else { return }
            do {
                let credential = try await self.service.mintRealtimeClientSecret()
                guard self.isRunning, self.socketGeneration == generation else { return }
                let executor = PulseGenericToolExecutor(service: self.service)
                let owner = self
                let initialContext = self.guardianInitialContext(recovered: recovering)
                let opened = try await self.realtime.beginCall(credential: credential, configuration: .init(), executor: executor, initialContext: initialContext, onState: { [weak owner] event in
                    let value = owner
                    Task { @MainActor in value?.receive(event, generation: generation) }
                }, onText: { [weak owner] text in
                    let value = owner
                    Task { @MainActor in
                        guard let value, value.socketGeneration == generation else { return }
                        value.onText?(text)
                    }
                }, onAudio: { [weak owner] pcm, played in
                    let value = owner
                    Task { @MainActor in
                        guard let value, value.socketGeneration == generation else { return }
                        value.noteResponseAudio()
                        value.voice.playPCM16(pcm, completion: played)
                    }
                }, onBargeIn: { [weak owner] in
                    let value = owner
                    Task { @MainActor in
                        guard let value, value.socketGeneration == generation else { return }
                        value.ownerBargedIn()
                    }
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
                self.finishVoiceReconnect()
                self.signalListeningReady()
                self.processQueue()
            } catch {
                guard self.socketGeneration == generation else { return }
                self.isOpeningRealtime = false
                // Minting a fresh client secret can fail for the same reason the
                // socket dropped (no coverage): keep retrying within the budget.
                if self.isReconnectingVoice { self.scheduleVoiceReconnect(); return }
                self.bufferingOwnerSpeech = false
                self.warmupBuffer.removeAll()
                // A retried announcement failing again must not overwrite the
                // notice the owner still needs to see: the conversation is lost,
                // which is the more specific truth.
                if self.state != .conversationLost { self.state = .failed }
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
        case .responding:
            isResponding = true
            if isNarrating {
                // The response that carries the announcement starts here. Any
                // `response.done` seen before this one closed something else.
                narrationResponseStarted = true
                narrationResponseDone = false
            }
            closeTask?.cancel(); closeTask = nil
            state = .speaking
        case .listening:
            isResponding = false
            if isNarrating {
                // response.done: the server finished generating the briefing.
                // The last PCM is usually still sounding on the device, so the
                // acknowledgement waits for the playback drain as well.
                if narrationResponseStarted { narrationResponseDone = true }
                state = .draining
                finishNarrationIfComplete()
            } else if !isPlayingResponseAudio {
                // response.done ends the server's generation before the last
                // PCM has finished sounding on the device.
                state = .listening
                processQueue()
                scheduleCloseAfterHotWindow()
            }
        case .speechStarted:
            // Real owner voice (server VAD): keep the call open through the turn.
            ownerSpeaking = true
            closeTask?.cancel(); closeTask = nil
            if !isNarrating { state = .listening }
        case .speechStopped:
            // Only genuine silence after real speech may start the close timer.
            ownerSpeaking = false
            if !isNarrating {
                // The owner's turn drained: an announcement that was waiting for
                // the floor can take it now.
                processQueue()
                if queue.isEmpty { scheduleCloseAfterHotWindow() }
            }
        case .ended, .failed: realtimeFailed()
        }
    }

    private func playbackDrained() {
        guard isRunning else { return }
        if !isNarrating {
            guard isPlayingResponseAudio else { return }
            isPlayingResponseAudio = false
            cancelStallWatchdog(.playback)
            if !isResponding, !ownerSpeaking {
                state = .listening
                processQueue()
                if queue.isEmpty { scheduleCloseAfterHotWindow() }
            }
            return
        }
        isPlayingResponseAudio = false
        state = .draining
        finishNarrationIfComplete()
    }

    /// More audio for the response in flight. Marking it here is what keeps a
    /// playback queue that momentarily empties between deltas from being read as
    /// the end of the announcement.
    private func noteResponseAudio() {
        notePulseAudio()
        isPlayingResponseAudio = true
        responseAudioTicks &+= 1
        // A non-narrated answer has no response-event contract to fall back on:
        // if its playback completion is lost, this watchdog is the only thing
        // that frees the queue and lets the hot window close again.
        if !isNarrating, stallWatchdogKind == nil { armStallWatchdog(.playback) }
    }

    /// The owner cut Pulse off mid-announcement. The flushed buffers never call
    /// back, so the narration would otherwise stay in flight forever: it is
    /// treated as delivered. Barging in is a conscious "I heard enough", and the
    /// provider already truncates the item to what actually sounded, so acking
    /// what the owner interrupted is honest rather than lossy.
    private func ownerBargedIn() {
        voice.flushPlayback()
        isPlayingResponseAudio = false
        cancelStallWatchdog(.playback)
        // The barge-in itself is owner speech; `speechStarted` follows right
        // after. Marking it now keeps the queue from grabbing the floor back.
        ownerSpeaking = true
        guard isNarrating else { return }
        finishNarration()
    }

    /// The announcement counts as delivered only once the server closed the
    /// response and no audio of it is still sounding. A response that produced
    /// no audio at all is complete as soon as `response.done` arrives.
    private func finishNarrationIfComplete() {
        guard isNarrating, narrationResponseStarted, narrationResponseDone, !isPlayingResponseAudio else { return }
        finishNarration()
    }

    /// The announcement is over for good: acknowledge what the owner heard and
    /// let the queue move on.
    private func finishNarration() {
        guard isNarrating else { return }
        cancelStallWatchdog()
        let acknowledgement = activeAcknowledgement
        activeAcknowledgement = nil
        if let pending = activePending { narrationPresentations[pending.deduplicationID] = nil }
        activePending = nil
        isNarrating = false
        narrationResponseStarted = false
        narrationResponseDone = false
        switch acknowledgement {
        case let .item(id): Task { await attention.ack(itemID: id) }
        case let .termination(id):
            spokenTerminationIDs.insert(id)
            acknowledgeTermination(id)
        case let .terminations(ids):
            // The catch-up was actually spoken: let the server purge every run it
            // covered. Pending asks/permissions are NOT resolved here — they keep
            // their own flow.
            for id in ids {
                spokenTerminationIDs.insert(id)
                terminationsAwaitingCatchUp.remove(id)
                acknowledgeTermination(id)
            }
        case nil: break
        }
        processQueue()
        if queue.isEmpty { scheduleCloseAfterHotWindow() }
    }

    /// Arms the single stall watchdog. It guards whoever holds the floor: the
    /// announcement in flight, or the playback of an answer the owner asked for.
    private func armStallWatchdog(_ kind: StallKind) {
        stallWatchdog?.cancel()
        stallWatchdogKind = kind
        let generation = socketGeneration
        let audioMark = responseAudioTicks
        let timeout = kind == .narration ? narrationTimeout : playbackTimeout
        stallWatchdog = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, self.isRunning, self.socketGeneration == generation else { return }
            self.stallWatchdogFired(kind, audioMark: audioMark)
        }
    }

    private func cancelStallWatchdog(_ kind: StallKind? = nil) {
        if let kind, stallWatchdogKind != kind { return }
        stallWatchdog?.cancel(); stallWatchdog = nil; stallWatchdogKind = nil
    }

    /// The floor has been held for too long. Nothing here may acknowledge
    /// anything: a timeout is not evidence that the owner heard the briefing,
    /// so a stuck announcement is treated exactly like an interrupted one.
    private func stallWatchdogFired(_ kind: StallKind, audioMark: UInt64) {
        switch kind {
        case .narration: guard isNarrating else { return }
        case .playback: guard isPlayingResponseAudio, !isNarrating else { return }
        }
        // A long answer is still a live answer: audio that kept arriving during
        // the window proves the session is producing, and cutting it would kill
        // a healthy response mid-sentence.
        guard responseAudioTicks == audioMark else {
            log.info("stall watchdog rearmed: the response is long but still producing audio")
            armStallWatchdog(kind)
            return
        }
        stallWatchdog = nil
        stallWatchdogKind = nil
        switch kind {
        case .narration where narrationResponseStarted && narrationResponseDone:
            // The server did close the whole response and its audio was handed
            // to the device: the only thing missing is the drain completion, so
            // this is a lost callback, not an undelivered briefing. Finishing it
            // acks something the owner did hear.
            log.info("narration watchdog fired: the playback drain of a completed response never arrived")
            isPlayingResponseAudio = false
            finishNarration()
            return
        case .narration:
            log.info("narration watchdog fired: stuck without completing, put back instead of acked")
            // Requeue honours the presentation limit, so a briefing that keeps
            // hanging is eventually dropped instead of looping forever.
            requeueInterruptedNarration()
            isNarrating = false
            narrationResponseStarted = false
            narrationResponseDone = false
            // The turn is declared dead: leaving `isResponding` pinned by a
            // `response.created` whose `response.done` never came would keep the
            // queue blocked just as hard as the narration flag did.
            isResponding = false
        case .playback:
            log.info("playback watchdog fired: the drain completion never arrived")
        }
        // Whatever the cause, the playback flag must not survive the stall: it
        // gates both `processQueue()` and the hot window.
        isPlayingResponseAudio = false
        if call != nil, !isResponding, !ownerSpeaking { state = .listening }
        processQueue()
        if queue.isEmpty { scheduleCloseAfterHotWindow() }
    }

    private func wakeFromOwner() {
        guard isRunning, state != .inactive else { return }
        disarmWakeWord()
        closeTask?.cancel(); closeTask = nil
        // Asking for Pulse while a dropped conversation is being retried means
        // "try now": skip the remaining backoff instead of opening a second socket.
        if isReconnectingVoice {
            guard !isOpeningRealtime else { return }
            voiceReconnectTask?.cancel(); voiceReconnectTask = nil
            openRealtimeForActivation()
            return
        }
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
        guard isRunning, wakeAvailable, !wakeWordActive, state != .inactive, state != .idle else {
            log.info("wake rearm skipped: running=\(self.isRunning, privacy: .public) avail=\(self.wakeAvailable, privacy: .public) active=\(self.wakeWordActive, privacy: .public) state=\(String(describing: self.state), privacy: .public)")
            return
        }
        if wakeRearmTask != nil {
            if wakeRearmTaskGeneration != wakeWordGeneration { wakeRearmPending = true }
            return
        }
        let generation = wakeWordGeneration
        wakeRearmTaskGeneration = generation
        log.info("wake rearm start gen=\(generation, privacy: .public)")
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
            self.log.info("wake rearm done gen=\(generation, privacy: .public) started=\(started, privacy: .public)")
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

    /// Picks the relevant level based on who has "the floor". While Pulse
    /// audio is playing, the output rules (the mic would pick up the echo of
    /// its own voice through the speaker); in the other voiced states, the mic.
    private func receiveAudioLevel(_ level: Float, fromOutput: Bool) {
        guard isRunning else { return }
        let outputHasFloor = isNarrating || isResponding || isPlayingResponseAudio
        if fromOutput {
            guard outputHasFloor else { return }
            onAudioLevel?(level)
        } else {
            guard !outputHasFloor else { return }
            switch state {
            case .listening, .waking: onAudioLevel?(level)
            default: break
            }
        }
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
        guard call != nil, !isNarrating, !isResponding, !isPlayingResponseAudio, !ownerSpeaking else { return }
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.hotWindow * 1_000_000_000))
            guard !Task.isCancelled, self.queue.isEmpty, !self.isNarrating, !self.isResponding, !self.isPlayingResponseAudio, !self.ownerSpeaking else { return }
            self.cancelVoiceReconnect()
            self.closeRealtime()
            if self.isRunning && self.state != .inactive { self.state = .guardianStandby; self.rearmWakeWord() }
        }
    }

    private func closeRealtime() {
        closeTask?.cancel(); closeTask = nil
        socketGeneration &+= 1
        requeueInterruptedNarration()
        let old = call; call = nil; isOpeningRealtime = false; isNarrating = false; isResponding = false; isPlayingResponseAudio = false; ownerSpeaking = false; activeAcknowledgement = nil
        narrationResponseStarted = false; narrationResponseDone = false
        bufferingOwnerSpeech = false; warmupBuffer.removeAll()
        pcmQueue.removeAll(); pcmTask?.cancel(); pcmTask = nil
        Task { await old?.end() }
    }

    /// A narration cut before it was acknowledged was never heard by the owner:
    /// it goes back to the head of the queue so the next session retries it.
    /// Its dedup marks (`spokenTerminationIDs`, `announcedItemIDs`) are kept on
    /// purpose so nothing is announced twice, and `terminationsAwaitingCatchUp`
    /// keeps shielding those runs from `markTerminationsSeenSilently()` — the
    /// briefing is retried, never acked silently.
    private func requeueInterruptedNarration() {
        cancelStallWatchdog()
        guard let pending = activePending else { return }
        activePending = nil
        activeAcknowledgement = nil
        // A stale "I'm back" is noise once the conversation has dropped again:
        // the next successful reconnection enqueues its own.
        guard !pending.isRecovered else { return }
        let id = pending.deduplicationID
        // The attempt that was just cut counts as one presentation; putting it
        // back only makes sense while the limit still allows another one.
        let presentations = (narrationPresentations[id] ?? 0) + 1
        guard presentations < narrationPresentationLimit else {
            narrationPresentations[id] = nil
            log.info("narration \(id, privacy: .public) dropped after \(presentations, privacy: .public) interrupted presentations")
            // Give up on telling it, but stop holding its runs hostage: the next
            // `init` may at least purge them silently.
            if case let .terminations(ids)? = pending.acknowledgement { terminationsAwaitingCatchUp.subtract(ids) }
            return
        }
        narrationPresentations[id] = presentations
        guard queuedIDs.insert(id).inserted else { return }
        // Front of the queue, and deliberately without calling processQueue():
        // the caller is in the middle of tearing the session down.
        queue.insert(pending, at: 0)
    }

    private func temporarilyInterrupted() {
        guard isRunning else { return }
        state = .interrupted
        cancelVoiceReconnect()
        closeRealtime()
    }

    private func captureResumed() {
        guard isRunning, state == .interrupted else { return }
        state = .guardianStandby
        rearmWakeWord()
        // The interruption closed the socket and put the announcement it was
        // telling back in the queue; audio works again, so it gets told now.
        processQueue()
    }

    private func routeChanged() {
        let privateNow = voice.hasPrivateOutputRoute()
        if privateRouteWasPresent && !privateNow {
            // Never unexpectedly promote a locked-phone announcement to speaker.
            announcementsPausedForRoute = true
            cancelVoiceReconnect()
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
        cancelVoiceReconnect()
        closeRealtime()
        state = .failed
        rearmWakeWord()
        // Deliberately no processQueue() here: local audio is broken, so any
        // announcement put back would only reopen the expensive socket to fail
        // again and burn its presentation budget. It waits for the next event
        // that proves the device can talk again (a wake, a fresh attention
        // event, or the attention socket reconnecting).
    }

    /// An anomalous end of a live Realtime session (socket error, transport
    /// failure). Normal closes — hot window, owner stop, server `inactive` — go
    /// through `closeRealtime()` and never land here.
    private func realtimeFailed() {
        let hadLiveSession = call != nil || isOpeningRealtime
        closeRealtime()
        guard isRunning, state != .inactive else { return }
        if hadLiveSession || isReconnectingVoice { scheduleVoiceReconnect(); return }
        state = .guardianStandby; rearmWakeWord(); processQueue()
    }

    /// Retries a dropped conversation with exponential backoff until the budget
    /// runs out. The owner's voice keeps being captured into the warmup buffer
    /// meanwhile, so whatever they say during the gap is not lost.
    private func scheduleVoiceReconnect() {
        guard isRunning, state != .inactive else { return }
        if !isReconnectingVoice {
            isReconnectingVoice = true
            voiceReconnectAttempt = 0
            voiceReconnectDeadline = Date().addingTimeInterval(voiceReconnectBudget)
        }
        bufferingOwnerSpeech = true
        voiceReconnectAttempt += 1
        let now = Date()
        let deadline = voiceReconnectDeadline ?? now
        guard now < deadline else { abandonVoiceReconnect(); return }
        // Spend the whole budget: when the full backoff would overshoot the
        // deadline, wait only what is left and make one last attempt right at it.
        // A mint/beginCall still in flight may finish slightly after the deadline;
        // that is accepted — an almost-recovered conversation is worth the extra
        // second, and every other close path cancels the retry anyway.
        let delay = min(max(0, voiceReconnectDelay(voiceReconnectAttempt)), deadline.timeIntervalSince(now))
        state = .conversationReconnecting
        log.info("voice reconnect attempt=\(self.voiceReconnectAttempt, privacy: .public) in \(String(format: "%.1f", delay), privacy: .public)s")
        voiceReconnectTask?.cancel()
        voiceReconnectTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self, self.isRunning, self.isReconnectingVoice, self.call == nil, self.state != .inactive else { return }
            self.voiceReconnectTask = nil
            self.openRealtimeForActivation()
        }
    }

    /// The retried socket is up: announce the recovery so the owner hears that
    /// their companion is back, and stop the retry machinery.
    private func finishVoiceReconnect() {
        guard isReconnectingVoice else { return }
        cancelVoiceReconnect()
        recoveredCounter &+= 1
        log.info("voice reconnect succeeded")
        enqueue(.recovered(recoveredCounter))
    }

    /// The budget is exhausted. Go back to a rearmed standby — but leave the
    /// drop visible in the UI instead of failing silently.
    private func abandonVoiceReconnect() {
        cancelVoiceReconnect()
        bufferingOwnerSpeech = false
        warmupBuffer.removeAll()
        guard isRunning, state != .inactive else { return }
        log.info("voice reconnect gave up")
        state = .conversationLost
        rearmWakeWord()
        processQueue()
    }

    private func cancelVoiceReconnect() {
        voiceReconnectTask?.cancel(); voiceReconnectTask = nil
        isReconnectingVoice = false
        voiceReconnectAttempt = 0
        voiceReconnectDeadline = nil
    }
}
