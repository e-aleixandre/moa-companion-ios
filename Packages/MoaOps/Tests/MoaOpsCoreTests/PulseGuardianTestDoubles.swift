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
    var onInputLevel: ((Float) -> Void)?
    var onOutputLevel: ((Float) -> Void)?
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

/// Records the audible cues instead of playing them: the coordinator decides
/// when a transition sounds, and that is what the tests assert.
@MainActor
final class MockEarcons: PulseEarcons {
    private(set) var wakeCount = 0
    private(set) var sleepCount = 0

    func wake() { wakeCount += 1 }
    func sleep() { sleepCount += 1 }
}

/// In-memory presence: no UserDefaults, so a test never inherits the timestamp
/// left behind by another run.
final class MockPresenceStore: PulseGuardianPresenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date?
    private var reads = 0

    init(lastListeningAt: Date? = nil) { stored = lastListeningAt }

    func lastListeningAt() -> Date? { lock.withLock { reads += 1; return stored } }
    func recordListening(at date: Date) { lock.withLock { stored = date } }

    /// Every presence decision starts by reading the stored timestamp, so this
    /// counter is the observable proof that a heartbeat tick actually ran —
    /// including the ticks that end up rejecting the write.
    var readCount: Int { lock.withLock { reads } }
}

/// A hand-wound clock so a test can move time forward without sleeping.
final class MockClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date) { current = now }

    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
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
    func ackedTerminationList() -> [String] { ackedTerminations }
    func ackedItemList() -> [String] { ackedItems }
}

actor MockRealtimeCall: PulseRealtimeCallControlling {
    private(set) var appendedPCM: [Data] = []
    private(set) var narrations: [String] = []
    private(set) var narrationAttempts = 0
    private(set) var ended = false
    private var ready: Bool
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    // A narration can be parked and later failed on purpose, reproducing the
    // socket that dies while Pulse has the floor and only reports it back once
    // the coordinator has already moved on to another session.
    private var narrationHeld = false
    private var narrationWaiters: [CheckedContinuation<Void, Never>] = []
    private var narrationFailure: Error?

    init(startsReady: Bool = true) { self.ready = startsReady }

    func appendPCM16(_ pcm: Data) async throws { appendedPCM.append(pcm) }
    func requestGuardianNarration(_ event: String) async throws {
        narrationAttempts += 1
        if narrationHeld {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if narrationHeld { narrationWaiters.append(c) } else { c.resume() }
            }
        }
        if let failure = narrationFailure { throw failure }
        narrations.append(event)
    }

    func holdNarrations() { narrationHeld = true }
    func failNarrations(_ error: Error) { narrationFailure = error }
    func releaseNarrations() {
        narrationHeld = false
        let waiters = narrationWaiters
        narrationWaiters.removeAll()
        for w in waiters { w.resume() }
    }
    func narrationAttemptCount() -> Int { narrationAttempts }
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
    // `end()` deliberately does not release a held narration: a dying socket is
    // exactly the case where the narration only reports its failure much later.
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
    private var onTurn: (@Sendable (PulseTranscriptSpeaker, String) -> Void)?
    private var onAudio: (@Sendable (Data, @escaping @Sendable () -> Void) -> Void)?
    private var onBargeIn: (@Sendable () -> Void)?
    private var onUsage: (@Sendable (PulseRealtimeUsage) -> Void)?
    private var call: MockRealtimeCall?

    init(startsReady: Bool = true) { self.startsReady = startsReady }

    func beginCall(credential _: PulseRealtimeClientCredential, configuration _: OpenAIRealtimeProviderConfiguration, executor _: PulseGenericToolExecutor, initialContext: String, onState: @escaping @Sendable (PulseRealtimeCallState) -> Void, onText _: @escaping @Sendable (String) -> Void, onTurn: @escaping @Sendable (PulseTranscriptSpeaker, String) -> Void, onAudio: @escaping @Sendable (Data, @escaping @Sendable () -> Void) -> Void, onBargeIn: @escaping @Sendable () -> Void, onUsage: @escaping @Sendable (PulseRealtimeUsage) -> Void) async throws -> any PulseRealtimeCallControlling {
        beginCount += 1
        lastInitialContext = initialContext
        self.onState = onState
        self.onTurn = onTurn
        self.onAudio = onAudio
        self.onBargeIn = onBargeIn
        self.onUsage = onUsage
        let call = MockRealtimeCall(startsReady: startsReady)
        self.call = call
        return call
    }

    func emit(_ state: PulseRealtimeCallState) { onState?(state) }
    /// One Moa tool call the app runs on the model's behalf. Split in two so a
    /// test can hold a tool "in flight" for as long as it needs, including
    /// chaining several before any of them answers.
    func emitToolCallStarted() { onState?(.toolCallStarted) }
    func emitToolCallFinished() { onState?(.toolCallFinished) }
    func emitAudio(_ pcm: Data) { onAudio?(pcm, {}) }
    /// One finished transcribed turn, the way the provider reports the owner's
    /// `input_audio_transcription.completed` and Pulse's own output transcript.
    func emitTurn(_ speaker: PulseTranscriptSpeaker, _ text: String) { onTurn?(speaker, text) }
    func emitUsage(_ usage: PulseRealtimeUsage) { onUsage?(usage) }
    func emitBargeIn() { onBargeIn?() }
    func begins() -> Int { beginCount }
    func initialContext() -> String { lastInitialContext }
    func currentCall() -> MockRealtimeCall? { call }
}

/// In-memory ledger: the totals of one test never leak into the next run, and
/// the handler that writes them fires off the coordinator's actor, so the
/// storage carries its own lock like the other doubles here.
final class MockCostStore: PulseRealtimeCostStore, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions = 0
    private var recorded: [PulseRealtimeUsage] = []

    func beginSession(at _: Date) { lock.withLock { sessions += 1 } }
    func record(usage: PulseRealtimeUsage, at _: Date) { lock.withLock { recorded.append(usage) } }
    func snapshot(at _: Date) -> PulseRealtimeCostSnapshot {
        lock.withLock {
            let total = recorded.reduce(PulseRealtimeUsage()) { $0 + $1 }
            let cost = PulseRealtimePricing.gptRealtime.costUSD(for: total)
            return .init(today: .init(costUSD: cost, sessions: sessions), month: .init(costUSD: cost, sessions: sessions), lastSessionUSD: recorded.isEmpty ? nil : cost)
        }
    }

    var sessionCount: Int { lock.withLock { sessions } }
    var recordedUsage: [PulseRealtimeUsage] { lock.withLock { recorded } }
}

/// Records every state the coordinator published. The handler is `@Sendable`
/// and fires from the coordinator's actor, so the storage carries its own lock
/// like the other doubles here.
final class GuardianStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [PulseGuardianState] = []

    func append(_ state: PulseGuardianState) { lock.withLock { states.append(state) } }
    func count(of state: PulseGuardianState) -> Int { lock.withLock { states.filter { $0 == state }.count } }
}

final class MockGuardianService: PulseCallServing, @unchecked Sendable {
    /// When set, minting a client secret fails — the way it does when the phone
    /// has no coverage, which is also why the Realtime socket dropped.
    var mintFailure: Error? {
        get { lock.withLock { storedMintFailure } }
        set { lock.withLock { storedMintFailure = newValue } }
    }

    /// How many times a client secret was requested, to assert how much of the
    /// reconnection budget was actually spent.
    var mintCount: Int { lock.withLock { storedMintCount } }

    private let lock = NSLock()
    private var storedMintFailure: Error?
    private var storedMintCount = 0

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
    func mintRealtimeClientSecret() async throws -> PulseRealtimeClientCredential {
        lock.withLock { storedMintCount += 1 }
        if let failure = mintFailure { throw failure }
        return try JSONDecoder.moaOps.decode(PulseRealtimeClientCredential.self, from: Data(#"{"client_secret":"ek_fixture","expires_at":1900000000,"transport":"websocket","endpoint":"wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1","model":"gpt-realtime-2.1"}"#.utf8))
    }
    func invalidate() async {}
}
