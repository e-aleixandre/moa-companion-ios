import Foundation
import SwiftUI
import MoaOpsCore

public enum PulseCallState: Equatable, Sendable {
    case disconnected, ready, connecting, reconnecting(attempt: Int), listening, responding, ended, error
    public var spanishLabel: String {
        switch self {
        case .disconnected: "Sin emparejar"
        case .ready: "Lista para llamar"
        case .connecting: "Conectando llamada"
        case let .reconnecting(attempt): "Reconectando (\(attempt))"
        case .listening: "Escuchando"
        case .responding: "Pulse responde"
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
    @Published public var isMuted = false { didSet { voice.setMuted(isMuted) } }

    private let store: any PulseSecureStore
    private let voice: any PulseVoiceControlling
    private let serviceFactory: ServiceFactory
    private let pairingClaim: PairingClaim
    private let realtime: any PulseRealtimeCalling
    private let reconnectDelay: @Sendable (Int) -> TimeInterval
    private var service: (any PulseCallServing)?
    private var call: (any PulseRealtimeCallControlling)?
    private var connectionTask: Task<Void, Never>?
    private var pendingPCM: [Data] = []
    private var pcmDrainGeneration: UInt64?
    private var callGeneration: UInt64 = 0
    private var wantsCall = false

    public init(store: any PulseSecureStore = KeychainPulseSecureStore(), voice: (any PulseVoiceControlling)? = nil, realtime: any PulseRealtimeCalling = OpenAIRealtimeClient(), reconnectDelay: @escaping @Sendable (Int) -> TimeInterval = { min(pow(2, Double(max(0, $0 - 1))), 30) }, pairingClaim: @escaping PairingClaim = { configuration, payload, label in try await PulsePairingClient().claim(configuration: configuration, payload: payload, deviceLabel: label) }, serviceFactory: @escaping ServiceFactory = { try MoaPulseDeviceService(registration: $0) }) {
        self.store = store; self.voice = voice ?? NativePulseVoiceController(); self.realtime = realtime; self.reconnectDelay = reconnectDelay; self.pairingClaim = pairingClaim; self.serviceFactory = serviceFactory
        configureVoice()
        restoreRegistration()
    }

    deinit { connectionTask?.cancel() }
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

    public func endCall() {
        callGeneration &+= 1
        wantsCall = false
        connectionTask?.cancel(); connectionTask = nil
        let oldCall = call; call = nil
        isCallActive = false
        pendingPCM.removeAll(); pcmDrainGeneration = nil
        voice.stopAll()
        state = hasPairedDevice ? .ended : .disconnected
        Task { await oldCall?.end() }
    }

    public func disconnectAndClearLocalCredential() {
        endCall(); let old = service; service = nil; try? store.clearDeviceRegistration(); hasPairedDevice = false; serverName = ""; captions = []; userMessage = nil; state = .disconnected
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
                let call = try await self.realtime.beginCall(credential: credential, configuration: .init(), executor: executor, initialContext: "<estado_inicial_moa>\n\(overview.output)\n</estado_inicial_moa>", onState: { [weak owner] event in let o = owner; Task { @MainActor in o?.apply(event, generation: generation, service: service, attempt: attempt) } }, onText: { [weak owner] text in let o = owner; Task { @MainActor in o?.append(text, owner: false, generation: generation) } }, onAudio: { [weak owner] pcm in let o = owner; Task { @MainActor in guard o?.owns(generation) == true else { return }; o?.voice.playPCM16(pcm) } }, onBargeIn: { [weak owner] in let o = owner; Task { @MainActor in guard o?.owns(generation) == true else { return }; o?.voice.flushPlayback() } })
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
                self.call = nil; self.isCallActive = false; self.voice.stopAll()
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
        case .listening: state = .listening
        case .responding: state = .responding
        case .ended, .failed:
            // Retire this socket generation before ending it: `end()` emits an
            // ended callback and must not schedule a duplicate reconnect.
            let replacementGeneration = callGeneration &+ 1
            callGeneration = replacementGeneration
            let old = call; call = nil; isCallActive = false; pendingPCM.removeAll(); pcmDrainGeneration = nil; voice.stopAll()
            Task { await old?.end() }
            scheduleReconnect(generation: replacementGeneration, service: service, attempt: max(1, attempt + 1))
        }
    }

    private func owns(_ generation: UInt64) -> Bool { wantsCall && generation == callGeneration }

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
        pendingPCM.removeAll()
        pcmDrainGeneration = nil
        voice.stopAll()
        state = .error
        userMessage = "No se pudo iniciar el micrófono. Comprueba el permiso y vuelve a intentarlo."
        Task { await call.end() }
    }

    private func restoreRegistration() {
        do { guard let registration = try store.loadDeviceRegistration() else { return }; service = try serviceFactory(registration); hasPairedDevice = true; serverName = registration.baseURL.host ?? "Moa"; state = .ready }
        catch { try? store.clearDeviceRegistration(); userMessage = "La credencial local no está disponible. Empareja Pulse de nuevo." }
    }

    private func append(_ text: String, owner: Bool, generation: UInt64) {
        guard owns(generation), !text.isEmpty else { return }
        captions = Array((captions + [.init(text: text, isOwner: owner)]).suffix(20))
    }
}
