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

    func testPTTUnavailableKeepsTextFallbackAndInterruptionDoesNotLeaveListening() async {
        let store = CallTestStore()
        let voice = CallTestVoice(availability: .unavailable)
        let model = PulseCallAppModel(store: store, voice: voice, serviceFactory: { _ in CallTestService() })
        // Unpaired Pulse does not record; pairing-only root still supplies the
        // text/paste flow. Exercise the reducer through the voice controller.
        XCTAssertEqual(model.rootDestination, .pairing)
        await voice.beginPushToTalk()
        XCTAssertEqual(model.voiceUnavailable, true)
        XCTAssertNotEqual(model.pttState, .listening)
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
        XCTAssertEqual(Array(voice.events.prefix(2)), ["stopNarration", "beginCapture"])

        voice.emitTranscript("sí", isFinal: true)
        await settle()
        XCTAssertEqual(service.confirmCalls, 1)
        XCTAssertNil(model.pendingReview)

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
        let model = PulseCallAppModel(store: store, voice: voice, serviceFactory: { _ in service })
        await model.refresh()
        model.present(review: try fixtureReview())

        model.beginPushToTalk()
        await settle()
        voice.emitInterruption()

        XCTAssertEqual(model.pttState, .interrupted)
        XCTAssertEqual(model.state, .review)
        XCTAssertNotNil(model.pendingReview)
        XCTAssertEqual(service.confirmCalls, 0)
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
        await wait(seconds: 0.02)
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

    private func pairedStore() throws -> CallTestStore {
        let store = CallTestStore()
        try store.saveDeviceRegistration(PulseDeviceRegistration(baseURL: URL(string: "https://moa.example")!, deviceID: "dev", credential: "dev.secret", expiresAt: .distantFuture))
        return store
    }

    private func fixtureReview(operationID: String = "AbCdEfGhIjKlMnOpQrStUvWx") throws -> PulsePendingReview {
        let review = try JSONDecoder.moaOps.decode(PulseOperationReview.self, from: Data(#"{"target":{"id":"s1","title":"Release","project":"/release"},"text":"continúa","action":"steer","risk":"changes","consequence":"delivery is not completion"}"#.utf8))
        return .init(operationID: operationID, kind: .directedInstruction, expiresAt: .distantFuture, review: review)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
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
    func loadAnthropicAPIKey() throws -> String? { key }
    func saveAnthropicAPIKey(_ key: String) throws { self.key = key }
    func clearAnthropicAPIKey() throws { key = nil }
}

@MainActor
private final class CallTestVoice: PulseVoiceControlling {
    var onTranscript: ((String, Bool) -> Void)?
    var onInterruption: (() -> Void)?
    var onAvailability: ((PulseVoiceAvailability) -> Void)?
    private let availability: PulseVoiceAvailability
    private(set) var events: [String] = []

    init(availability: PulseVoiceAvailability = .available) { self.availability = availability }
    func stopSpeakingForCapture() { events.append("stopNarration") }
    func beginPushToTalk() async { events.append("beginCapture"); onAvailability?(availability) }
    func endPushToTalk() {}
    func speak(_: String) {}
    func stopAll() {}
    func setMuted(_: Bool) {}
    func setForegroundActive(_: Bool) {}
    func emitTranscript(_ text: String, isFinal: Bool) { onTranscript?(text, isFinal) }
    func emitInterruption() { onInterruption?() }
}

private final class CallTestService: PulseCallService, @unchecked Sendable {
    var pulseResults: [Result<OpsPulse, PulseCallError>] = []
    var streamEvents: [PulseOpsStreamEvent] = []
    private(set) var confirmCalls = 0

    func loadPulse() async throws -> OpsPulse {
        guard !pulseResults.isEmpty else { throw PulseCallError.transport }
        return try pulseResults.removeFirst().get()
    }
    func loadSitrep() async throws -> OpsBriefing {
        try JSONDecoder.moaOps.decode(OpsBriefing.self, from: Data(#"{"sessions":null,"blockers":[],"spoken":"Panorama seguro."}"#.utf8))
    }
    func loadStatus(target _: String) async throws -> OpsStatusResult { throw PulseCallError.transport }
    func loadSafeConversationEvidence(sessionID _: String) async throws -> ConversationPage { throw PulseCallError.transport }
    func prepareOperation(_: PulseOperationPrepare) async throws -> PulseOperationResponse { throw PulseCallError.transport }
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
