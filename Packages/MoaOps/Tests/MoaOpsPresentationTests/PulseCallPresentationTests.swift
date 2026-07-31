import Foundation
import XCTest
@testable import MoaOpsCore
@testable import MoaOpsPresentation

@MainActor
final class PulseCallPresentationTests: XCTestCase {
    func testQRPairingRemainsAnAvailableFirstClassPath() async throws {
        let store = PresentationStore()
        let registration = try registration()
        let model = PulseCallAppModel(store: store, voice: PresentationVoice(), pairingClaim: { _, _, _ in registration }, serviceFactory: { _ in PresentationService() })
        let encoded = Data(#"{"server_url":"https://moa.example","pairing_payload":"moa-pair-v1:p:s"}"#.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        await model.claimQRCode("moa-pulse-pair-v1:\(encoded)", deviceLabel: "Phone")
        XCTAssertTrue(model.hasPairedDevice)
        XCTAssertEqual(model.rootDestination, .call)
    }

    func testHangupInvalidatesConnectingGenerationAndLateSocketCannotReactivate() async throws {
        let store = try pairedStore()
        let realtime = PresentationRealtime()
        let model = PulseCallAppModel(store: store, voice: PresentationVoice(), realtime: realtime, reconnectDelay: { _ in 0 }, serviceFactory: { _ in PresentationService() })
        model.startCall()
        model.endCall()
        await settle()
        await realtime.emit(.listening)
        await settle()
        XCTAssertFalse(model.isCallActive)
        XCTAssertEqual(model.state, .ended)
        XCTAssertTrue(model.canStartCall)
    }

    func testFailureReconnectsWithOneCancelableReplacementAndDisablesNewStart() async throws {
        let store = try pairedStore()
        let realtime = PresentationRealtime()
        let model = PulseCallAppModel(store: store, voice: PresentationVoice(), realtime: realtime, reconnectDelay: { _ in 0 }, serviceFactory: { _ in PresentationService() })
        model.startCall()
        await settle()
        XCTAssertFalse(model.canStartCall)
        await realtime.emit(.failed)
        await settle()
        let reconnected = await realtime.beginCount()
        XCTAssertGreaterThanOrEqual(reconnected, 2)
        XCTAssertTrue(model.isConnectingOrReconnecting || model.isCallActive)
        model.endCall()
        let count = await realtime.beginCount()
        await settle()
        let finalCount = await realtime.beginCount()
        XCTAssertEqual(finalCount, count)
    }

    func testCaptureStartupFailureHangsUpAndShowsAMicrophoneError() async throws {
        let realtime = PresentationRealtime()
        let model = PulseCallAppModel(store: try pairedStore(), voice: PresentationVoice(captureStarts: false), realtime: realtime, reconnectDelay: { _ in 0 }, serviceFactory: { _ in PresentationService() })
        model.startCall()
        await settle()
        XCTAssertFalse(model.isCallActive)
        XCTAssertEqual(model.state, .error)
        XCTAssertTrue(model.userMessage?.contains("micrófono") == true)
        let ended = await realtime.lastCallEnded()
        XCTAssertTrue(ended)
    }

    func testSpeechStartedFlushesQueuedAssistantPlayback() async throws {
        let realtime = PresentationRealtime()
        let voice = PresentationVoice()
        let model = PulseCallAppModel(store: try pairedStore(), voice: voice, realtime: realtime, reconnectDelay: { _ in 0 }, serviceFactory: { _ in PresentationService() })
        model.startCall()
        await settle()
        await realtime.emitBargeIn()
        await settle()
        XCTAssertEqual(voice.playbackFlushes, 1)
        model.endCall()
    }

    // The model is querying Moa on the owner's behalf (list_sessions, read_session…):
    // the orb must show the thinking vortex instead of a silent listening state.
    func testToolCallShowsResolvingAndReturnsToTheLiveTurn() async throws {
        let realtime = PresentationRealtime()
        let model = PulseCallAppModel(store: try pairedStore(), voice: PresentationVoice(), realtime: realtime, reconnectDelay: { _ in 0 }, resolvingDelay: 0.05, serviceFactory: { _ in PresentationService() })
        model.startCall()
        await settle()
        await realtime.emit(.listening)
        await settle()
        XCTAssertEqual(model.state, .listening)

        await realtime.emit(.toolCallStarted)
        try await waitFor { model.state == .resolving }
        XCTAssertEqual(model.state.orbMode, .thinking)

        await realtime.emit(.toolCallFinished)
        try await waitFor { model.state == .listening }
        model.endCall()
    }

    // A tool answering faster than the delay must not blink the vortex.
    func testFastToolCallNeverShowsResolving() async throws {
        let realtime = PresentationRealtime()
        let model = PulseCallAppModel(store: try pairedStore(), voice: PresentationVoice(), realtime: realtime, reconnectDelay: { _ in 0 }, resolvingDelay: 0.4, serviceFactory: { _ in PresentationService() })
        model.startCall()
        await settle()
        await realtime.emit(.listening)
        await settle()

        await realtime.emit(.toolCallStarted)
        await settle()
        await realtime.emit(.toolCallFinished)
        await settle()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.state, .listening, "a tool shorter than the delay must never reach the orb")
        model.endCall()
    }

    // Chained tools are one single stretch of work for the owner.
    func testChainedToolCallsKeepResolvingUntilTheLastOneReturns() async throws {
        let realtime = PresentationRealtime()
        let model = PulseCallAppModel(store: try pairedStore(), voice: PresentationVoice(), realtime: realtime, reconnectDelay: { _ in 0 }, resolvingDelay: 0.05, serviceFactory: { _ in PresentationService() })
        model.startCall()
        await settle()
        await realtime.emit(.listening)
        await settle()

        await realtime.emit(.toolCallStarted)
        try await waitFor { model.state == .resolving }
        await realtime.emit(.toolCallStarted)
        await settle()
        await realtime.emit(.toolCallFinished)
        await settle()
        XCTAssertEqual(model.state, .resolving, "the vortex belongs to the last tool in flight")

        await realtime.emit(.toolCallFinished)
        try await waitFor { model.state == .listening }
        model.endCall()
    }

    // A tool run during a response goes back to responding, not to listening.
    func testResolvingDuringResponseReturnsToResponding() async throws {
        let realtime = PresentationRealtime()
        let model = PulseCallAppModel(store: try pairedStore(), voice: PresentationVoice(), realtime: realtime, reconnectDelay: { _ in 0 }, resolvingDelay: 0.05, serviceFactory: { _ in PresentationService() })
        model.startCall()
        await settle()
        await realtime.emit(.responding)
        await settle()
        XCTAssertEqual(model.state, .responding)

        await realtime.emit(.toolCallStarted)
        try await waitFor { model.state == .resolving }
        await realtime.emit(.toolCallFinished)
        try await waitFor { model.state == .responding }
        model.endCall()
    }

    // Hanging up with a tool still in flight: nothing will report it back, so the
    // orb must not be left thinking forever.
    func testHangupWithToolInFlightDoesNotStrandResolving() async throws {
        let realtime = PresentationRealtime()
        let model = PulseCallAppModel(store: try pairedStore(), voice: PresentationVoice(), realtime: realtime, reconnectDelay: { _ in 0 }, resolvingDelay: 0.05, serviceFactory: { _ in PresentationService() })
        model.startCall()
        await settle()
        await realtime.emit(.listening)
        await settle()
        await realtime.emit(.toolCallStarted)
        try await waitFor { model.state == .resolving }

        model.endCall()
        await settle()
        XCTAssertEqual(model.state, .ended)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.state, .ended, "a dead call must never leave the orb thinking")
    }

    // Each provider callback hops to the main actor on its own, so a tool's
    // `finished` can be applied before its own `started`. The pair must balance
    // out or the orb stays thinking for the rest of the call.
    func testToolCallFinishedArrivingBeforeItsStartedReturnsToTheLiveTurn() async throws {
        let realtime = PresentationRealtime()
        let model = PulseCallAppModel(store: try pairedStore(), voice: PresentationVoice(), realtime: realtime, reconnectDelay: { _ in 0 }, resolvingDelay: 0.05, serviceFactory: { _ in PresentationService() })
        model.startCall()
        await settle()
        await realtime.emit(.listening)
        await settle()
        XCTAssertEqual(model.state, .listening)

        // Inverted order, forced deterministically instead of relying on scheduling.
        await realtime.emit(.toolCallFinished)
        await settle()
        await realtime.emit(.toolCallStarted)
        await settle()

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.state, .listening, "an inverted pair must not leave the orb thinking")

        // And the counter is balanced: the next real tool still shows the vortex.
        await realtime.emit(.toolCallStarted)
        try await waitFor { model.state == .resolving }
        await realtime.emit(.toolCallFinished)
        try await waitFor { model.state == .listening }
        model.endCall()
    }

    // A tool of a call that was already hung up reports back: the late callback
    // belongs to a dead generation and must not unbalance the next call.
    func testToolCallFinishedAfterHangupDoesNotContaminateTheNextCall() async throws {
        let realtime = PresentationRealtime()
        let model = PulseCallAppModel(store: try pairedStore(), voice: PresentationVoice(), realtime: realtime, reconnectDelay: { _ in 0 }, resolvingDelay: 0.05, serviceFactory: { _ in PresentationService() })
        model.startCall()
        await settle()
        await realtime.emit(.listening)
        await settle()
        model.endCall()
        await settle()
        await realtime.emit(.toolCallFinished)
        await settle()

        model.startCall()
        await settle()
        await realtime.emit(.listening)
        await settle()
        await realtime.emit(.toolCallStarted)
        try await waitFor { model.state == .resolving }
        await realtime.emit(.toolCallFinished)
        try await waitFor { model.state == .listening }
        model.endCall()
    }

    // The owner must be able to see what voice is costing: every response of a
    // direct call feeds the same ledger the Guardián writes into.
    func testDirectCallCountsItsSessionAndRecordsUsageInTheLedger() async throws {
        let realtime = PresentationRealtime()
        let costs = PresentationCostStore()
        let model = PulseCallAppModel(store: try pairedStore(), voice: PresentationVoice(), realtime: realtime, costs: costs, reconnectDelay: { _ in 0 }, serviceFactory: { _ in PresentationService() })
        model.startCall()
        try await waitFor { costs.sessionCount == 1 }
        await realtime.emitUsage(.init(inputAudioTokens: 1_000, outputAudioTokens: 500))
        try await waitFor { model.costSnapshot.today.costUSD > 0 }
        XCTAssertEqual(costs.recordedCount, 1)
        XCTAssertEqual(model.costSnapshot.today.sessions, 1)
        model.endCall()
    }

    // A response billed by a socket that was already hung up still cost money.
    func testUsageArrivingAfterHangupIsStillBilled() async throws {
        let realtime = PresentationRealtime()
        let costs = PresentationCostStore()
        let model = PulseCallAppModel(store: try pairedStore(), voice: PresentationVoice(), realtime: realtime, costs: costs, reconnectDelay: { _ in 0 }, serviceFactory: { _ in PresentationService() })
        model.startCall()
        try await waitFor { costs.sessionCount == 1 }
        model.endCall()
        await settle()
        await realtime.emitUsage(.init(inputAudioTokens: 1_000))
        try await waitFor { costs.recordedCount == 1 }
    }

    func testAmountsAreReadableIncludingLessThanOneCent() {
        XCTAssertEqual(PulseRealtimeCostFormatting.amount(0), "$0,00")
        XCTAssertEqual(PulseRealtimeCostFormatting.amount(0.0004), "<$0,01")
        XCTAssertEqual(PulseRealtimeCostFormatting.amount(0.34), "$0,34")
        XCTAssertEqual(PulseRealtimeCostFormatting.amount(12.5), "$12,50")
        XCTAssertEqual(PulseRealtimeCostFormatting.sessions(1), "1 sesión")
        XCTAssertEqual(PulseRealtimeCostFormatting.sessions(4), "4 sesiones")
    }

    /// Zero maintenance: nothing recorded reads as "—", not as "free".
    func testAnEmptyLedgerShowsPlaceholders() {
        let empty = PulseRealtimeCostSnapshot()
        XCTAssertEqual(PulseRealtimeCostFormatting.bucket(empty.today), "—")
        XCTAssertEqual(PulseRealtimeCostFormatting.lastSession(empty), "—")
        let used = PulseRealtimeCostSnapshot(today: .init(costUSD: 1.2, sessions: 3), month: .init(costUSD: 9, sessions: 20), lastSessionUSD: 0.4)
        XCTAssertEqual(PulseRealtimeCostFormatting.bucket(used.today), "$1,20 · 3 sesiones")
        XCTAssertEqual(PulseRealtimeCostFormatting.lastSession(used), "$0,40")
    }

    private func registration() throws -> PulseDeviceRegistration { try .init(baseURL: URL(string: "https://moa.example")!, deviceID: "device", credential: "device.secret", expiresAt: .distantFuture) }
    private func pairedStore() throws -> PresentationStore { let store = PresentationStore(); try store.saveDeviceRegistration(registration()); return store }
    private func settle() async { for _ in 0..<40 { await Task.yield() } }
    private func waitFor(_ condition: @escaping () async -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met before timeout")
    }
}

private final class PresentationStore: PulseSecureStore, @unchecked Sendable {
    private var value: PulseDeviceRegistration?
    func loadDeviceRegistration() throws -> PulseDeviceRegistration? { value }
    func saveDeviceRegistration(_ registration: PulseDeviceRegistration) throws { value = registration }
    func clearDeviceRegistration() throws { value = nil }
}

@MainActor
private final class PresentationVoice: PulseVoiceControlling {
    var onPCM16: ((Data) -> Void)?
    var onInterruption: (() -> Void)?
    var onPlaybackFailure: (() -> Void)?
    var onInputLevel: ((Float) -> Void)?
    var onOutputLevel: ((Float) -> Void)?
    private let captureStarts: Bool
    private(set) var playbackFlushes = 0
    init(captureStarts: Bool = true) { self.captureStarts = captureStarts }
    func startContinuousCapture() async -> Bool { captureStarts }
    func stopContinuousCapture() {}
    func playPCM16(_: Data) {}
    func flushPlayback() { playbackFlushes += 1 }
    func stopAll() {}
    func setMuted(_: Bool) {}
}

private final class PresentationService: PulseCallServing, @unchecked Sendable {
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

/// In-memory ledger so a test never reads or writes the device's real totals.
/// Its writes arrive from `@Sendable` provider callbacks, hence the lock.
private final class PresentationCostStore: PulseRealtimeCostStore, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions = 0
    private var recorded: [PulseRealtimeUsage] = []

    func beginSession(at _: Date) { lock.lock(); sessions += 1; lock.unlock() }
    func record(usage: PulseRealtimeUsage, at _: Date) { lock.lock(); recorded.append(usage); lock.unlock() }
    func snapshot(at _: Date) -> PulseRealtimeCostSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let total = recorded.reduce(PulseRealtimeUsage()) { $0 + $1 }
        let cost = PulseRealtimePricing.gptRealtime.costUSD(for: total)
        return .init(today: .init(costUSD: cost, sessions: sessions), month: .init(costUSD: cost, sessions: sessions), lastSessionUSD: recorded.isEmpty ? nil : cost)
    }

    var sessionCount: Int { lock.lock(); defer { lock.unlock() }; return sessions }
    var recordedCount: Int { lock.lock(); defer { lock.unlock() }; return recorded.count }
}

private actor PresentationCall: PulseRealtimeCallControlling {
    func appendPCM16(_: Data) async throws {}
    private var ended = false
    func end() async { ended = true }
    func wasEnded() -> Bool { ended }
}

private actor PresentationRealtime: PulseRealtimeCalling {
    private var count = 0
    private var callback: (@Sendable (PulseRealtimeCallState) -> Void)?
    private var bargeInCallback: (@Sendable () -> Void)?
    private var usageCallback: (@Sendable (PulseRealtimeUsage) -> Void)?
    private var lastCall: PresentationCall?
    func beginCall(credential _: PulseRealtimeClientCredential, configuration _: OpenAIRealtimeProviderConfiguration, executor _: PulseGenericToolExecutor, initialContext _: String, onState: @escaping @Sendable (PulseRealtimeCallState) -> Void, onText _: @escaping @Sendable (String) -> Void, onAudio _: @escaping @Sendable (Data, @escaping @Sendable () -> Void) -> Void, onBargeIn: @escaping @Sendable () -> Void, onUsage: @escaping @Sendable (PulseRealtimeUsage) -> Void) async throws -> any PulseRealtimeCallControlling {
        count += 1; callback = onState; bargeInCallback = onBargeIn; usageCallback = onUsage
        let call = PresentationCall(); lastCall = call
        return call
    }
    func emit(_ event: PulseRealtimeCallState) { callback?(event) }
    func emitBargeIn() { bargeInCallback?() }
    func emitUsage(_ usage: PulseRealtimeUsage) { usageCallback?(usage) }
    func beginCount() -> Int { count }
    func lastCallEnded() async -> Bool {
        guard let lastCall else { return false }
        return await lastCall.wasEnded()
    }
}
