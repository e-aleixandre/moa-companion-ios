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
        /// Guardián was away. Never one announcement per item.
        case catchUp(id: UInt64, envelope: CatchUpEnvelope, terminationIDs: [String])

        var acknowledgement: PulseGuardianAcknowledgement? {
            switch self {
            case let .item(item): return .item(item.id)
            case let .termination(termination): return .termination(termination.id)
            case let .catchUp(_, _, terminationIDs): return terminationIDs.isEmpty ? nil : .terminations(terminationIDs)
            case .briefing, .recovered: return nil
            }
        }

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

    public init(service: any PulseCallServing, realtime: any PulseRealtimeCalling, attention: any PulseAttentionChanneling, voice: any PulseVoiceControlling, wakeWord: any PulseWakeWordDetecting, hotWindow: TimeInterval = 25, voiceReconnectDelay: @escaping @Sendable (Int) -> TimeInterval = { min(pow(2, Double(max(0, $0 - 1))), 8) }, voiceReconnectBudget: TimeInterval = 75, presence: any PulseGuardianPresenceStore = UserDefaultsPulseGuardianPresenceStore(), catchUpGapThreshold: TimeInterval = 120, presenceRefreshInterval: TimeInterval = 30, now: @escaping @Sendable () -> Date = { Date() }) {
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
        self.now = now
        configureAudioCallbacks()
    }

    deinit { pcmTask?.cancel(); closeTask?.cancel(); wakeRearmTask?.cancel(); voiceReconnectTask?.cancel(); presenceTask?.cancel() }

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
    }

    public func stop() {
        // A clean stop is the last moment the Guardián was really listening: a
        // catch-up must measure the absence from here, not from the last tick.
        recordPresenceIfListening()
        presenceTask?.cancel(); presenceTask = nil
        attentionConnected = false
        isRunning = false
        disarmWakeWord()
        Task { await attention.stop() }
        cancelVoiceReconnect()
        closeTask?.cancel(); closeTask = nil
        socketGeneration &+= 1
        pcmTask?.cancel(); pcmTask = nil; pcmQueue.removeAll()
        let old = call; call = nil; isOpeningRealtime = false; isNarrating = false; isResponding = false; isPlayingResponseAudio = false
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
        presence.recordListening(at: now())
    }

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
            Task { await attention.ackTermination(terminationID: termination.id) }
        }
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
            Task { await attention.ackTermination(terminationID: termination.id) }
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
                        value.notePulseAudio()
                        value.isPlayingResponseAudio = true
                        value.voice.playPCM16(pcm, completion: played)
                    }
                }, onBargeIn: { [weak owner] in
                    let value = owner
                    Task { @MainActor in
                        guard let value, value.socketGeneration == generation else { return }
                        value.voice.flushPlayback()
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
        case .responding:
            isResponding = true
            closeTask?.cancel(); closeTask = nil
            state = .speaking
        case .listening:
            isResponding = false
            if isNarrating { state = .draining }
            else if !isPlayingResponseAudio {
                // response.done ends the server's generation before the last
                // PCM has finished sounding on the device.
                state = .listening
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
            if !isNarrating, queue.isEmpty { scheduleCloseAfterHotWindow() }
        case .ended, .failed: realtimeFailed()
        }
    }

    private func playbackDrained() {
        guard isRunning else { return }
        if !isNarrating {
            guard isPlayingResponseAudio else { return }
            isPlayingResponseAudio = false
            if !isResponding, !ownerSpeaking {
                state = .listening
                if queue.isEmpty { scheduleCloseAfterHotWindow() }
            }
            return
        }
        state = .draining
        let acknowledgement = activeAcknowledgement
        activeAcknowledgement = nil
        isNarrating = false
        switch acknowledgement {
        case let .item(id): Task { await attention.ack(itemID: id) }
        case let .termination(id):
            spokenTerminationIDs.insert(id)
            Task { await attention.ackTermination(terminationID: id) }
        case let .terminations(ids):
            // The catch-up was actually spoken: let the server purge every run it
            // covered. Pending asks/permissions are NOT resolved here — they keep
            // their own flow.
            for id in ids {
                spokenTerminationIDs.insert(id)
                terminationsAwaitingCatchUp.remove(id)
                Task { await attention.ackTermination(terminationID: id) }
            }
        case nil: break
        }
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
        // A catch-up cut mid-narration will never be acked by playback: release
        // its hold so the next connection can at least purge those runs quietly
        // instead of keeping them forever.
        if case let .terminations(ids)? = activeAcknowledgement { terminationsAwaitingCatchUp.subtract(ids) }
        let old = call; call = nil; isOpeningRealtime = false; isNarrating = false; isResponding = false; isPlayingResponseAudio = false; ownerSpeaking = false; activeAcknowledgement = nil
        bufferingOwnerSpeech = false; warmupBuffer.removeAll()
        pcmQueue.removeAll(); pcmTask?.cancel(); pcmTask = nil
        Task { await old?.end() }
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
