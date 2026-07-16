import Foundation
@testable import MoaOpsCore

/// In-memory doubles for the guardian engine. They never touch AVAudioEngine,
/// Speech, or a network socket: only the pure coordination logic is exercised.

@MainActor
final class MockWakeWord: PulseWakeWordDetecting {
    var onWakeWord: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var appended: [Data] = []
    var available = true

    func start() async -> Bool { startCount += 1; return available }
    func stop() { stopCount += 1 }
    func appendPCM16(_ pcm: Data) { appended.append(pcm) }
    func fire() { onWakeWord?() }
}

@MainActor
final class MockVoice: PulseVoiceControlling {
    var onPCM16: ((Data) -> Void)?
    var onInterruption: (() -> Void)?
    var onPlaybackFailure: (() -> Void)?
    private var playbackDrained: (() -> Void)?
    private var temporaryInterruption: (() -> Void)?
    private var captureResumed: (() -> Void)?
    private(set) var flushCount = 0
    private(set) var played: [Data] = []
    private let captureStarts: Bool

    init(captureStarts: Bool = true) { self.captureStarts = captureStarts }

    func startContinuousCapture() async -> Bool { captureStarts }
    func stopContinuousCapture() {}
    func playPCM16(_ pcm: Data) { played.append(pcm) }
    func flushPlayback() { flushCount += 1 }
    func stopAll() {}
    func setMuted(_: Bool) {}
    func setPlaybackDrainedHandler(_ handler: @escaping () -> Void) { playbackDrained = handler }
    func setTemporaryInterruptionHandler(_ handler: @escaping () -> Void) { temporaryInterruption = handler }
    func setCaptureResumedHandler(_ handler: @escaping () -> Void) { captureResumed = handler }
    func setRouteChangedHandler(_: @escaping () -> Void) {}
    func hasPrivateOutputRoute() -> Bool { true }

    func emitPCM(_ pcm: Data) { onPCM16?(pcm) }
    func drainPlayback() { playbackDrained?() }
    func interruptTemporarily() { temporaryInterruption?() }
    func resumeCapture() { captureResumed?() }
}

actor MockAttentionChannel: PulseAttentionChanneling {
    private var eventHandler: (@Sendable (PulseAttentionServerMessage) -> Void)?
    private var stateHandler: (@Sendable (PulseAttentionWebSocket.State) -> Void)?
    private(set) var ackedItems: [String] = []
    private(set) var ackedTerminations: [String] = []

    func start(onEvent: @escaping @Sendable (PulseAttentionServerMessage) -> Void, onState: @escaping @Sendable (PulseAttentionWebSocket.State) -> Void) {
        eventHandler = onEvent
        stateHandler = onState
        onState(.connected)
    }

    func stop() {}
    func reclaim() {}
    func ack(itemID: String) async { ackedItems.append(itemID) }
    func ackTermination(terminationID: String) async { ackedTerminations.append(terminationID) }

    func emit(_ message: PulseAttentionServerMessage) { eventHandler?(message) }
    func emitState(_ state: PulseAttentionWebSocket.State) { stateHandler?(state) }
}

actor MockRealtimeCall: PulseRealtimeCallControlling {
    private(set) var appendedPCM: [Data] = []
    private(set) var narrations: [String] = []
    private(set) var ended = false
    private var ready: Bool
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    init(startsReady: Bool = true) { self.ready = startsReady }

    func appendPCM16(_ pcm: Data) async throws { appendedPCM.append(pcm) }
    func requestGuardianNarration(_ event: String) async throws { narrations.append(event) }
    func awaitSessionReady() async {
        if ready { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if ready { c.resume() } else { readyWaiters.append(c) }
        }
    }
    func markReady() {
        guard !ready else { return }
        ready = true
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for w in waiters { w.resume() }
    }
    func end() async { ended = true; markReady() }

    func appendedCount() -> Int { appendedPCM.count }
    func firstAppended() -> Data? { appendedPCM.first }
    func allAppended() -> [Data] { appendedPCM }
    func wasEnded() -> Bool { ended }
    func recordedNarrations() -> [String] { narrations }
}

actor MockRealtime: PulseRealtimeCalling {
    private(set) var beginCount = 0
    private(set) var lastInitialContext = ""
    private let startsReady: Bool
    private var onState: (@Sendable (PulseRealtimeCallState) -> Void)?
    private var onBargeIn: (@Sendable () -> Void)?
    private var call: MockRealtimeCall?

    init(startsReady: Bool = true) { self.startsReady = startsReady }

    func beginCall(credential _: PulseRealtimeClientCredential, configuration _: OpenAIRealtimeProviderConfiguration, executor _: PulseGenericToolExecutor, initialContext: String, onState: @escaping @Sendable (PulseRealtimeCallState) -> Void, onText _: @escaping @Sendable (String) -> Void, onAudio _: @escaping @Sendable (Data, @escaping @Sendable () -> Void) -> Void, onBargeIn: @escaping @Sendable () -> Void) async throws -> any PulseRealtimeCallControlling {
        beginCount += 1
        lastInitialContext = initialContext
        self.onState = onState
        self.onBargeIn = onBargeIn
        let call = MockRealtimeCall(startsReady: startsReady)
        self.call = call
        return call
    }

    func emit(_ state: PulseRealtimeCallState) { onState?(state) }
    func emitBargeIn() { onBargeIn?() }
    func begins() -> Int { beginCount }
    func initialContext() -> String { lastInitialContext }
    func currentCall() -> MockRealtimeCall? { call }
}

final class MockGuardianService: PulseCallServing, @unchecked Sendable {
    func listSessions() async throws -> [MoaServeSessionInfo] { [] }
    func attention() async throws -> MoaServeAttentionResponse { try JSONDecoder.moaOps.decode(MoaServeAttentionResponse.self, from: Data(#"{"items":[]}"#.utf8)) }
    func readSession(sessionID: String, limit: Int, cursor: String?) async throws -> MoaServeConversationPage { throw PulseCallError.operationUnavailable }
    func readToolDetail(sessionID: String, itemID: String) async throws -> MoaServeToolDetail { throw PulseCallError.operationUnavailable }
    func listSubagents(sessionID: String) async throws -> MoaServeSubagentListResponse { throw PulseCallError.operationUnavailable }
    func readSubagent(sessionID: String, jobID: String, limit: Int, cursor: String?) async throws -> MoaServeSubagentPage { throw PulseCallError.operationUnavailable }
    func sendMessage(sessionID: String, text: String) async throws -> MoaServeSendMessageResponse { throw PulseCallError.operationUnavailable }
    func respondAsk(sessionID: String, askID: String, answers: [String]) async throws {}
    func decidePermission(sessionID: String, permissionID: String, approved: Bool, feedback: String?) async throws {}
    func createSession(title: String?, cwd: String?, model: String?) async throws -> MoaServeSessionInfo { throw PulseCallError.operationUnavailable }
    func resumeSession(sessionID: String) async throws -> MoaServeSessionInfo { throw PulseCallError.operationUnavailable }
    func cancelRun(sessionID: String) async throws {}
    func archiveSession(sessionID: String) async throws -> MoaServeArchiveSessionResponse { throw PulseCallError.operationUnavailable }
    func mintRealtimeClientSecret() async throws -> PulseRealtimeClientCredential { try JSONDecoder.moaOps.decode(PulseRealtimeClientCredential.self, from: Data(#"{"client_secret":"ek_fixture","expires_at":1900000000,"transport":"websocket","endpoint":"wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1","model":"gpt-realtime-2.1"}"#.utf8)) }
    func invalidate() async {}
}
