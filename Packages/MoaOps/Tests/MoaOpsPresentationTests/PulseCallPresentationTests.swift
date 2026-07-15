import Foundation
import XCTest
@testable import MoaOpsCore
@testable import MoaOpsPresentation

@MainActor
final class PulseCallPresentationTests: XCTestCase {
    func testRootSelectsPairingUntilAKeychainRegistrationExists() throws {
        let empty = CallTestStore()
        let pairingModel = PulseCallAppModel(store: empty, voice: CallTestVoice(), serviceFactory: { _ in CallTestService() })
        XCTAssertEqual(pairingModel.rootDestination, .pairing)

        let paired = CallTestStore()
        try paired.saveDeviceRegistration(PulseDeviceRegistration(baseURL: URL(string: "https://moa.example")!, deviceID: "dev", credential: "dev.secret", expiresAt: .distantFuture))
        let callModel = PulseCallAppModel(store: paired, voice: CallTestVoice(), serviceFactory: { _ in CallTestService() })
        XCTAssertEqual(callModel.rootDestination, .call)
        XCTAssertNotEqual(callModel.rootDestination, .pairing, "The primary host must not select the old dashboard/tabs")
    }

    func testQRClaimUsesEnvelopeValuesWithoutPublishingOneUsePayload() async throws {
        let store = CallTestStore()
        let recorder = PairingClaimRecorder()
        let registration = try PulseDeviceRegistration(
            baseURL: URL(string: "https://moa.example")!,
            deviceID: "pulse_phone",
            credential: "pulse_phone.device-secret",
            expiresAt: .distantFuture
        )
        let model = PulseCallAppModel(
            store: store,
            voice: CallTestVoice(),
            pairingClaim: { configuration, payload, label in
                await recorder.record(configuration: configuration, payload: payload, label: label)
                return registration
            },
            serviceFactory: { _ in CallTestService() }
        )
        let qr = "moa-pulse-pair-v1:" + base64URL(#"{"server_url":"https://moa.example","pairing_payload":"moa-pair-v1:pair_abc:one-use-secret"}"#)

        await model.claimQRCode(qr, deviceLabel: "El iPhone de Ana")

        let claim = await recorder.claim
        XCTAssertEqual(claim?.configuration.baseURL, URL(string: "https://moa.example"))
        XCTAssertEqual(claim?.payload.pairingID, "pair_abc")
        XCTAssertEqual(claim?.payload.secret, "one-use-secret")
        XCTAssertEqual(claim?.label, "El iPhone de Ana")
        XCTAssertNotNil(try store.loadDeviceRegistration())
        XCTAssertTrue(model.hasPairedDevice)
        XCTAssertFalse(String(describing: model).contains("one-use-secret"))
    }

    func testRefreshBuildsSpanishSafeBriefAndOfflineKeepsOnlyTransientSnapshot() async throws {
        let store = CallTestStore()
        try store.saveDeviceRegistration(PulseDeviceRegistration(baseURL: URL(string: "https://moa.example")!, deviceID: "dev", credential: "dev.secret", expiresAt: .distantFuture))
        let service = CallTestService()
        service.pulseResults = [.success(try fixturePulse()), .failure(.transport)]
        let voice = CallTestVoice()
        let model = PulseCallAppModel(store: store, voice: voice, serviceFactory: { _ in service })

        await model.refresh()
        XCTAssertEqual(model.state, .ready)
        XCTAssertTrue(model.captions.last?.text.contains("solicitud de permiso") == true)
        XCTAssertTrue(model.captions.last?.provenance == .moaObserved)
        XCTAssertNotNil(model.snapshot)

        await model.refresh()
        XCTAssertEqual(model.state, .offline)
        XCTAssertTrue(model.freshnessLabel.contains("Último estado"))
        XCTAssertTrue(model.userMessage?.contains("no enviará ni encolará") == true)
        XCTAssertTrue(model.captions.last?.text.contains("último estado conocido") == true)
    }

    func testDisconnectedClearsKeychainRegistrationAndAllTransientCallState() throws {
        let store = CallTestStore()
        try store.saveDeviceRegistration(PulseDeviceRegistration(baseURL: URL(string: "https://moa.example")!, deviceID: "dev", credential: "dev.secret", expiresAt: .distantFuture))
        let model = PulseCallAppModel(store: store, voice: CallTestVoice(), serviceFactory: { _ in CallTestService() })

        model.disconnectAndClearLocalCredential()

        XCTAssertEqual(model.rootDestination, .pairing)
        XCTAssertNil(try store.loadDeviceRegistration())
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.captions.isEmpty)
        XCTAssertEqual(model.state, .disconnected)
    }

    func testUnconfiguredProviderStaysDeterministicInsteadOfPretendingToBeAnLLM() async throws {
        let store = CallTestStore()
        try store.saveDeviceRegistration(PulseDeviceRegistration(baseURL: URL(string: "https://moa.example")!, deviceID: "dev", credential: "dev.secret", expiresAt: .distantFuture))
        let service = CallTestService()
        service.pulseResults = [.success(try fixturePulse())]
        let model = PulseCallAppModel(store: store, voice: CallTestVoice(), serviceFactory: { _ in service })
        await model.refresh()

        await model.submitText("¿Qué está bloqueado?")

        XCTAssertFalse(model.providerConfigured)
        XCTAssertTrue(model.captions.contains { $0.text.contains("¿Quieres que explique el bloqueo") })
        XCTAssertEqual(model.state, .ready)
    }

    func testPTTUnavailableKeepsTextFallbackAndInterruptionDoesNotLeaveListening() async throws {
        let store = try pairedStore()
        let service = CallTestService()
        service.pulseResults = [.success(try fixturePulse())]
        let voice = CallTestVoice(availability: .unavailable)
        let model = PulseCallAppModel(store: store, voice: voice, serviceFactory: { _ in service })
        await model.refresh()
        model.beginPushToTalk()
        await settle()
        XCTAssertEqual(model.voiceUnavailable, true)
        XCTAssertNotEqual(model.pttState, .listening)
    }

    func testFailedEphemeralMintCleansCaptureAndAllowsTheNextPress() async throws {
        let store = try pairedStore()
        let service = RealtimeCallTestService()
        service.pulseResults = [.success(try fixturePulse())]
        service.mintResults = [.failure(.transport), .failure(.transport)]
        let voice = CallTestVoice()
        let model = PulseCallAppModel(store: store, voice: voice, serviceFactory: { _ in service })
        await model.refresh()

        model.beginPushToTalk()
        await settle()
        XCTAssertEqual(model.pttState, .idle)
        XCTAssertFalse(model.isTurnBusy)
        XCTAssertNil(voice.activeCapture)
        XCTAssertTrue(model.userMessage?.contains("estado de envío no pudo confirmarse") == true)

        model.beginPushToTalk()
        await settle()
        XCTAssertEqual(voice.captures.count, 2, "A terminal mint failure must not wedge the next PTT press")
        XCTAssertEqual(model.pttState, .idle)
        XCTAssertFalse(model.isTurnBusy)
    }

    func testReviewPTTStopsNarrationThenConfirmsOrCancelsWithoutProviderTurn() async throws {
        let store = try pairedStore()
        let service = CallTestService()
        service.pulseResults = [.success(try fixturePulse())]
        let voice = CallTestVoice()
        let model = PulseCallAppModel(store: store, voice: voice, serviceFactory: { _ in service })
        await model.refresh()

        model.present(review: try fixtureReview())
        model.beginPushToTalk()
        await settle()

        XCTAssertEqual(model.state, .review, "Review must remain visible while its yes/no answer is captured")
        XCTAssertEqual(model.pttState, .listening)
        XCTAssertEqual(Array(voice.events.prefix(2)), ["stopNarration", "beginReviewCapture"])

        voice.emitTranscript("sí", isFinal: true)
        await settle()
        XCTAssertEqual(service.confirmCalls, 1)
        XCTAssertNil(model.pendingReview)
        voice.emitTranscript("sí", isFinal: true)
        await settle()
        XCTAssertEqual(service.confirmCalls, 1, "A second yes cannot confirm a review that is no longer visible")

        model.present(review: try fixtureReview(operationID: "ZbCdEfGhIjKlMnOpQrStUvWx"))
        model.beginPushToTalk()
        await settle()
        voice.emitTranscript("no", isFinal: true)
        await settle()
        XCTAssertEqual(service.confirmCalls, 1)
        XCTAssertNil(model.pendingReview)

        model.present(review: try fixtureReview(operationID: "YbCdEfGhIjKlMnOpQrStUvWx"))
        model.beginPushToTalk()
        await settle()
        voice.emitTranscript("quizá después", isFinal: true)
        await settle()
        XCTAssertEqual(service.confirmCalls, 1)
        XCTAssertNotNil(model.pendingReview)
        XCTAssertEqual(model.state, .review)
        XCTAssertTrue(model.captions.last?.text.contains("Di sí") == true)
    }

    func testReviewPTTInterruptionKeepsReviewAndNeverOpensProvider() async throws {
        let store = try pairedStore()
        let service = CallTestService()
        service.pulseResults = [.success(try fixturePulse())]
        let voice = CallTestVoice()
        let provider = RecordingProvider()
        let model = PulseCallAppModel(
            store: store,
            voice: voice,
            providerFactory: { _, _, _, _ in provider },
            serviceFactory: { _ in service }
        )
        await model.refresh()
        model.present(review: try fixtureReview())

        model.beginPushToTalk()
        await settle()
        let interruptedCapture = try XCTUnwrap(voice.activeCapture)
        voice.emitInterruption(capture: interruptedCapture)
        // Speech can queue a final result after cancellation. It carries the
        // old token, so it must be ignored before it can reach confirmation.
        voice.emitTranscript("sí", isFinal: true, capture: interruptedCapture)
        await settle()

        XCTAssertEqual(model.pttState, .interrupted)
        XCTAssertEqual(model.state, .review)
        XCTAssertNotNil(model.pendingReview)
        XCTAssertEqual(service.confirmCalls, 0)
        XCTAssertEqual(service.prepareCalls, 0)
        let providerCalls = await provider.callCount()
        XCTAssertEqual(providerCalls, 0, "A late interrupted yes must not open a provider turn")
    }

    func testOneGlobalTurnReservationRejectsConcurrentVoiceAndTextWithoutOrphanReview() async throws {
        let store = try pairedStore()
        let service = RealtimeCallTestService()
        service.pulseResults = [.success(try fixturePulse())]
        let prepared = try fixturePreparedResponse(operationID: "CbCdEfGhIjKlMnOpQrStUvWx")
        service.prepareResults = [.success(prepared)]
        let voice = CallTestVoice(reportsAvailability: false)
        let barrier = PrepareBarrier()
        let model = PulseCallAppModel(
            store: store,
            voice: voice,
            providerFactory: { service, _, _, _ in
                BlockingPrepareProvider(service: service, barrier: barrier)
            },
            serviceFactory: { _ in service }
        )
        await model.refresh()

        // First turn arrives by voice and reserves before its provider can
        // prepare. The barrier makes the second submission deterministic.
        model.beginPushToTalk()
        await settle()
        let firstCapture = try XCTUnwrap(voice.activeCapture)
        voice.emitTranscript("continúa la entrega", isFinal: true, capture: firstCapture)
        await barrier.waitForFirstArrival()

        await model.submitText("prepara otra instrucción")
        model.beginPushToTalk()
        await settle()

        let arrivalsBeforeRelease = await barrier.arrivalCount()
        XCTAssertEqual(arrivalsBeforeRelease, 1)
        XCTAssertEqual(voice.captures.count, 1, "A busy provider turn cannot open a second PTT capture")
        XCTAssertEqual(service.prepareCalls, 0, "The first prepare remains reserved behind the barrier")
        XCTAssertTrue(model.captions.contains { $0.text.contains("está atendiendo un turno") })

        await barrier.release()
        await settle()

        XCTAssertEqual(service.prepareCalls, 1)
        XCTAssertEqual(service.preparedOperationIDs, ["CbCdEfGhIjKlMnOpQrStUvWx"])
        XCTAssertEqual(model.pendingReview?.operationID, "CbCdEfGhIjKlMnOpQrStUvWx")
        XCTAssertTrue(model.isTurnBusy, "The reservation remains held while the one visible review exists")
        let arrivalsAfterRelease = await barrier.arrivalCount()
        XCTAssertEqual(arrivalsAfterRelease, 1)
    }

    func testStreamDropClosesWritesAndOnlyAuthoritativeRefreshRestoresThem() async throws {
        let store = try pairedStore()
        let service = CallTestService()
        service.pulseResults = [.success(try fixturePulse()), .success(try fixturePulse())]
        service.streamEvents = [
            .reconnecting(attempt: 1),
            .snapshot(.init(version: 2, snapshot: .init(projects: []), isInitial: false)),
        ]
        let model = PulseCallAppModel(
            store: store,
            voice: CallTestVoice(),
            streamGraceInterval: 0.01,
            streamOfflineInterval: 0.02,
            serviceFactory: { _ in service }
        )

        await model.refresh()
        await wait(seconds: 0.015)
        XCTAssertEqual(model.state, .stale)
        XCTAssertFalse(model.hasFreshAuthoritativeProjection)
        XCTAssertFalse(model.operationsAreAvailable)
        XCTAssertNil(model.brief, "An old briefing must not remain current after stream grace expires")
        XCTAssertTrue(model.freshnessLabel.contains("Último estado conocido"))

        model.present(review: try fixtureReview())
        await model.confirmCurrentReview()
        XCTAssertEqual(service.confirmCalls, 0, "No review confirmation may write while stale")
        XCTAssertEqual(model.state, .review)

        // A stream snapshot arrived above but could not reopen writes. A fresh
        // successful Pulse plus sitrep refresh is the only restoration path.
        await model.refresh()
        XCTAssertTrue(model.hasFreshAuthoritativeProjection)
        XCTAssertTrue(model.operationsAreAvailable)
        XCTAssertEqual(model.state, .review)
        model.cancelReview()
        XCTAssertEqual(model.state, .ready)
    }

    func testProlongedStreamDropAndForegroundKeepWritesClosedUntilRefresh() async throws {
        let store = try pairedStore()
        let service = CallTestService()
        service.pulseResults = [.success(try fixturePulse()), .success(try fixturePulse())]
        service.streamEvents = [.reconnecting(attempt: 1)]
        let model = PulseCallAppModel(
            store: store,
            voice: CallTestVoice(),
            streamGraceInterval: 0.005,
            streamOfflineInterval: 0.01,
            serviceFactory: { _ in service }
        )
        await model.refresh()
        await wait(seconds: 0.08)
        XCTAssertEqual(model.state, .offline)
        XCTAssertFalse(model.operationsAreAvailable)

        model.setForegroundActive(false)
        XCTAssertFalse(model.operationsAreAvailable)
        model.setForegroundActive(true)
        await settle()
        XCTAssertEqual(model.state, .ready)
        XCTAssertTrue(model.hasFreshAuthoritativeProjection)
        XCTAssertTrue(model.operationsAreAvailable)
    }

    func testCompletedStreamDoesNotRetainModelThroughFailureTimer() async throws {
        let store = try pairedStore()
        let service = CallTestService()
        service.pulseResults = [.success(try fixturePulse())]
        weak var releasedModel: PulseCallAppModel?

        do {
            let model = PulseCallAppModel(
                store: store,
                voice: CallTestVoice(),
                streamGraceInterval: 60,
                streamOfflineInterval: 60,
                serviceFactory: { _ in service }
            )
            await model.refresh()
            await settle()
            releasedModel = model
        }

        for _ in 0..<20 where releasedModel != nil { await Task.yield() }
        XCTAssertNil(releasedModel)
    }

    private func pairedStore() throws -> CallTestStore {
        let store = CallTestStore()
        try store.saveDeviceRegistration(PulseDeviceRegistration(baseURL: URL(string: "https://moa.example")!, deviceID: "dev", credential: "dev.secret", expiresAt: .distantFuture))
        return store
    }

    private func fixtureReview(operationID: String = "AbCdEfGhIjKlMnOpQrStUvWx") throws -> PulsePendingReview {
        let review = try JSONDecoder.moaOps.decode(PulseOperationReview.self, from: Data(#"{"target":{"id":"s1","title":"Release","project":"/release"},"text":"continúa","action":"steer","risk":"changes","consequence":"delivery is not completion"}"#.utf8))
        return .init(operationID: operationID, kind: .directedInstruction, expiresAt: .distantFuture, review: review)
    }

    private func fixturePreparedResponse(operationID: String) throws -> PulseOperationResponse {
        try JSONDecoder.moaOps.decode(PulseOperationResponse.self, from: Data("""
        {"operation_id":"\(operationID)","kind":"directed_instruction","status":"pending_confirmation","expires_at":"2027-01-01T00:00:00Z","review":{"target":{"id":"s1","title":"Release","project":"/release"},"text":"continúa","action":"steer","risk":"changes","consequence":"delivery is not completion"}}
        """.utf8))
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func base64URL(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func wait(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await settle()
    }

    private func fixturePulse() throws -> OpsPulse {
        try JSONDecoder.moaOps.decode(OpsPulse.self, from: Data(#"{"generated_at":"2026-07-12T12:00:00Z","summary":{"needs_attention":1,"in_progress":1,"stale_work":0,"on_track":0,"changes":0},"needs_attention":[{"id":"a","session":{"id":"s1","title":"Release","project":"/release"},"category":"permission_needed","priority":1,"lifecycle":"running","activity":"permission","freshness":"fresh","facts":[{"kind":"activity","value":"permission","provenance":"observed"}]}],"in_progress":[{"id":"b","session":{"id":"s2","title":"Build","project":"/build"},"category":"in_progress","lifecycle":"running","activity":"running","freshness":"fresh","facts":[]}],"stale_work":[],"on_track":[],"changes":{"requested":false,"until":"2026-07-12T12:00:00Z","items":[],"next_cursor":"cursor","has_more":false}}"#.utf8))
    }
}

private final class CallTestStore: PulseSecureStore, @unchecked Sendable {
    private var registration: PulseDeviceRegistration?
    private var key: String?
    func loadDeviceRegistration() throws -> PulseDeviceRegistration? { registration }
    func saveDeviceRegistration(_ registration: PulseDeviceRegistration) throws { self.registration = registration }
    func clearDeviceRegistration() throws { registration = nil }
}

@MainActor
private final class CallTestVoice: PulseVoiceControlling {
    var onTranscript: ((PulseVoiceCaptureToken, String, Bool) -> Void)?
    var onInterruption: ((PulseVoiceCaptureToken) -> Void)?
    var onAvailability: ((PulseVoiceCaptureToken, PulseVoiceAvailability) -> Void)?
    var onPCM16: ((PulseVoiceCaptureToken, Data) -> Void)?
    private let availability: PulseVoiceAvailability
    private let reportsAvailability: Bool
    private(set) var events: [String] = []
    private(set) var activeCapture: PulseVoiceCaptureToken?
    private(set) var captures: [PulseVoiceCaptureToken] = []

    init(availability: PulseVoiceAvailability = .available, reportsAvailability: Bool = true) {
        self.availability = availability
        self.reportsAvailability = reportsAvailability
    }
    func stopSpeakingForCapture() { events.append("stopNarration") }
    func beginPushToTalk(capture: PulseVoiceCaptureToken) async {
        events.append("beginCapture")
        activeCapture = capture
        captures.append(capture)
        if reportsAvailability { onAvailability?(capture, availability) }
    }
    func beginReviewConfirmation(capture: PulseVoiceCaptureToken) async {
        events.append("beginReviewCapture")
        activeCapture = capture
        captures.append(capture)
        if reportsAvailability { onAvailability?(capture, availability) }
    }
    func endPushToTalk(capture _: PulseVoiceCaptureToken) { events.append("endCapture") }
    func invalidateCapture() {
        events.append("invalidateCapture")
        activeCapture = nil
    }
    func speak(_: String) {}
    func stopAll() { invalidateCapture() }
    func setMuted(_: Bool) {}
    func setForegroundActive(_ active: Bool) { if !active { invalidateCapture() } }
    func playPCM16(_: Data) {}
    func emitTranscript(_ text: String, isFinal: Bool, capture: PulseVoiceCaptureToken? = nil) {
        guard let capture = capture ?? activeCapture else { return }
        onTranscript?(capture, text, isFinal)
    }
    func emitInterruption(capture: PulseVoiceCaptureToken? = nil) {
        guard let capture = capture ?? activeCapture else { return }
        activeCapture = nil
        onInterruption?(capture)
    }
}

private class CallTestService: PulseCallService, @unchecked Sendable {
    var pulseResults: [Result<OpsPulse, PulseCallError>] = []
    var streamEvents: [PulseOpsStreamEvent] = []
    var prepareResults: [Result<PulseOperationResponse, PulseCallError>] = []
    private(set) var confirmCalls = 0
    private(set) var prepareCalls = 0
    private(set) var preparedOperationIDs: [String] = []

    func loadPulse() async throws -> OpsPulse {
        guard !pulseResults.isEmpty else { throw PulseCallError.transport }
        return try pulseResults.removeFirst().get()
    }
    func loadSitrep() async throws -> OpsBriefing {
        try JSONDecoder.moaOps.decode(OpsBriefing.self, from: Data(#"{"sessions":null,"blockers":[],"spoken":"Panorama seguro."}"#.utf8))
    }
    func loadStatus(target _: String) async throws -> OpsStatusResult { throw PulseCallError.transport }
    func loadSafeConversationEvidence(sessionID _: String) async throws -> ConversationPage { throw PulseCallError.transport }
    func prepareOperation(_: PulseOperationPrepare) async throws -> PulseOperationResponse {
        prepareCalls += 1
        guard !prepareResults.isEmpty else { throw PulseCallError.transport }
        let response = try prepareResults.removeFirst().get()
        preparedOperationIDs.append(response.operationID)
        return response
    }
    func confirmOperation(_ id: String) async throws -> PulseOperationResponse {
        confirmCalls += 1
        return try JSONDecoder.moaOps.decode(PulseOperationResponse.self, from: Data("""
        {"operation_id":"\(id)","kind":"directed_instruction","status":"receipt","receipt":{"operation_id":"\(id)","kind":"directed_instruction","status":"accepted","action":"steer","delivery":"delivered_to_agent","observation":"not_observed","completion":"not_observed","at":"2026-07-12T12:00:00Z"}}
        """.utf8))
    }
    func loadOperation(_: String) async throws -> PulseOperationResponse { throw PulseCallError.transport }
    func startOpsUpdates() async {}
    func stopOpsUpdates() async {}
    func opsUpdates() async -> AsyncStream<OpsSnapshotUpdate> { AsyncStream { $0.finish() } }
    func opsStreamEvents() async -> AsyncStream<PulseOpsStreamEvent> {
        let events = streamEvents
        return AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
    func invalidate() async {}
}

private final class RealtimeCallTestService: CallTestService, PulseRealtimeCredentialIssuing {
    var mintResults: [Result<PulseRealtimeClientCredential, PulseCallError>] = []

    func mintRealtimeClientSecret() async throws -> PulseRealtimeClientCredential {
        if !mintResults.isEmpty { return try mintResults.removeFirst().get() }
        return try JSONDecoder.moaOps.decode(PulseRealtimeClientCredential.self, from: Data(#"{"client_secret":"ek_test","expires_at":1900000000,"transport":"websocket","endpoint":"wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini","model":"gpt-realtime-2.1-mini"}"#.utf8))
    }
}

private actor RecordingProvider: PulseProviderResponding {
    private var calls = 0

    func respond(
        question _: String,
        context _: PulseProviderContext,
        onText _: @escaping @Sendable (String) -> Void
    ) async throws -> PulseProviderAnswer {
        calls += 1
        return .init(text: "respuesta", preparedReviews: [])
    }

    func callCount() -> Int { calls }
}

private actor PairingClaimRecorder {
    struct Claim: Sendable {
        let configuration: PulseServerConfiguration
        let payload: PulsePairingPayload
        let label: String
    }

    private(set) var claim: Claim?

    func record(configuration: PulseServerConfiguration, payload: PulsePairingPayload, label: String) {
        claim = Claim(configuration: configuration, payload: payload, label: label)
    }
}

private actor PrepareBarrier {
    private var arrivals = 0
    private var released = false
    private var firstArrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrivals += 1
        let waiters = firstArrivalWaiters
        firstArrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitForFirstArrival() async {
        guard arrivals > 0 else {
            await withCheckedContinuation { continuation in
                firstArrivalWaiters.append(continuation)
            }
            return
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func arrivalCount() -> Int { arrivals }
}

private actor BlockingPrepareProvider: PulseProviderResponding {
    private let service: any PulseCallService
    private let barrier: PrepareBarrier

    init(service: any PulseCallService, barrier: PrepareBarrier) {
        self.service = service
        self.barrier = barrier
    }

    func respond(
        question: String,
        context _: PulseProviderContext,
        onText _: @escaping @Sendable (String) -> Void
    ) async throws -> PulseProviderAnswer {
        await barrier.arriveAndWait()
        let response = try await service.prepareOperation(.directedInstruction(target: "s1", text: question))
        guard let review = response.pendingReview else { throw PulseCallError.decoding }
        return .init(text: "", preparedReviews: [review])
    }
}
