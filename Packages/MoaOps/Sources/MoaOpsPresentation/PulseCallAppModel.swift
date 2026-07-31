import Foundation
import SwiftUI
import MoaOpsCore

public enum PulseCallState: Equatable, Sendable {
    case disconnected, ready, connecting, reconnecting(attempt: Int), listening, responding, resolving, ended, error
    public var spanishLabel: String {
        switch self {
        case .disconnected: "Sin emparejar"
        case .ready: "Lista para llamar"
        case .connecting: "Conectando llamada"
        case let .reconnecting(attempt): "Reconectando (\(attempt))"
        case .listening: "Escuchando"
        case .responding: "Pulse responde"
        case .resolving: "Pulse resuelve"
        case .ended: "Llamada terminada"
        case .error: "Llamada no disponible"
        }
    }
}

public enum PulseCallRootDestination: Equatable, Sendable { case pairing, call }
public struct PulseCallCaption: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let isOwner: Bool
    public init(id: UUID = UUID(), text: String, isOwner: Bool = false) { self.id = id; self.text = text; self.isOwner = isOwner }
}

@MainActor
public final class PulseCallAppModel: ObservableObject {
    public typealias ServiceFactory = @Sendable (PulseDeviceRegistration) throws -> any PulseCallServing
    public typealias PairingClaim = @Sendable (PulseServerConfiguration, PulsePairingPayload, String) async throws -> PulseDeviceRegistration

    @Published public private(set) var hasPairedDevice = false
    @Published public private(set) var serverName = ""
    @Published public private(set) var state: PulseCallState = .disconnected
    @Published public private(set) var captions: [PulseCallCaption] = []
    @Published public private(set) var userMessage: String?
    @Published public private(set) var isPairing = false
    @Published public private(set) var isCallActive = false
    @Published public private(set) var isGuardianActive = false
    @Published public private(set) var guardianState: PulseGuardianState = .idle
    @Published public private(set) var guardianSnapshot = PulseGuardianSnapshot()
    /// 0..1 level of the relevant voice (owner or Pulse) while the Guardian
    /// is active; feeds the orb's reactivity. Arrives already smoothed and
    /// capped at ~30 Hz from the audio layer.
    @Published public private(set) var audioLevel: Float = 0
    /// Guardián is the default UI mode. `startCall()` remains the explicit
    /// legacy Conversation entry point for callers that rely on it.
    @Published public var isGuardianMode = true
    @Published public var isMuted = false { didSet { voice.setMuted(isMuted); updateGuardianLiveActivity() } }

    private let store: any PulseSecureStore
    private let voice: any PulseVoiceControlling
    private let serviceFactory: ServiceFactory
    private let pairingClaim: PairingClaim
    private let realtime: any PulseRealtimeCalling
    private let reconnectDelay: @Sendable (Int) -> TimeInterval
    /// How long a Moa tool has to run before the orb shows it. Below it the
    /// resolving state would only be a flash. Injectable so tests do not sleep.
    private let resolvingDelay: TimeInterval
    private var service: (any PulseCallServing)?
    private var call: (any PulseRealtimeCallControlling)?
    private var connectionTask: Task<Void, Never>?
    private var pendingPCM: [Data] = []
    private var pcmDrainGeneration: UInt64?
    private var callGeneration: UInt64 = 0
    private var wantsCall = false
    private var registration: PulseDeviceRegistration?
    // Moa tools the model is running through the app. Counted, not flagged: one
    // response commonly chains several calls. It may dip below zero for an
    // instant: each provider callback reaches the main actor in its own hop, so
    // a `finished` can land before its own `started` and the pair only balances
    // out once both have been applied.
    private var toolsInFlight = 0
    private var resolvingTask: Task<Void, Never>?
    private var isResolvingVisible = false
    /// The live-turn state the vortex is standing in for. Turn events keep
    /// updating it while a tool runs, so the orb goes back to what the call is
    /// actually doing instead of to a guess.
    private var liveStateBehindResolving: PulseCallState = .listening
    private var guardian: PulseGuardianCoordinator?
    private let guardianLiveActivity = PulseGuardianLiveActivityController()

    public init(store: any PulseSecureStore = KeychainPulseSecureStore(), voice: (any PulseVoiceControlling)? = nil, realtime: any PulseRealtimeCalling = OpenAIRealtimeClient(), reconnectDelay: @escaping @Sendable (Int) -> TimeInterval = { min(pow(2, Double(max(0, $0 - 1))), 30) }, resolvingDelay: TimeInterval = 0.3, pairingClaim: @escaping PairingClaim = { configuration, payload, label in try await PulsePairingClient().claim(configuration: configuration, payload: payload, deviceLabel: label) }, serviceFactory: @escaping ServiceFactory = { try MoaPulseDeviceService(registration: $0) }) {
        self.store = store; self.voice = voice ?? NativePulseVoiceController(); self.realtime = realtime; self.reconnectDelay = reconnectDelay; self.resolvingDelay = resolvingDelay; self.pairingClaim = pairingClaim; self.serviceFactory = serviceFactory
        configureVoice()
        restoreRegistration()
        registerRemoteControl()
    }

    deinit { connectionTask?.cancel(); resolvingTask?.cancel() }
    public var rootDestination: PulseCallRootDestination { hasPairedDevice ? .call : .pairing }
    public var canStartCall: Bool {
        guard hasPairedDevice, !wantsCall else { return false }
        switch state { case .ready, .ended, .error: return true; default: return false }
    }
    public var isConnectingOrReconnecting: Bool { if case .connecting = state { return true }; if case .reconnecting = state { return true }; return false }

    public func start() async { if hasPairedDevice, state == .disconnected { state = .ready } }

    public func claim(baseURLText: String, pairingPayloadText: String, deviceLabel: String) async {
        do { try await claim(configuration: PulseServerConfiguration(urlText: baseURLText), payload: PulsePairingPayload(parsing: pairingPayloadText), deviceLabel: deviceLabel) }
        catch { userMessage = "No se pudo emparejar Pulse. Comprueba la dirección y el código temporal." }
    }

    public func claimQRCode(_ value: String, deviceLabel: String) async {
        do { let envelope = try PulsePairingEnvelope(parsing: value); try await claim(configuration: envelope.configuration, payload: envelope.payload, deviceLabel: deviceLabel) }
        catch { userMessage = "El QR de emparejamiento no es válido." }
    }

    private func claim(configuration: PulseServerConfiguration, payload: PulsePairingPayload, deviceLabel: String) async throws {
        isPairing = true; defer { isPairing = false }
        let registration = try await pairingClaim(configuration, payload, deviceLabel)
        try store.saveDeviceRegistration(registration)
        service = try serviceFactory(registration)
        self.registration = registration
        hasPairedDevice = true; serverName = configuration.baseURL.host ?? "Moa"; state = .ready; userMessage = nil
    }

    /// A monotonically increasing generation owns every connection attempt and
    /// callback. Hangup invalidates it before cancelling work, so an old mint
    /// or socket completion can never reactivate the call.
    public func startCall() {
        guard canStartCall, let service else { return }
        callGeneration &+= 1
        wantsCall = true
        userMessage = nil
        startConnection(generation: callGeneration, service: service, attempt: 0)
    }

    public func startGuardian() async {
        guard hasPairedDevice, let service, let registration, !isGuardianActive, call == nil else { return }
        let attention = PulseAttentionWebSocket(registration: registration)
        let coordinator = PulseGuardianCoordinator(service: service, realtime: realtime, attention: attention, voice: voice, wakeWord: PulseWakeWordDetector())
        coordinator.onState = { [weak self] state in
            let model = self
            Task { @MainActor in
                guard let model else { return }
                model.guardianState = state
                model.updateGuardianLiveActivity()
            }
        }
        coordinator.onSnapshot = { [weak self] snapshot in
            let model = self
            Task { @MainActor in
                guard let model else { return }
                model.guardianSnapshot = snapshot
                model.updateGuardianLiveActivity()
            }
        }
        coordinator.onText = { [weak self] text in
            let model = self
            Task { @MainActor in
                guard let model, !text.isEmpty else { return }
                model.captions = Array((model.captions + [.init(text: text)]).suffix(20))
            }
        }
        coordinator.onAudioLevel = { [weak self] level in
            let model = self
            Task { @MainActor in model?.audioLevel = level }
        }
        guardian = coordinator
        await coordinator.start()
        isGuardianActive = coordinator.state != .failed
        if isGuardianActive {
            guardianLiveActivity.start(
                attributes: .init(startedAt: Date(), ownerName: nil),
                contentState: PulseGuardianActivityAttributes.contentState(state: guardianState, snapshot: guardianSnapshot, micMuted: isMuted)
            )
        } else {
            userMessage = "No se pudo iniciar el micrófono del Guardián."
        }
    }

    public func stopGuardian() {
        guardian?.stop()
        guardian = nil
        isGuardianActive = false
        guardianState = .idle
        guardianSnapshot = .init()
        audioLevel = 0
        // Keep the Live Activity alive in its stopped form so the single
        // lock-screen toggle can restart the Guardián without opening the app.
        // Tapping "Activar" relaunches the app process in the background.
        updateGuardianLiveActivity()
    }

    /// One lock-screen toggle: start when stopped, stop when running. Mirrors the
    /// single in-app Guardián button.
    public func toggleGuardian() async {
        if isGuardianActive { stopGuardian() }
        else { await startGuardian() }
    }

    /// Muting is purely a capture gate — the Guardián keeps its behaviour, it
    /// just stops listening so cabin noise doesn't interrupt it.
    public func toggleMic() { isMuted.toggle() }

    private func registerRemoteControl() {
        PulseGuardianRemoteControl.shared.onToggleMic = { [weak self] in self?.toggleMic() }
        PulseGuardianRemoteControl.shared.onToggleGuardian = { [weak self] in await self?.toggleGuardian() }
    }

    public func activateGuardianTalk() { guardian?.activateTalk() }
    public func reclaimGuardianAttention() { guardian?.reclaimAttention() }

    public func endCall() {
        if isGuardianActive { stopGuardian(); return }
        callGeneration &+= 1
        wantsCall = false
        connectionTask?.cancel(); connectionTask = nil
        clearToolsInFlight()
        let oldCall = call; call = nil
        isCallActive = false
        pendingPCM.removeAll(); pcmDrainGeneration = nil
        voice.stopAll()
        state = hasPairedDevice ? .ended : .disconnected
        Task { await oldCall?.end() }
    }

    public func disconnectAndClearLocalCredential() {
        stopGuardian(); endCall(); let old = service; service = nil; registration = nil; try? store.clearDeviceRegistration(); hasPairedDevice = false; serverName = ""; captions = []; userMessage = nil; state = .disconnected
        Task { await old?.invalidate() }
    }

    private func startConnection(generation: UInt64, service: any PulseCallServing, attempt: Int) {
        guard owns(generation), call == nil else { return }
        connectionTask?.cancel()
        state = attempt == 0 ? .connecting : .reconnecting(attempt: attempt)
        connectionTask = Task { [weak self] in
            do {
                let executor = PulseGenericToolExecutor(service: service)
                let overview = await executor.execute(.init(id: "initial-overview", name: "list_sessions", arguments: Data("{}".utf8)))
                try Task.checkCancellation()
                let credential = try await service.mintRealtimeClientSecret()
                try Task.checkCancellation()
                guard let self, self.owns(generation) else { return }
                let owner = self
                let call = try await self.realtime.beginCall(credential: credential, configuration: .init(), executor: executor, initialContext: "<estado_inicial_moa>\n\(overview.output)\n</estado_inicial_moa>", onState: { [weak owner] event in let o = owner; Task { @MainActor in o?.apply(event, generation: generation, service: service, attempt: attempt) } }, onText: { [weak owner] text in let o = owner; Task { @MainActor in o?.append(text, owner: false, generation: generation) } }, onAudio: { [weak owner] pcm, played in let o = owner; Task { @MainActor in guard o?.owns(generation) == true else { return }; o?.voice.playPCM16(pcm, completion: played) } }, onBargeIn: { [weak owner] in let o = owner; Task { @MainActor in guard o?.owns(generation) == true else { return }; o?.voice.flushPlayback() } })
                guard self.owns(generation) else { await call.end(); return }
                self.call = call
                guard await self.voice.startContinuousCapture() else {
                    guard self.owns(generation) else { await call.end(); return }
                    self.stopForCaptureFailure(call: call)
                    return
                }
                guard self.owns(generation) else { await call.end(); return }
                self.isCallActive = true
                self.connectionTask = nil
            } catch is CancellationError {
                // The owning generation has been cancelled by hangup/retry.
            } catch {
                guard let self, self.owns(generation) else { return }
                self.call = nil; self.isCallActive = false; self.clearToolsInFlight(); self.voice.stopAll()
                self.scheduleReconnect(generation: generation, service: service, attempt: max(1, attempt + 1))
            }
        }
    }

    private func scheduleReconnect(generation: UInt64, service: any PulseCallServing, attempt: Int) {
        guard owns(generation) else { return }
        connectionTask?.cancel()
        state = .reconnecting(attempt: attempt)
        connectionTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.reconnectDelay(attempt)
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            guard self.owns(generation) else { return }
            self.startConnection(generation: generation, service: service, attempt: attempt)
        }
    }

    private func apply(_ event: PulseRealtimeCallState, generation: UInt64, service: any PulseCallServing, attempt: Int) {
        guard owns(generation) else { return }
        switch event {
        case .connecting: state = .connecting
        case .listening: applyLiveState(.listening)
        case .responding: applyLiveState(.responding)
        case .toolCallStarted: toolCallStarted(generation: generation)
        case .toolCallFinished: toolCallFinished(generation: generation)
        case .speechStarted, .speechStopped:
            // Conversation mode already streams continuously; owner-speech
            // boundaries only matter for the Guardián hot window.
            break
        case .ended, .failed:
            // Retire this socket generation before ending it: `end()` emits an
            // ended callback and must not schedule a duplicate reconnect.
            let replacementGeneration = callGeneration &+ 1
            callGeneration = replacementGeneration
            clearToolsInFlight()
            let old = call; call = nil; isCallActive = false; pendingPCM.removeAll(); pcmDrainGeneration = nil; voice.stopAll()
            Task { await old?.end() }
            scheduleReconnect(generation: replacementGeneration, service: service, attempt: max(1, attempt + 1))
        }
    }

    /// Assigns a live-turn state. While a Moa tool is being resolved the orb
    /// belongs to the thinking vortex; the state matching the turn is recomputed
    /// when the tool comes back. Connecting, reconnecting, ending and failing all
    /// assign `state` directly and therefore outrank resolving.
    private func applyLiveState(_ live: PulseCallState) {
        liveStateBehindResolving = live
        guard !isResolvingVisible else { return }
        state = live
    }

    private func toolCallStarted(generation: UInt64) {
        guard owns(generation) else { return }
        toolsInFlight += 1
        // Its own `finished` was applied first: the pair is balanced and there is
        // nothing left to wait for, so the vortex must not be scheduled at all.
        guard toolsInFlight > 0 else { return }
        guard toolsInFlight == 1, !isResolvingVisible, resolvingTask == nil else { return }
        let delay = resolvingDelay
        resolvingTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self, self.owns(generation) else { return }
            self.resolvingTask = nil
            self.showResolvingIfStillWorking()
        }
    }

    private func toolCallFinished(generation: UInt64) {
        // Deliberately NOT `toolsInFlight > 0`: an out-of-order `finished` dropped
        // here would leave the counter stuck at 1 and strand the orb thinking
        // forever. Letting it go negative inside the same live generation keeps
        // the pair balanced, and the generation guard — the same one `started`
        // uses — drops the late callbacks of a call that is already gone, so they
        // cannot contaminate the next one.
        guard owns(generation) else { return }
        toolsInFlight -= 1
        // Chained tools read as one continuous "Pulse is working": the vortex only
        // leaves when the last call is back.
        guard toolsInFlight <= 0 else { return }
        resolvingTask?.cancel(); resolvingTask = nil
        leaveResolving()
    }

    /// A tool shorter than `resolvingDelay` never reaches the orb: a
    /// fraction-of-a-second flash is worse than showing nothing.
    private func showResolvingIfStillWorking() {
        guard toolsInFlight > 0, call != nil else { return }
        switch state {
        case .listening, .responding: break
        default: return
        }
        liveStateBehindResolving = state
        isResolvingVisible = true
        state = .resolving
    }

    private func leaveResolving() {
        guard isResolvingVisible else { return }
        isResolvingVisible = false
        // If something more important already took the orb (hangup, drop,
        // reconnection), it keeps it: only the vortex itself is undone.
        guard call != nil, state == .resolving else { return }
        state = liveStateBehindResolving
    }

    /// The socket that owned the tools is gone: nothing will report them back, so
    /// the vortex must not outlive it.
    private func clearToolsInFlight() {
        toolsInFlight = 0
        resolvingTask?.cancel(); resolvingTask = nil
        isResolvingVisible = false
        liveStateBehindResolving = .listening
    }

    private func owns(_ generation: UInt64) -> Bool { wantsCall && generation == callGeneration }

    private func updateGuardianLiveActivity() {
        guardianLiveActivity.update(PulseGuardianActivityAttributes.contentState(state: guardianState, snapshot: guardianSnapshot, micMuted: isMuted))
    }

    private func configureVoice() {
        voice.onPCM16 = { [weak self] pcm in
            self?.enqueuePCM(pcm)
        }
        voice.onInterruption = { [weak self] in self?.endCall() }
        voice.onPlaybackFailure = { [weak self] in self?.userMessage = "El audio de Pulse no está disponible en este momento." }
    }

    private func enqueuePCM(_ pcm: Data) {
        guard isCallActive, call != nil else { return }
        if pendingPCM.count == 8 { pendingPCM.removeFirst() }
        pendingPCM.append(pcm)
        guard pcmDrainGeneration == nil else { return }
        let generation = callGeneration
        pcmDrainGeneration = generation
        Task { [weak self] in await self?.drainPCM(generation: generation) }
    }

    private func drainPCM(generation: UInt64) async {
        while owns(generation), let call, !pendingPCM.isEmpty {
            let pcm = pendingPCM.removeFirst()
            do { try await call.appendPCM16(pcm) }
            catch { break }
        }
        if pcmDrainGeneration == generation { pcmDrainGeneration = nil }
    }

    private func stopForCaptureFailure(call: any PulseRealtimeCallControlling) {
        callGeneration &+= 1
        wantsCall = false
        self.call = nil
        isCallActive = false
        clearToolsInFlight()
        pendingPCM.removeAll()
        pcmDrainGeneration = nil
        voice.stopAll()
        state = .error
        userMessage = "No se pudo iniciar el micrófono. Comprueba el permiso y vuelve a intentarlo."
        Task { await call.end() }
    }

    private func restoreRegistration() {
        do { guard let registration = try store.loadDeviceRegistration() else { return }; service = try serviceFactory(registration); self.registration = registration; hasPairedDevice = true; serverName = registration.baseURL.host ?? "Moa"; state = .ready }
        catch { try? store.clearDeviceRegistration(); userMessage = "La credencial local no está disponible. Empareja Pulse de nuevo." }
    }

    private func append(_ text: String, owner: Bool, generation: UInt64) {
        guard owns(generation), !text.isEmpty else { return }
        captions = Array((captions + [.init(text: text, isOwner: owner)]).suffix(20))
    }
}
