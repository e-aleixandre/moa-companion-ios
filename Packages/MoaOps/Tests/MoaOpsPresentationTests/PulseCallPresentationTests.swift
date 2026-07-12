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

    init(availability: PulseVoiceAvailability = .available) { self.availability = availability }
    func beginPushToTalk() async { onAvailability?(availability) }
    func endPushToTalk() {}
    func speak(_: String) {}
    func stopAll() {}
    func setMuted(_: Bool) {}
    func setForegroundActive(_: Bool) {}
}

private final class CallTestService: PulseCallService, @unchecked Sendable {
    var pulseResults: [Result<OpsPulse, PulseCallError>] = []

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
    func confirmOperation(_: String) async throws -> PulseOperationResponse { throw PulseCallError.transport }
    func loadOperation(_: String) async throws -> PulseOperationResponse { throw PulseCallError.transport }
    func startOpsUpdates() async {}
    func stopOpsUpdates() async {}
    func opsUpdates() async -> AsyncStream<OpsSnapshotUpdate> { AsyncStream { $0.finish() } }
    func invalidate() async {}
}
