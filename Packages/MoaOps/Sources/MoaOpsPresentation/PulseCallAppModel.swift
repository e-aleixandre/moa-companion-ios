import Foundation
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
    public typealias ServiceFactory = @Sendable (PulseDeviceRegistration) throws -> any PulseCallService

    @Published public private(set) var hasPairedDevice = false
    @Published public private(set) var serverName = ""
    @Published public private(set) var state: PulseCallState = .disconnected
    @Published public private(set) var pttState: PulsePTTState = .idle
    @Published public private(set) var voiceUnavailable = false
    @Published public private(set) var isPairing = false
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var providerConfigured = false
    @Published public private(set) var snapshot: OpsPulse?
    @Published public private(set) var opsSnapshot: OpsSnapshot?
    @Published public private(set) var lastSuccessfulRefreshAt: Date?
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
    private let providerClient: AnthropicMessagesClient
    private let writeGate = PulseWriteGate()
    private let voice: any PulseVoiceControlling
    private var service: (any PulseCallService)?
    private var updatesTask: Task<Void, Never>?
    private var liveOwnerCaptionID: UUID?
    private var isForeground = true

    public init(
        store: any PulseSecureStore = KeychainPulseSecureStore(),
        voice: (any PulseVoiceControlling)? = nil,
        providerClient: AnthropicMessagesClient = .init(),
        serviceFactory: @escaping ServiceFactory = { registration in try MoaPulseDeviceService(registration: registration) }
    ) {
        self.store = store
        self.voice = voice ?? NativePulseVoiceController()
        self.providerClient = providerClient
        self.serviceFactory = serviceFactory
        configureVoiceCallbacks()
        providerConfigured = (try? store.loadAnthropicAPIKey()) != nil
        restoreRegistration()
    }

    deinit { updatesTask?.cancel() }

    public var rootDestination: PulseCallRootDestination { hasPairedDevice ? .call : .pairing }

    public var freshnessLabel: String {
        guard let last = lastSuccessfulRefreshAt else { return "Sin estado reciente" }
        let age = max(0, Int(Date().timeIntervalSince(last)))
        if state == .offline || state == .stale { return "Último estado · hace \(relativeAge(age))" }
        return age < 10 ? "Actualizado ahora" : "Actualizado hace \(relativeAge(age))"
    }

    public var providerAvailabilityLabel: String {
        providerConfigured
            ? "Anthropic Messages API configurado en este dispositivo"
            : "Proveedor no configurado · Pulse usa un panorama determinista"
    }

    public func start() async {
        guard hasPairedDevice else { return }
        await refresh(narrate: true)
    }

    /// The pairing payload is parsed and claimed in this scope. It is never
    /// placed in a published property, a URL, a prompt, or ordinary storage.
    public func claim(baseURLText: String, pairingPayloadText: String, deviceLabel: String) async {
        isPairing = true
        defer { isPairing = false }
        do {
            let configuration = try PulseServerConfiguration(urlText: baseURLText)
            let payload = try PulsePairingPayload(parsing: pairingPayloadText)
            let registration = try await PulsePairingClient().claim(configuration: configuration, payload: payload, deviceLabel: deviceLabel)
            try store.saveDeviceRegistration(registration)
            service = try serviceFactory(registration)
            hasPairedDevice = true
            serverName = configuration.baseURL.host ?? "Moa"
            userMessage = nil
            state = .consulting
            await refresh(narrate: true)
        } catch {
            state = .disconnected
            userMessage = pairingMessage(for: error)
        }
    }

    /// This revokes local access by deleting the only local device credential.
    /// Serve's remote device revoke endpoint is intentionally owner-cookie-only,
    /// so Pulse does not pretend a device credential can revoke itself.
    public func disconnectAndClearLocalCredential() {
        let active = service
        service = nil
        updatesTask?.cancel()
        updatesTask = nil
        try? store.clearDeviceRegistration()
        hasPairedDevice = false
        serverName = ""
        snapshot = nil
        opsSnapshot = nil
        brief = nil
        lastSuccessfulRefreshAt = nil
        pendingReview = nil
        lastReceipt = nil
        captions = []
        state = .disconnected
        userMessage = nil
        Task {
            await writeGate.setOnline(false)
            await active?.invalidate()
        }
    }

    public func refresh(narrate: Bool = false) async {
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
            appendCaption(currentBrief.spoken, provenance: .moaObserved)
            state = pendingReview == nil ? .ready : .review
            userMessage = nil
            await writeGate.setOnline(true)
            startUpdates(using: service)
            if narrate { narrate(currentBrief.spoken) }
        } catch {
            await writeGate.setOnline(false)
            showOffline(error)
        }
    }

    public func beginPushToTalk() {
        guard hasPairedDevice, pendingReview == nil else { return }
        pttState = PulsePTTReducer.reduce(pttState, event: .press)
        guard pttState == .requestingPermission else { return }
        state = .listening
        Task { await voice.beginPushToTalk() }
    }

    public func endPushToTalk() {
        voice.endPushToTalk()
        pttState = PulsePTTReducer.reduce(pttState, event: .release)
        if state == .listening { state = .ready }
    }

    public func stop() {
        voice.stopAll()
        pttState = .idle
        if pendingReview == nil { state = hasPairedDevice ? .ready : .disconnected }
    }

    public func submitText(_ text: String) async { await handleOwnerTurn(text) }

    public func cancelReview() {
        pendingReview = nil
        if hasPairedDevice { state = .ready }
        appendCaption("Revisión cancelada en Pulse. Moa no recibió una confirmación.", provenance: .localFreshness)
    }

    public func confirmCurrentReview() async {
        guard let service, let review = pendingReview, review.isCurrent(), hasPairedDevice else {
            pendingReview = nil
            state = hasPairedDevice ? .ready : .disconnected
            return
        }
        state = .consulting
        do {
            let response = try await service.confirmOperation(review.operationID)
            guard let receipt = response.receipt else { throw PulseCallError.decoding }
            lastReceipt = receipt
            pendingReview = nil
            let narration = PulseOperationNarrator.receipt(receipt)
            appendCaption(narration, provenance: .moaObserved)
            state = .ready
            narrate(narration)
        } catch {
            // The review remains visible for an explicit owner retry/status
            // check. Pulse does not queue or retry a confirm in the background.
            state = .review
            userMessage = "No se recibió un recibo de Moa. La operación no se reintentará automáticamente; revisa antes de confirmar otra vez."
        }
    }

    public func saveAnthropicAPIKey(_ value: String) {
        do {
            try store.saveAnthropicAPIKey(value)
            providerConfigured = true
            userMessage = nil
        } catch {
            providerConfigured = false
            userMessage = "No se pudo guardar la clave del proveedor en el Llavero."
        }
    }

    public func clearAnthropicAPIKey() {
        try? store.clearAnthropicAPIKey()
        providerConfigured = false
    }

    public func setForegroundActive(_ active: Bool) {
        guard isForeground != active else { return }
        isForeground = active
        voice.setForegroundActive(active)
        pttState = PulsePTTReducer.reduce(pttState, event: .foreground(active: active))
        if !active {
            updatesTask?.cancel()
            updatesTask = nil
            Task { [service, writeGate] in
                await writeGate.setOnline(false)
                await service?.stopOpsUpdates()
            }
            if hasPairedDevice, pendingReview == nil { state = .stale }
        } else if hasPairedDevice {
            Task { await self.refresh(narrate: false) }
        }
    }

    private func restoreRegistration() {
        do {
            guard let registration = try store.loadDeviceRegistration() else { return }
            service = try serviceFactory(registration)
            hasPairedDevice = true
            serverName = registration.baseURL.host ?? "Moa"
            state = .ready
        } catch {
            try? store.clearDeviceRegistration()
            userMessage = "La credencial local no está disponible. Empareja Pulse de nuevo."
        }
    }

    private func startUpdates(using service: any PulseCallService) {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            await service.startOpsUpdates()
            let updates = await service.opsUpdates()
            for await update in updates {
                guard !Task.isCancelled else { return }
                await self?.apply(update)
            }
        }
    }

    private func apply(_ update: OpsSnapshotUpdate) {
        opsSnapshot = update.snapshot
        // A websocket snapshot is a warm safe projection, but it is not a
        // replacement for the cursor-free Pulse briefing. Preserve the current
        // provenance/freshness instead of synthesizing a new spoken claim.
        if state == .stale || state == .offline { state = pendingReview == nil ? .ready : .review }
    }

    private func handleOwnerTurn(_ rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        appendOwnerCaption(text)
        if let review = pendingReview, review.isCurrent() {
            switch PulseReviewVoiceConfirmation.resolve(transcript: text, visibleReviews: [review]) {
            case .confirm:
                await confirmCurrentReview()
            case .cancel:
                cancelReview()
            case .none:
                appendCaption("Hay una única revisión visible. Di sí para confirmar o no para cancelar.", provenance: .localFreshness)
            }
            return
        }
        if pendingReview != nil { pendingReview = nil }
        guard let service, let brief, hasPairedDevice, state != .offline else {
            deterministicFallback()
            return
        }
        guard providerConfigured else {
            deterministicFallback()
            return
        }
        state = .thinking
        let executor = PulseMoaToolExecutor(service: service, writeGate: writeGate)
        let coordinator = PulseProviderCoordinator(client: providerClient, store: store, executor: executor)
        do {
            let answer = try await coordinator.respond(question: text, context: .init(brief: brief)) { [weak self] delta in
                Task { @MainActor [weak self] in
                    self?.appendProviderDelta(delta)
                }
            }
            if answer.preparedReviews.count == 1, let review = answer.preparedReviews.first {
                pendingReview = review
                state = .review
                let narration = PulseOperationNarrator.review(review)
                appendCaption(narration, provenance: .moaObserved)
                narrate(narration)
            } else if answer.preparedReviews.count > 1 {
                state = .ready
                appendCaption("Pulse recibió más de una revisión. No mostraré ninguna: prepara una sola acción cada vez.", provenance: .localFreshness)
            } else {
                state = .speaking
                let spoken = answer.text.isEmpty ? "Pulse no recibió una respuesta del proveedor." : answer.text
                finalizeProviderCaption(spoken)
                narrate(spoken)
                state = .ready
            }
        } catch {
            state = .ready
            appendCaption("El proveedor Anthropic no está disponible. Mantengo el panorama determinista de Moa.", provenance: .localFreshness)
            deterministicFallback()
        }
    }

    private func configureVoiceCallbacks() {
        voice.onAvailability = { [weak self] availability in
            guard let self else { return }
            self.voiceUnavailable = availability == .unavailable
            self.pttState = PulsePTTReducer.reduce(self.pttState, event: .permission(granted: availability == .available))
            if availability == .unavailable, self.state == .listening { self.state = .ready }
        }
        voice.onInterruption = { [weak self] in
            guard let self else { return }
            self.pttState = PulsePTTReducer.reduce(self.pttState, event: .interruption)
            if self.pendingReview == nil { self.state = .ready }
            self.appendCaption("La captura de voz se interrumpió. Puedes usar texto o volver a pulsar para hablar.", provenance: .localFreshness)
        }
        voice.onTranscript = { [weak self] text, isFinal in
            guard let self else { return }
            self.appendOwnerCaption(text, replacingLive: !isFinal)
            if isFinal {
                self.liveOwnerCaptionID = nil
                Task { await self.handleOwnerTurn(text) }
            }
        }
    }

    private func deterministicFallback() {
        guard let brief else {
            appendCaption("Conecta con Moa para recibir un panorama seguro.", provenance: .localFreshness)
            return
        }
        let fallback: PulseDeterministicBrief
        if let last = lastSuccessfulRefreshAt, state == .offline || state == .stale {
            fallback = PulseBriefBuilder.offline(last: brief, age: Date().timeIntervalSince(last))
        } else {
            fallback = brief
        }
        appendCaption(fallback.spoken, provenance: .moaObserved)
        narrate(fallback.spoken)
        if pendingReview == nil { state = hasPairedDevice ? .ready : .disconnected }
    }

    private func showOffline(_ error: Error) {
        if let brief, let last = lastSuccessfulRefreshAt {
            let fallback = PulseBriefBuilder.offline(last: brief, age: Date().timeIntervalSince(last))
            self.brief = fallback
            appendCaption(fallback.spoken, provenance: .localFreshness)
            state = .offline
        } else {
            state = .error
        }
        userMessage = connectionMessage(for: error)
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

    private func appendProviderDelta(_ text: String) {
        guard !text.isEmpty else { return }
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
