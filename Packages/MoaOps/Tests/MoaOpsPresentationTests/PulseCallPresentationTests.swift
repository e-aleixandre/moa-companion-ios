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

    private func registration() throws -> PulseDeviceRegistration { try .init(baseURL: URL(string: "https://moa.example")!, deviceID: "device", credential: "device.secret", expiresAt: .distantFuture) }
    private func pairedStore() throws -> PresentationStore { let store = PresentationStore(); try store.saveDeviceRegistration(registration()); return store }
    private func settle() async { for _ in 0..<40 { await Task.yield() } }
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
    private var lastCall: PresentationCall?
    func beginCall(credential _: PulseRealtimeClientCredential, configuration _: OpenAIRealtimeProviderConfiguration, executor _: PulseGenericToolExecutor, initialContext _: String, onState: @escaping @Sendable (PulseRealtimeCallState) -> Void, onText _: @escaping @Sendable (String) -> Void, onAudio _: @escaping @Sendable (Data, @escaping @Sendable () -> Void) -> Void, onBargeIn: @escaping @Sendable () -> Void) async throws -> any PulseRealtimeCallControlling {
        count += 1; callback = onState; bargeInCallback = onBargeIn
        let call = PresentationCall(); lastCall = call
        return call
    }
    func emit(_ event: PulseRealtimeCallState) { callback?(event) }
    func emitBargeIn() { bargeInCallback?() }
    func beginCount() -> Int { count }
    func lastCallEnded() async -> Bool {
        guard let lastCall else { return false }
        return await lastCall.wasEnded()
    }
}
