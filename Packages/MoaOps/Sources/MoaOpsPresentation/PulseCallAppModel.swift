import Foundation
import os
import SwiftUI
import MoaOpsCore

public enum PulseCallState: Equatable, Sendable {
    case disconnected
    case ready
    case listening
    case consulting
    case thinking
    case speaking
    case review
    case stale
    case offline
    case error

    public var spanishLabel: String {
        switch self {
        case .disconnected: "Sin emparejar"
        case .ready: "Lista"
        case .listening: "Escuchando"
        case .consulting: "Consultando Moa"
        case .thinking: "Pulse está pensando"
        case .speaking: "Pulse responde"
        case .review: "Revisión pendiente"
        case .stale: "Último estado conocido"
        case .offline: "Moa sin conexión"
        case .error: "Requiere atención"
        }
    }
}

public enum PulseCallRootDestination: Equatable, Sendable {
    case pairing
    case call
}

public struct PulseCallCaption: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let provenance: PulseProvenance
    public let isOwner: Bool

    public init(id: UUID = UUID(), text: String, provenance: PulseProvenance, isOwner: Bool = false) {
        self.id = id
        self.text = text
        self.provenance = provenance
        self.isOwner = isOwner
    }
}

@MainActor
public final class PulseCallAppModel: ObservableObject {
    private let voiceLog = Logger(subsystem: "com.ealeixandre.moa.pulse", category: "ptt")
    public typealias ServiceFactory = @Sendable (PulseDeviceRegistration) throws -> any PulseCallService
    public typealias PairingClaim = @Sendable (PulseServerConfiguration, PulsePairingPayload, String) async throws -> PulseDeviceRegistration
    public typealias ProviderFactory = @Sendable (
        any PulseCallService,
        any PulseSecureStore,
        PulseWriteGate,
        OpenAIRealtimeClient
    ) -> any PulseProviderResponding

    private enum TurnReservationPhase: Equatable {
        case provider
        case review(operationID: String)
        case confirming(operationID: String)
    }

    private struct TurnReservation: Equatable {
        let id: UUID
        var phase: TurnReservationPhase
    }

    private enum VoiceCaptureIntent: Equatable {
        case ownerTurn
        case review(operationID: String)
    }

    private struct ActiveVoiceCapture: Equatable {
        let token: PulseVoiceCaptureToken
        let intent: VoiceCaptureIntent
    }

    @Published public private(set) var hasPairedDevice = false
    @Published public private(set) var serverName = ""
    @Published public private(set) var state: PulseCallState = .disconnected
    @Published public private(set) var pttState: PulsePTTState = .idle
    @Published public private(set) var voiceUnavailable = false
    @Published public private(set) var isPairing = false
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var providerConfigured = false
    @Published public private(set) var privacyMode: PulsePrivacyMode = .automatic
    @Published public private(set) var snapshot: OpsPulse?
    @Published public private(set) var opsSnapshot: OpsSnapshot?
    @Published public private(set) var lastSuccessfulRefreshAt: Date?
    @Published public private(set) var hasFreshAuthoritativeProjection = false
    @Published public private(set) var operationsAreAvailable = false
    @Published public private(set) var brief: PulseDeterministicBrief?
    @Published public private(set) var captions: [PulseCallCaption] = []
    @Published public private(set) var pendingReview: PulsePendingReview?
    @Published public private(set) var lastReceipt: PulseOperationReceipt?
    @Published public private(set) var userMessage: String?
    @Published public var isMuted = false {
        didSet { voice.setMuted(isMuted) }
    }

    private let store: any PulseSecureStore
    private let serviceFactory: ServiceFactory
    private let pairingClaim: PairingClaim
    private let providerClient: OpenAIRealtimeClient
    private let providerFactory: ProviderFactory
    private let writeGate = PulseWriteGate()
    private let voice: any PulseVoiceControlling
    private let streamGraceInterval: TimeInterval
    private let streamOfflineInterval: TimeInterval
    private var service: (any PulseCallService)?
    private var updatesTask: Task<Void, Never>?
    private var streamFailureTask: Task<Void, Never>?
    private var streamFailureID: UUID?
    private var lastAuthoritativeBrief: PulseDeterministicBrief?
    private var liveOwnerCaptionID: UUID?
    private var isForeground = true
    private var isConfirmingReview = false
    private var nextVoiceCaptureGeneration: UInt64 = 0
    private var activeVoiceCapture: ActiveVoiceCapture?
    /// This lease is acquired before the first provider request and remains
    /// owned through an immutable review until cancel, failure, or receipt.
    private var turnReservation: TurnReservation?
    private var providerTask: Task<Void, Never>?
    private var audioMintTask: Task<Void, Never>?
    private var audioSendTask: Task<Void, Never>?
    private var realtimeAudioTurn: OpenAIRealtimeAudioTurn?
    private var isBargingIn = false
    private var endedAudioCapture: PulseVoiceCaptureToken?
    private var audioCommitCapture: PulseVoiceCaptureToken?
    private var preconnectPCM = PulsePTTPreconnectBuffer()

    public init(
        store: any PulseSecureStore = KeychainPulseSecureStore(),
        voice: (any PulseVoiceControlling)? = nil,
        providerClient: OpenAIRealtimeClient = .init(),
        providerFactory: @escaping ProviderFactory = { service, store, writeGate, providerClient in
            PulseProviderCoordinator(
                client: providerClient,
                issuer: (service as? any PulseRealtimeCredentialIssuing) ?? PulseUnavailableRealtimeCredentialIssuer(),
                executor: PulseMoaToolExecutor(service: service, writeGate: writeGate)
            )
        },
        streamGraceInterval: TimeInterval = 45,
        streamOfflineInterval: TimeInterval = 60,
        pairingClaim: @escaping PairingClaim = { configuration, payload, deviceLabel in
            try await PulsePairingClient().claim(configuration: configuration, payload: payload, deviceLabel: deviceLabel)
        },
        serviceFactory: @escaping ServiceFactory = { registration in try MoaPulseDeviceService(registration: registration) }
    ) {
        self.store = store
        self.voice = voice ?? NativePulseVoiceController()
        self.providerClient = providerClient
        self.providerFactory = providerFactory
        self.streamGraceInterval = max(0, streamGraceInterval)
        self.streamOfflineInterval = max(0, streamOfflineInterval)
        self.pairingClaim = pairingClaim
        self.serviceFactory = serviceFactory
        configureVoiceCallbacks()
        restoreRegistration()
    }

    deinit {
        updatesTask?.cancel()
        streamFailureTask?.cancel()
        providerTask?.cancel()
    }

    public var rootDestination: PulseCallRootDestination { hasPairedDevice ? .call : .pairing }

    public var freshnessLabel: String {
        guard let last = lastSuccessfulRefreshAt else { return "Sin estado reciente" }
        let age = max(0, Int(Date().timeIntervalSince(last)))
        if !hasFreshAuthoritativeProjection { return "Último estado conocido · hace \(relativeAge(age))" }
        return age < 10 ? "Actualizado ahora" : "Actualizado hace \(relativeAge(age))"
    }

    public var isPTTListening: Bool { pttState == .listening }

    public var isTurnBusy: Bool { turnReservation != nil }

    public var canUsePushToTalk: Bool {
        guard activeVoiceCapture == nil,
              hasPairedDevice,
              hasFreshAuthoritativeProjection,
              state != .offline,
              state != .error else { return false }
        if let review = pendingReview {
            return review.isCurrent() && operationsAreAvailable && reservationIsReview(for: review.operationID)
        }
        return turnReservation == nil
    }

    public var canConfirmCurrentReview: Bool {
        guard let review = pendingReview else { return false }
        return review.isCurrent()
            && operationsAreAvailable
            && hasFreshAuthoritativeProjection
            && !isConfirmingReview
            && activeVoiceCapture == nil
            && reservationIsReview(for: review.operationID)
    }

    public var providerAvailabilityLabel: String {
        providerConfigured
            ? "El dispositivo emparejado puede solicitar acceso efímero al proveedor al iniciar un turno"
            : "El acceso efímero al proveedor no está disponible. Comprueba Moa o vuelve a emparejar este iPhone."
    }

    public func setPrivacyMode(_ mode: PulsePrivacyMode) {
        privacyMode = mode
        if mode == .privateSaving {
            cancelActiveProviderTurn()
            invalidateActiveVoiceCapture()
            voice.stopAll()
            appendCaption("Modo Privado-ahorro: Pulse no envía audio ni texto a OpenAI; conserva solo el panorama local seguro.", provenance: .localFreshness)
        }
    }

    public func start() async {
        guard hasPairedDevice else { return }
        await refresh(narrating: true)
    }

    /// The pairing payload is parsed and claimed in this scope. It is never
    /// placed in a published property, a URL, a prompt, or ordinary storage.
    public func claim(baseURLText: String, pairingPayloadText: String, deviceLabel: String) async {
        do {
            let configuration = try PulseServerConfiguration(urlText: baseURLText)
            let payload = try PulsePairingPayload(parsing: pairingPayloadText)
            await claim(configuration: configuration, payload: payload, deviceLabel: deviceLabel)
        } catch {
            pairingFailed(error)
        }
    }

    /// QR pairing keeps its server URL and one-use payload in local call scope,
    /// then follows the same claim path as manual pairing.
    public func claimQRCode(_ value: String, deviceLabel: String) async {
        do {
            let envelope = try PulsePairingEnvelope(parsing: value)
            await claim(configuration: envelope.configuration, payload: envelope.payload, deviceLabel: deviceLabel)
        } catch {
            pairingFailed(error)
        }
    }

    private func claim(configuration: PulseServerConfiguration, payload: PulsePairingPayload, deviceLabel: String) async {
        isPairing = true
        defer { isPairing = false }
        do {
            let registration = try await pairingClaim(configuration, payload, deviceLabel)
            try store.saveDeviceRegistration(registration)
            service = try serviceFactory(registration)
            hasPairedDevice = true
            providerConfigured = service is any PulseRealtimeCredentialIssuing
            serverName = configuration.baseURL.host ?? "Moa"
            userMessage = nil
            state = .consulting
            await refresh(narrating: true)
        } catch {
            pairingFailed(error)
        }
    }

    private func pairingFailed(_ error: Error) {
        state = .disconnected
        userMessage = pairingMessage(for: error)
    }

    /// This revokes local access by deleting the only local device credential.
    /// Serve's remote device revoke endpoint is intentionally owner-cookie-only,
    /// so Pulse does not pretend a device credential can revoke itself.
    public func disconnectAndClearLocalCredential() {
        let active = service
        invalidateActiveVoiceCapture()
        service = nil
        updatesTask?.cancel()
        updatesTask = nil
        clearStreamFailure()
        try? store.clearDeviceRegistration()
        hasPairedDevice = false
        providerConfigured = false
        serverName = ""
        snapshot = nil
        opsSnapshot = nil
        brief = nil
        lastSuccessfulRefreshAt = nil
        hasFreshAuthoritativeProjection = false
        operationsAreAvailable = false
        pendingReview = nil
        isConfirmingReview = false
        releaseTurnReservation()
        lastReceipt = nil
        captions = []
        state = .disconnected
        userMessage = nil
        Task {
            await writeGate.setOnline(false)
            await active?.invalidate()
        }
    }

    public func refresh(narrating shouldNarrate: Bool = false) async {
        guard let service, hasPairedDevice, isForeground else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        state = .consulting
        defer { isRefreshing = false }
        do {
            async let loadedPulse = service.loadPulse()
            async let loadedSitrep = service.loadSitrep()
            let (pulse, sitrep) = try await (loadedPulse, loadedSitrep)
            snapshot = pulse
            lastSuccessfulRefreshAt = Date()
            let currentBrief = PulseBriefBuilder.make(pulse: pulse, sitrep: sitrep)
            brief = currentBrief
            lastAuthoritativeBrief = currentBrief
            hasFreshAuthoritativeProjection = true
            appendCaption(currentBrief.spoken, provenance: .moaObserved)
            state = pendingReview == nil ? .ready : .review
            userMessage = nil
            clearStreamFailure()
            await openWriteGate()
            startUpdates(using: service)
            if shouldNarrate { narrate(currentBrief.spoken) }
        } catch {
            await closeWriteGate()
            showOffline(error)
        }
    }

    public func beginPushToTalk() {
        // Per-turn sockets are discarded on barge-in. Do not begin a new
        // capture until the old socket and local playback are stopped.
        if let realtimeAudioTurn {
            guard !isBargingIn else { return }
            isBargingIn = true
            voice.stopSpeakingForCapture()
            Task { [weak self] in
                await realtimeAudioTurn.cancelForBargeIn()
                await MainActor.run {
                    guard let self else { return }
                    self.realtimeAudioTurn = nil
                    self.releaseTurnReservation()
                    self.isBargingIn = false
                    self.beginPushToTalk()
                }
            }
            return
        }
        guard !isBargingIn else { return }
        if activeVoiceCapture != nil {
            appendCaption("Pulse sigue cerrando la captura anterior. Espera antes de hablar de nuevo.", provenance: .localFreshness)
            return
        }
        if turnReservation != nil, pendingReview == nil {
            appendCaption("Pulse está atendiendo un turno. Espera a que termine antes de hablar de nuevo.", provenance: .localFreshness)
            return
        }
        guard canUsePushToTalk else { return }
        let intent: VoiceCaptureIntent
        if let review = pendingReview {
            guard reservationIsReview(for: review.operationID) else { return }
            intent = .review(operationID: review.operationID)
        } else {
            guard turnReservation == nil else {
                appendCaption("Pulse está atendiendo un turno. Espera a que termine antes de hablar de nuevo.", provenance: .localFreshness)
                return
            }
            intent = .ownerTurn
        }
        pttState = PulsePTTReducer.reduce(pttState, event: .press)
        guard pttState == .requestingPermission else { return }
        nextVoiceCaptureGeneration &+= 1
        let capture = ActiveVoiceCapture(token: .init(generation: nextVoiceCaptureGeneration), intent: intent)
        activeVoiceCapture = capture
        voiceLog.debug("ptt_press")
        if pendingReview == nil { state = .listening }
        voice.stopSpeakingForCapture()
        switch intent {
        case .ownerTurn: Task { await voice.beginPushToTalk(capture: capture.token) }
        case .review: Task { await voice.beginReviewConfirmation(capture: capture.token) }
        }
    }

    public func endPushToTalk() {
        guard let capture = activeVoiceCapture else { return }
        voiceLog.debug("ptt_release")
        voice.endPushToTalk(capture: capture.token)
        if capture.intent == .ownerTurn {
            endedAudioCapture = capture.token
            preconnectPCM.release()
            if let reservation = turnReservation {
                state = .thinking
                if realtimeAudioTurn != nil {
                    enqueueAudioCommit(capture: capture.token, reservationID: reservation.id)
                }
            }
        }
        pttState = PulsePTTReducer.reduce(pttState, event: .release)
        if pendingReview == nil, state == .listening { state = hasFreshAuthoritativeProjection ? .ready : .stale }
    }

    public func stop() {
        invalidateActiveVoiceCapture()
        voice.stopAll()
        pttState = .idle
        if pendingReview == nil { state = settledCallState() }
    }

    public func submitText(_ text: String) async { acceptOwnerTurn(text) }

    /// One path for a server-produced immutable review. It is internal so the
    /// presentation tests can exercise the same confirmation state as the
    /// provider/tool path without manufacturing a model response.
    func present(review: PulsePendingReview) {
        _ = present(review: review, replacing: nil)
    }

    @discardableResult
    private func present(review: PulsePendingReview, replacing reservationID: UUID?) -> Bool {
        guard pendingReview == nil else {
            appendCaption("Ya hay una revisión visible. Pulse no preparará otra acción.", provenance: .localFreshness)
            return false
        }
        if let reservation = turnReservation {
            guard reservation.phase == .provider,
                  reservationID == nil || reservation.id == reservationID else {
                appendCaption("Pulse sigue atendiendo una operación. No se puede sustituir su revisión.", provenance: .localFreshness)
                return false
            }
            turnReservation?.phase = .review(operationID: review.operationID)
        } else {
            guard reservationID == nil else { return false }
            turnReservation = .init(id: UUID(), phase: .review(operationID: review.operationID))
        }
        pendingReview = review
        isConfirmingReview = false
        state = .review
        return true
    }

    public func cancelReview() {
        guard !isConfirmingReview else { return }
        guard let review = pendingReview, reservationIsReview(for: review.operationID) else { return }
        invalidateActiveVoiceCapture()
        pendingReview = nil
        releaseTurnReservation()
        if hasPairedDevice { state = settledCallState() }
        appendCaption("Revisión cancelada en Pulse. Moa no recibió una confirmación.", provenance: .localFreshness)
    }

    public func confirmCurrentReview() async {
        guard let review = pendingReview, review.isCurrent(), hasPairedDevice else {
            pendingReview = nil
            releaseTurnReservation()
            state = settledCallState()
            return
        }
        guard operationsAreAvailable, hasFreshAuthoritativeProjection, let service, reservationIsReview(for: review.operationID) else {
            state = .review
            userMessage = "La revisión sigue visible, pero Moa no está actualizado. Pulse no confirmará ni encolará la acción hasta recibir un estado nuevo."
            return
        }
        guard !isConfirmingReview else { return }
        isConfirmingReview = true
        turnReservation?.phase = .confirming(operationID: review.operationID)
        defer { isConfirmingReview = false }
        state = .consulting
        do {
            let response = try await service.confirmOperation(review.operationID)
            guard let receipt = response.receipt else { throw PulseCallError.decoding }
            lastReceipt = receipt
            pendingReview = nil
            releaseTurnReservation()
            let narration = PulseOperationNarrator.receipt(receipt)
            appendCaption(narration, provenance: .moaObserved)
            state = settledCallState()
            narrate(narration)
        } catch {
            // The review remains visible for an explicit owner retry/status
            // check. Pulse does not queue or retry a confirm in the background.
            state = .review
            turnReservation?.phase = .review(operationID: review.operationID)
            userMessage = "No se recibió un recibo de Moa. La operación no se reintentará automáticamente; revisa antes de confirmar otra vez."
        }
    }

    public func setForegroundActive(_ active: Bool) {
        guard isForeground != active else { return }
        isForeground = active
        voice.setForegroundActive(active)
        pttState = PulsePTTReducer.reduce(pttState, event: .foreground(active: active))
        if !active {
            invalidateActiveVoiceCapture()
            updatesTask?.cancel()
            updatesTask = nil
            clearStreamFailure()
            hasFreshAuthoritativeProjection = false
            brief = nil
            operationsAreAvailable = false
            Task { [service, writeGate] in
                await writeGate.setOnline(false)
                await service?.stopOpsUpdates()
            }
            if hasPairedDevice, pendingReview == nil { state = .stale }
        } else if hasPairedDevice {
            Task { await self.refresh(narrating: false) }
        }
    }

    private func restoreRegistration() {
        do {
            guard let registration = try store.loadDeviceRegistration() else { return }
            service = try serviceFactory(registration)
            hasPairedDevice = true
            providerConfigured = service is any PulseRealtimeCredentialIssuing
            serverName = registration.baseURL.host ?? "Moa"
            state = .stale
        } catch {
            try? store.clearDeviceRegistration()
            userMessage = "La credencial local no está disponible. Empareja Pulse de nuevo."
        }
    }

    private func startUpdates(using service: any PulseCallService) {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            let events = await service.opsStreamEvents()
            await service.startOpsUpdates()
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                self.applyStreamEvent(event)
            }
            guard !Task.isCancelled, let self else { return }
            self.scheduleStreamFailure()
            self.updatesTask = nil
        }
    }

    private func applyStreamEvent(_ event: PulseOpsStreamEvent) {
        switch event {
        case let .snapshot(update):
            opsSnapshot = update.snapshot
            // A WS snapshot is intentionally not authoritative enough to
            // reopen writes or turn stale data into a current briefing.
        case .reconnecting, .stopped:
            scheduleStreamFailure()
        }
    }

    /// Reserves the one global owner turn before a provider task exists. This
    /// method deliberately has no suspension point before the reservation.
    private func acceptOwnerTurn(_ rawText: String, recordCaption: Bool = true) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if recordCaption { appendOwnerCaption(text) }
        if let review = pendingReview {
            guard review.isCurrent() else {
                pendingReview = nil
                releaseTurnReservation()
                state = settledCallState()
                appendCaption("La revisión de Moa caducó. No se confirmó ninguna acción.", provenance: .localFreshness)
                return
            }
            acceptReviewAnswer(text, review: review)
            return
        }
        guard turnReservation == nil else {
            appendCaption("Pulse está atendiendo un turno. Espera a que termine antes de enviar otra petición.", provenance: .localFreshness)
            return
        }
        guard let service, let brief, hasPairedDevice, hasFreshAuthoritativeProjection, state != .offline else {
            deterministicFallback()
            return
        }
        guard providerConfigured, privacyMode.permitsCloudAudio else {
            deterministicFallback()
            return
        }
        let reservation = TurnReservation(id: UUID(), phase: .provider)
        turnReservation = reservation
        state = .thinking
        let coordinator = providerFactory(service, store, writeGate, providerClient)
        providerTask = Task { [weak self] in
            guard let self else { return }
            await self.runProviderTurn(
                reservation: reservation,
                question: text,
                context: .init(brief: brief),
                coordinator: coordinator
            )
        }
    }

    private func runProviderTurn(
        reservation: TurnReservation,
        question: String,
        context: PulseProviderContext,
        coordinator: any PulseProviderResponding
    ) async {
        do {
            let answer = try await coordinator.respond(question: question, context: context) { [weak self] delta in
                Task { @MainActor [weak self] in
                    self?.appendProviderDelta(delta, for: reservation.id)
                }
            }
            guard reservationIsProvider(reservation.id) else { return }
            providerTask = nil
            if answer.preparedReviews.count == 1, let review = answer.preparedReviews.first {
                guard present(review: review, replacing: reservation.id) else {
                    // A provider response that cannot become the visible
                    // review must never permit another turn. Keep the lease
                    // until the app reports the safe failure state.
                    state = .error
                    appendCaption("Moa devolvió una revisión que Pulse no pudo presentar con seguridad.", provenance: .localFreshness)
                    return
                }
                let narration = PulseOperationNarrator.review(review)
                appendCaption(narration, provenance: .moaObserved)
                narrate(narration)
            } else if answer.preparedReviews.count > 1 {
                // The constrained coordinator forbids this. Do not release a
                // reservation and allow another prepare after an unsafe reply.
                state = .error
                appendCaption("Pulse recibió más de una revisión. No prepararé ninguna acción adicional.", provenance: .localFreshness)
            } else {
                state = .speaking
                let spoken = answer.text.isEmpty ? "Pulse no recibió una respuesta del proveedor." : answer.text
                finalizeProviderCaption(spoken)
                narrate(spoken)
                releaseTurnReservation(reservation.id)
                state = settledCallState()
            }
        } catch is CancellationError {
            guard reservationIsProvider(reservation.id) else { return }
            providerTask = nil
            releaseTurnReservation(reservation.id)
            state = settledCallState()
            appendCaption("El turno de Pulse se canceló antes de preparar una acción.", provenance: .localFreshness)
        } catch {
            guard reservationIsProvider(reservation.id) else { return }
            providerTask = nil
            releaseTurnReservation(reservation.id)
            state = settledCallState()
            appendCaption("El proveedor OpenAI Realtime no está disponible. Mantengo el panorama determinista de Moa.", provenance: .localFreshness)
            deterministicFallback()
        }
    }

    private func acceptReviewAnswer(_ text: String, review: PulsePendingReview) {
        guard reservationIsReview(for: review.operationID), activeVoiceCapture == nil else {
            appendCaption("La revisión está ocupada. Espera a que termine la captura actual.", provenance: .localFreshness)
            return
        }
        switch PulseReviewVoiceConfirmation.resolve(transcript: text, visibleReviews: [review]) {
        case .confirm:
            Task { [weak self] in await self?.confirmCurrentReview() }
        case .cancel:
            cancelReview()
        case .none:
            appendCaption("Hay una única revisión visible. Di sí para confirmar o no para cancelar.", provenance: .localFreshness)
        }
    }

    private func configureVoiceCallbacks() {
        voice.onPlaybackFailure = { [weak self] in
            guard let self else { return }
            self.voiceLog.error("playback_failure")
            self.userMessage = "No se pudo reproducir la respuesta de voz. El turno sigue activo; puedes detenerlo o esperar el resultado escrito."
        }
        voice.onAvailability = { [weak self] capture, availability in
            guard let self else { return }
            guard self.activeVoiceCapture?.token == capture else { return }
            self.voiceUnavailable = availability == .unavailable
            if availability == .available {
                self.voiceLog.debug("capture_available")
            } else {
                self.voiceLog.debug("capture_unavailable")
            }
            self.pttState = PulsePTTReducer.reduce(self.pttState, event: .permission(granted: availability == .available))
            if availability == .unavailable {
                if let reservation = self.turnReservation, reservation.phase == .provider {
                    self.finishAudioAttempt(capture: capture, reservationID: reservation.id, cancelTurn: true)
                }
                self.clearActiveVoiceCapture(invalidateNative: false)
                if self.pendingReview == nil, self.state == .listening {
                    self.state = self.settledCallState()
                }
            } else if case .ownerTurn? = self.activeVoiceCapture?.intent {
                self.startRealtimeAudioTurn(capture)
            }
        }
        voice.onInterruption = { [weak self] capture in
            guard let self else { return }
            guard self.activeVoiceCapture?.token == capture else { return }
            if let reservation = self.turnReservation, reservation.phase == .provider {
                self.finishAudioAttempt(capture: capture, reservationID: reservation.id, cancelTurn: true)
                // The provider attempt is terminal; unlike a review speech
                // interruption, its next press must be immediately usable.
                self.pttState = .idle
            } else {
                self.clearActiveVoiceCapture(invalidateNative: false)
                self.pttState = PulsePTTReducer.reduce(self.pttState, event: .interruption)
            }
            if self.pendingReview == nil { self.state = self.settledCallState() }
            self.appendCaption("La captura de voz se interrumpió. Puedes usar texto o volver a pulsar para hablar.", provenance: .localFreshness)
        }
        voice.onTranscript = { [weak self] capture, text, isFinal in
            guard let self else { return }
            guard let active = self.activeVoiceCapture, active.token == capture else { return }
            self.appendOwnerCaption(text, replacingLive: !isFinal || self.liveOwnerCaptionID != nil)
            if isFinal {
                self.liveOwnerCaptionID = nil
                self.clearActiveVoiceCapture(invalidateNative: false)
                self.pttState = PulsePTTReducer.reduce(self.pttState, event: .release)
                switch active.intent {
                case .ownerTurn:
                    self.acceptOwnerTurn(text, recordCaption: false)
                case let .review(operationID):
                    guard let review = self.pendingReview,
                          review.operationID == operationID,
                          self.state == .review,
                          self.reservationIsReview(for: operationID) else { return }
                    self.acceptReviewAnswer(text, review: review)
                }
            }
        }
        voice.onPCM16 = { [weak self] capture, pcm in
            Task { @MainActor [weak self] in
                guard let self, self.activeVoiceCapture?.token == capture else { return }
                if let reservation = self.turnReservation, self.realtimeAudioTurn != nil {
                    self.enqueueAudioAppend(pcm, capture: capture, reservationID: reservation.id)
                } else {
                    self.preconnectPCM.append(pcm)
                }
            }
        }
    }

    private func startRealtimeAudioTurn(_ capture: PulseVoiceCaptureToken) {
        guard realtimeAudioTurn == nil, providerConfigured, privacyMode.permitsCloudAudio,
              let brief, let issuer = service as? any PulseRealtimeCredentialIssuing,
              activeVoiceCapture?.token == capture, turnReservation == nil else { return }
        let reservation = TurnReservation(id: UUID(), phase: .provider)
        turnReservation = reservation
        voice.setRealtimeTurnActive(true)
        voiceLog.debug("realtime_turn_reserved")
        let model = self
        audioMintTask = Task { [weak model, providerClient] in
            guard let model else { return }
            do {
                try Task.checkCancellation()
                let credential = try await issuer.mintRealtimeClientSecret()
                await MainActor.run { model.voiceLog.debug("realtime_mint_succeeded") }
                try Task.checkCancellation()
                let turn = try await providerClient.beginAudioTurn(credential: credential, configuration: await MainActor.run { model.realtimeConfiguration() }, context: .init(brief: brief), onText: { [weak model] delta in
                    Task { @MainActor [weak model] in model?.appendProviderDelta(delta, for: reservation.id) }
                }, onAudio: { [weak model] pcm in
                    Task { @MainActor [weak model] in model?.voice.playPCM16(pcm) }
                }, onFinished: { [weak model] completion in
                    Task { @MainActor [weak model] in
                        guard let model, model.reservationIsProvider(reservation.id) else { return }
                        switch completion {
                        case .completed:
                            model.voiceLog.debug("realtime_completed")
                            model.finishAudioAttempt(capture: capture, reservationID: reservation.id, cancelTurn: false)
                        case .providerFailed, .transportFailed:
                            model.voiceLog.error("realtime_failed")
                            model.failAudioAttempt(capture: capture, reservationID: reservation.id)
                        }
                    }
                })
                guard await MainActor.run(body: { model.activeVoiceCapture?.token == capture }) else {
                    await turn.cancelForBargeIn()
                    await MainActor.run { model.finishAudioAttempt(capture: capture, reservationID: reservation.id, cancelTurn: false) }
                    return
                }
                await MainActor.run {
                    guard model.reservationIsProvider(reservation.id), model.activeVoiceCapture?.token == capture else { return }
                    model.realtimeAudioTurn = turn
                    model.audioMintTask = nil
                    model.voiceLog.debug("realtime_turn_opened")
                    let flush = model.preconnectPCM.takeForFlush()
                    for chunk in flush.chunks {
                        model.enqueueAudioAppend(chunk, capture: capture, reservationID: reservation.id)
                    }
                    if flush.shouldCommit || model.endedAudioCapture == capture {
                        model.state = .thinking
                        model.enqueueAudioCommit(capture: capture, reservationID: reservation.id)
                    }
                }
            } catch {
                await MainActor.run {
                    guard model.reservationIsProvider(reservation.id) else { return }
                    model.finishAudioAttempt(capture: capture, reservationID: reservation.id, cancelTurn: true)
                    model.deterministicFallback()
                    model.userMessage = "No se pudo completar el turno de voz. El estado de envío no pudo confirmarse; puedes volver a pulsar para hablar."
                }
            }
        }
    }

    private func reservationIsProvider(_ id: UUID) -> Bool {
        guard let reservation = turnReservation, reservation.id == id else { return false }
        return reservation.phase == .provider
    }

    private func enqueueAudioAppend(_ pcm: Data, capture: PulseVoiceCaptureToken, reservationID: UUID) {
        let previous = audioSendTask
        audioSendTask = Task { [weak self] in
            _ = await previous?.value
            guard let self,
                  self.activeVoiceCapture?.token == capture,
                  self.reservationIsProvider(reservationID),
                  let turn = self.realtimeAudioTurn else { return }
            do {
                try await turn.appendPCM16(pcm)
            } catch {
                self.failAudioAttempt(capture: capture, reservationID: reservationID)
            }
        }
    }

    private func enqueueAudioCommit(capture: PulseVoiceCaptureToken, reservationID: UUID) {
        guard audioCommitCapture != capture else { return }
        audioCommitCapture = capture
        voiceLog.debug("realtime_commit_queued")
        let previous = audioSendTask
        audioSendTask = Task { [weak self] in
            _ = await previous?.value
            guard let self,
                  self.activeVoiceCapture?.token == capture,
                  self.reservationIsProvider(reservationID),
                  let turn = self.realtimeAudioTurn else { return }
            do {
                try await turn.endCapture()
                self.voiceLog.debug("realtime_commit_sent")
            } catch {
                self.failAudioAttempt(capture: capture, reservationID: reservationID)
            }
        }
    }

    private func reservationIsReview(for operationID: String) -> Bool {
        guard let reservation = turnReservation else { return false }
        if case let .review(id) = reservation.phase { return id == operationID }
        return false
    }

    private func releaseTurnReservation(_ id: UUID? = nil) {
        guard id == nil || turnReservation?.id == id else { return }
        turnReservation = nil
        providerTask = nil
    }

    private func invalidateActiveVoiceCapture() {
        audioMintTask?.cancel()
        audioMintTask = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        preconnectPCM.cancel()
        audioCommitCapture = nil
        voice.setRealtimeTurnActive(false)
        if let realtimeAudioTurn { Task { await realtimeAudioTurn.cancelForBargeIn() }; self.realtimeAudioTurn = nil }
        if let reservation = turnReservation, reservation.phase == .provider { releaseTurnReservation(reservation.id) }
        clearActiveVoiceCapture(invalidateNative: true)
    }

    /// Every terminal audio path funnels here. It invalidates the exact
    /// capture generation and drops all per-turn state before another press.
    private func finishAudioAttempt(capture: PulseVoiceCaptureToken, reservationID: UUID, cancelTurn: Bool) {
        guard turnReservation?.id == reservationID else { return }
        audioMintTask?.cancel()
        audioMintTask = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        preconnectPCM.cancel()
        endedAudioCapture = nil
        audioCommitCapture = nil
        voice.setRealtimeTurnActive(false)
        if cancelTurn, let turn = realtimeAudioTurn {
            Task { await turn.cancelForBargeIn() }
        }
        realtimeAudioTurn = nil
        if activeVoiceCapture?.token == capture { clearActiveVoiceCapture(invalidateNative: true) }
        releaseTurnReservation(reservationID)
        pttState = .idle
        if pendingReview == nil { state = settledCallState() }
    }

    private func failAudioAttempt(capture: PulseVoiceCaptureToken, reservationID: UUID) {
        finishAudioAttempt(capture: capture, reservationID: reservationID, cancelTurn: true)
        userMessage = "No se pudo completar el turno de voz. El estado de envío no pudo confirmarse; puedes volver a pulsar para hablar."
    }

    private func cancelActiveProviderTurn() {
        providerTask?.cancel()
        providerTask = nil
        if let reservation = turnReservation, reservation.phase == .provider { releaseTurnReservation() }
    }

    private func clearActiveVoiceCapture(invalidateNative: Bool) {
        guard activeVoiceCapture != nil else { return }
        activeVoiceCapture = nil
        endedAudioCapture = nil
        liveOwnerCaptionID = nil
        if invalidateNative { voice.invalidateCapture() }
    }

    private func deterministicFallback() {
        guard let lastAuthoritativeBrief else {
            appendCaption("Conecta con Moa para recibir un panorama seguro.", provenance: .localFreshness)
            return
        }
        let fallback: PulseDeterministicBrief
        if let last = lastSuccessfulRefreshAt, !hasFreshAuthoritativeProjection {
            fallback = PulseBriefBuilder.offline(last: lastAuthoritativeBrief, age: Date().timeIntervalSince(last))
        } else {
            fallback = lastAuthoritativeBrief
        }
        appendCaption(fallback.spoken, provenance: .moaObserved)
        narrate(fallback.spoken)
        if pendingReview == nil, hasFreshAuthoritativeProjection { state = settledCallState() }
    }

    private func showOffline(_ error: Error) {
        hasFreshAuthoritativeProjection = false
        brief = nil
        if let lastAuthoritativeBrief, let last = lastSuccessfulRefreshAt {
            let fallback = PulseBriefBuilder.offline(last: lastAuthoritativeBrief, age: Date().timeIntervalSince(last))
            appendCaption(fallback.spoken, provenance: .localFreshness)
            state = pendingReview == nil ? .offline : .review
        } else {
            state = pendingReview == nil ? .error : .review
        }
        userMessage = connectionMessage(for: error)
    }

    private func openWriteGate() async {
        await writeGate.setOnline(true)
        operationsAreAvailable = true
    }

    private func closeWriteGate() async {
        operationsAreAvailable = false
        await writeGate.setOnline(false)
    }

    private func clearStreamFailure() {
        streamFailureTask?.cancel()
        streamFailureTask = nil
        streamFailureID = nil
    }

    /// The WebSocket is a warm hint only. Once it drops, retain the display for
    /// a short grace period, then close writes and clearly label the old state.
    /// A reconnecting socket frame cannot reverse this; only `refresh()` can.
    private func scheduleStreamFailure() {
        guard isForeground, hasPairedDevice, streamFailureTask == nil else { return }
        let id = UUID()
        let graceInterval = streamGraceInterval
        let offlineInterval = streamOfflineInterval
        streamFailureID = id
        streamFailureTask = Task { [weak self, id, graceInterval, offlineInterval] in
            if graceInterval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(graceInterval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            if let self, self.streamFailureID == id {
                await self.transitionToStaleAfterStreamFailure(id: id)
            }
            if offlineInterval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(offlineInterval * 1_000_000_000))
            }
            guard !Task.isCancelled, let self, self.streamFailureID == id else { return }
            await self.transitionToOfflineAfterStreamFailure(id: id)
            self.streamFailureTask = nil
        }
    }

    private func transitionToStaleAfterStreamFailure(id: UUID) async {
        guard streamFailureID == id else { return }
        hasFreshAuthoritativeProjection = false
        brief = nil
        await closeWriteGate()
        if pendingReview == nil { state = .stale }
        userMessage = "La conexión en directo con Moa se perdió. Este es el último estado conocido; Pulse no confirmará ni preparará acciones hasta actualizar."
    }

    private func transitionToOfflineAfterStreamFailure(id: UUID) async {
        guard streamFailureID == id, !hasFreshAuthoritativeProjection else { return }
        if pendingReview == nil { state = .offline }
        userMessage = "Moa sigue sin conexión. Pulse conserva solo el último estado conocido y no encola acciones."
    }

    private func settledCallState() -> PulseCallState {
        guard hasPairedDevice else { return .disconnected }
        if hasFreshAuthoritativeProjection { return .ready }
        return lastSuccessfulRefreshAt == nil ? .stale : .offline
    }

    private func realtimeConfiguration() -> OpenAIRealtimeProviderConfiguration {
        .init()
    }

    private func narrate(_ text: String) {
        guard !isMuted else { return }
        voice.speak(text)
    }

    private func appendCaption(_ text: String, provenance: PulseProvenance) {
        guard !text.isEmpty else { return }
        captions = Array((captions + [.init(text: text, provenance: provenance)]).suffix(8))
    }

    private func appendOwnerCaption(_ text: String, replacingLive: Bool = false) {
        guard !text.isEmpty else { return }
        if replacingLive, let id = liveOwnerCaptionID, let index = captions.firstIndex(where: { $0.id == id }) {
            captions[index] = .init(id: id, text: text, provenance: .localFreshness, isOwner: true)
        } else {
            let caption = PulseCallCaption(text: text, provenance: .localFreshness, isOwner: true)
            captions = Array((captions + [caption]).suffix(8))
            if replacingLive { liveOwnerCaptionID = caption.id }
        }
    }

    private func appendProviderDelta(_ text: String, for reservationID: UUID) {
        guard !text.isEmpty, reservationIsProvider(reservationID) else { return }
        if let index = captions.lastIndex(where: { $0.provenance == .pulseInference && !$0.isOwner }) {
            let id = captions[index].id
            captions[index] = .init(id: id, text: captions[index].text + text, provenance: .pulseInference)
        } else {
            appendCaption(text, provenance: .pulseInference)
        }
    }

    private func finalizeProviderCaption(_ text: String) {
        guard !text.isEmpty else { return }
        if let index = captions.lastIndex(where: { $0.provenance == .pulseInference && !$0.isOwner }) {
            let id = captions[index].id
            captions[index] = .init(id: id, text: text, provenance: .pulseInference)
        } else {
            appendCaption(text, provenance: .pulseInference)
        }
    }

    private func relativeAge(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        return "\(max(1, seconds / 60)) min"
    }

    private func pairingMessage(for error: Error) -> String {
        if let error = error as? PulseCallError {
            switch error {
            case .insecureTransport: return "Pulse requiere HTTPS salvo para localhost o una IP 127.x directa."
            case .invalidPairingPayload: return "El payload de emparejamiento no tiene el formato moa-pair-v1 esperado."
            case let .httpStatus(code, _):
                if code == 401 { return "El emparejamiento caducó o no es válido." }
                if code == 426 { return "Moa exige HTTPS para esta conexión remota." }
                return "Moa no pudo reclamar este dispositivo (\(code))."
            default: return "No se pudo emparejar Pulse. Comprueba la dirección y el payload."
            }
        }
        return "No se pudo emparejar Pulse. Comprueba la dirección y el payload."
    }

    private func connectionMessage(for error: Error) -> String {
        if let error = error as? PulseCallError, case let .httpStatus(code, _) = error, code == 401 || code == 403 {
            return "La credencial de este dispositivo ya no está autorizada. Desconecta Pulse y empareja de nuevo."
        }
        return "Moa no está disponible. Pulse no enviará ni encolará acciones sin conexión."
    }
}
