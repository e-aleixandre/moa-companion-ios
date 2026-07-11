import Foundation
import XCTest
@testable import MoaOpsPresentation
@testable import MoaOpsCore

final class MoaOpsPresentationTests: XCTestCase {
    func testServerConfigurationAcceptsHTTPAndHTTPSHostsOnly() throws {
        XCTAssertEqual(try ServerConfiguration(urlText: " https://ops.example:8443 ").baseURL.host, "ops.example")
        XCTAssertThrowsError(try ServerConfiguration(urlText: "ops.example"))
        XCTAssertThrowsError(try ServerConfiguration(urlText: "https://user:pass@ops.example"))
        XCTAssertThrowsError(try ServerConfiguration(urlText: "https://ops.example/?token=secret"))
    }

    func testTargetsAndDetailOnlyComeFromLoadedSnapshot() {
        let snapshot = snapshot()

        XCTAssertEqual(PresentationMapper.sessionTargets(in: nil), [])
        XCTAssertEqual(PresentationMapper.sessionTargets(in: snapshot), [
            OpsSessionTarget(id: "known-session", title: "Known", projectName: "/work/moa")
        ])
        XCTAssertNil(PresentationMapper.detail(sessionID: "not-loaded", in: snapshot))
        XCTAssertEqual(PresentationMapper.detail(sessionID: "known-session", in: snapshot)?.verification, "Passed")
    }

    func testStalenessRequiresLiveAndRecentSnapshot() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(PresentationMapper.isStale(lastSnapshotAt: now, connection: .reconnecting(attempt: 1), now: now))
        XCTAssertFalse(PresentationMapper.isStale(lastSnapshotAt: now.addingTimeInterval(-44), connection: .connected, now: now))
        XCTAssertTrue(PresentationMapper.isStale(lastSnapshotAt: now.addingTimeInterval(-46), connection: .connected, now: now))
    }

    func testErrorMappingDoesNotExposeServerDetails() {
        XCTAssertEqual(PresentationMapper.userMessage(for: MoaOpsClientError.httpStatus(code: 401, retryAfter: nil)), "The server requires authentication. Check your access and try again.")
        XCTAssertEqual(PresentationMapper.userMessage(for: MoaOpsClientError.httpStatus(code: 403, retryAfter: nil)), "The server did not authorize this request. Check authentication and request authorization.")
        XCTAssertEqual(PresentationMapper.userMessage(for: MoaOpsClientError.httpStatus(code: 404, retryAfter: nil)), "This server does not support the requested Ops API.")
        XCTAssertEqual(PresentationMapper.userMessage(for: MoaOpsClientError.httpStatus(code: 429, retryAfter: nil)), "The server is rate limiting requests. Try again shortly.")
        XCTAssertEqual(PresentationMapper.userMessage(for: MoaOpsClientError.httpStatus(code: 500, retryAfter: nil)), "The server refused the request. Try again later.")
        XCTAssertEqual(PresentationMapper.userMessage(for: NSError(domain: "private-server-detail", code: 1)), "Could not reach the server. Check the address and try again.")
    }

    func testAskMappingKeepsOnlyRecognizedVerifiedAnswers() throws {
        let response = try askResponse(kind: "status", includesBriefing: true)

        let entry = try XCTUnwrap(PresentationMapper.askHistoryEntry(question: "What is Known doing?", response: response))

        XCTAssertEqual(entry.question, "What is Known doing?")
        XCTAssertEqual(entry.statusLabel, "Verified status")
        XCTAssertEqual(entry.briefing.sessions?.map(\.title), ["Known"])
        XCTAssertNil(PresentationMapper.askHistoryEntry(question: "Anything?", response: try askResponse(kind: "future", includesBriefing: true)))
        XCTAssertNil(PresentationMapper.askHistoryEntry(question: "Anything?", response: try askResponse(kind: "unsupported", includesBriefing: false)))
    }

    func testAskHistoryIsBoundedAndKeepsMostRecentEntries() throws {
        let response = try askResponse(kind: "sitrep", includesBriefing: true)
        let entries = (1...3).compactMap { index in
            PresentationMapper.askHistoryEntry(question: "Question \(index)", response: response)
        }

        let history = entries.reduce([]) { partial, entry in
            PresentationMapper.appendingAskHistory(entry, to: partial, maximumCount: 2)
        }

        XCTAssertEqual(history.map(\.question), ["Question 2", "Question 3"])
    }

    func testInstructionReceiptUsesLocalTargetAndDoesNotClaimCompletion() {
        let sent = OpsInstructionReceipt(title: "Known", action: .send)
        let steered = OpsInstructionReceipt(title: "Known", action: .steer)

        XCTAssertEqual(sent.message, "Entregada a Known — enviada")
        XCTAssertEqual(steered.message, "Entregada a Known — dirigida")
        XCTAssertEqual(sent.completionNotice, "La entrega no demuestra que el trabajo haya terminado. Revisa Pulse para ver el progreso.")
    }

    func testPulseSectionsKeepInboxPriorityAndKnownVerificationOnly() throws {
        let pulse = try pulse(generatedAt: Date())

        let sections = PresentationMapper.pulseSections(for: pulse)
        let attention = try XCTUnwrap(sections.first)
        let attentionCard = try XCTUnwrap(attention.cards.first)

        XCTAssertEqual(sections.map(\.kind), [.needsAttention, .changes, .inProgress, .onTrack])
        XCTAssertEqual(attentionCard.category, "Permiso necesario")
        XCTAssertNil(attentionCard.verification, "Unknown must never become a displayed status")
        XCTAssertEqual(attentionCard.facts.map(\.provenance), ["Derivado", "Observado"])
        XCTAssertEqual(attentionCard.instructionTarget, PulseInstructionTarget(id: "directed-s1", title: "Release", project: "/work/release"))
    }

    @MainActor
    func testPulseRetentionGapRetriesOnceWithoutCursorAndThenPersistsRenderedCursor() async throws {
        let cursor = "expired-cursor"
        let generatedAt = Date()
        let store = CursorStore(cursor: cursor)
        let service = PulseServiceStub(pulseResults: [.failure(.pulseResetRequired), .success(try pulse(generatedAt: generatedAt, nextCursor: "fresh-cursor"))])
        let model = MoaOpsAppModel(
            serverURLText: "https://ops.example",
            cursorStore: store,
            serviceFactory: { _, _ in service }
        )

        await model.testConnection()

        XCTAssertEqual(service.requestedCursors, [cursor, nil])
        XCTAssertEqual(store.cursor(), "fresh-cursor")
        XCTAssertTrue(model.historyUnavailable)
        XCTAssertNotNil(model.pulse)
    }

    @MainActor
    func testInstructionUsesOnlyPulseSuppliedTargetBinding() async throws {
        let service = PulseServiceStub(pulseResults: [.success(try pulse(generatedAt: Date()))])
        let model = MoaOpsAppModel(
            serverURLText: "https://ops.example",
            cursorStore: CursorStore(cursor: nil),
            serviceFactory: { _, _ in service }
        )
        await model.testConnection()
        let card = try XCTUnwrap(model.pulseSections.first?.cards.first)

        model.beginInstruction(for: card)
        await model.submitInstruction(text: "Continúa con la entrega")

        XCTAssertEqual(service.submittedInstructions.map(\.target), ["directed-s1"])
        XCTAssertEqual(model.instructionReceipt?.message, "Entregada a Release — dirigida")
    }

    @MainActor
    func testPulseConsumesOneOpaquePageAtATimeWithoutSkippingOrDuplicating() async throws {
        let service = PulseServiceStub(pulseResults: [
            .success(try pulse(generatedAt: Date(), nextCursor: "cursor-1", hasMore: true, changeID: "change-1")),
            .success(try pulse(generatedAt: Date(), nextCursor: "cursor-2", hasMore: true, changeID: "change-2")),
            .success(try pulse(generatedAt: Date(), nextCursor: "poll-cursor", changeID: "change-3")),
        ])
        let store = CursorStore(cursor: nil)
        let model = MoaOpsAppModel(serverURLText: "https://ops.example", cursorStore: store, serviceFactory: { _, _ in service })

        await model.testConnection()
        await model.refresh()
        await model.refresh()

        XCTAssertEqual(service.requestedCursors, [nil, "cursor-1", "cursor-2"])
        XCTAssertEqual(store.cursor(), "poll-cursor")
        XCTAssertEqual(model.pulse?.changes.items.map(\.id), ["change-3"])
    }

    @MainActor
    func testFailedPulsePageRetainsOpaqueCursorForSafeRetryAndForegroundRefreshUsesIt() async throws {
        let service = PulseServiceStub(pulseResults: [
            .success(try pulse(generatedAt: Date(), nextCursor: "retry-cursor")),
            .failure(.transport),
            .success(try pulse(generatedAt: Date(), nextCursor: "after-foreground")),
        ])
        let store = CursorStore(cursor: nil)
        let model = MoaOpsAppModel(serverURLText: "https://ops.example", cursorStore: store, serviceFactory: { _, _ in service })

        await model.testConnection()
        await model.refresh()
        XCTAssertEqual(store.cursor(), "retry-cursor")
        await model.refreshOnForeground()

        XCTAssertEqual(service.requestedCursors, [nil, "retry-cursor", "retry-cursor"])
        XCTAssertEqual(store.cursor(), "after-foreground")
    }

    @MainActor
    func testAccessTokenIsPassedOnlyToServiceFactory() async throws {
        let service = PulseServiceStub(pulseResults: [.success(try pulse(generatedAt: Date()))])
        let tokenRecorder = TokenRecorder()
        let model = MoaOpsAppModel(
            serverURLText: "https://ops.example",
            cursorStore: CursorStore(cursor: nil),
            serviceFactory: { _, token in
                tokenRecorder.value = token
                return service
            }
        )
        model.accessToken = " token-en-memoria "

        await model.testConnection()

        XCTAssertEqual(tokenRecorder.value, "token-en-memoria")
        model.disconnect()
        XCTAssertEqual(model.accessToken, "")
    }

    @MainActor
    func testInstructionRetryKeepsRequestIDTextAndBoundTargetAfterTransportFailure() async throws {
        let success = try JSONDecoder.moaOps.decode(OpsInstructionResponse.self, from: Data("""
        {"action":"send","target":{"id":"directed-s1","title":"Release","project":"/work/release"}}
        """.utf8))
        let service = PulseServiceStub(pulseResults: [.success(try pulse(generatedAt: Date()))])
        service.instructionResults = [.failure(.transport), .success(success)]
        let model = MoaOpsAppModel(serverURLText: "https://ops.example", cursorStore: CursorStore(cursor: nil), serviceFactory: { _, _ in service })
        await model.testConnection()
        model.beginInstruction(for: try XCTUnwrap(model.pulseSections.first?.cards.first))
        model.instructionText = "Continúa con la entrega"

        await model.submitInstruction()
        await model.submitInstruction()

        XCTAssertEqual(service.submittedInstructions.count, 2)
        XCTAssertEqual(service.submittedInstructions[0], service.submittedInstructions[1])
        XCTAssertEqual(service.submittedInstructions[0].target, "directed-s1")
        XCTAssertEqual(service.submittedInstructions[0].text, "Continúa con la entrega")
        XCTAssertEqual(model.instructionReceipt?.message, "Entregada a Release — enviada")
    }

    func testPulseFreshnessUsesLastSuccessfulRefreshNotServerGenerationTime() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(PresentationMapper.isPulseStale(lastSuccessfulRefreshAt: now.addingTimeInterval(-299), now: now))
        XCTAssertTrue(PresentationMapper.isPulseStale(lastSuccessfulRefreshAt: now.addingTimeInterval(-301), now: now))
        XCTAssertTrue(PresentationMapper.isPulseStale(lastSuccessfulRefreshAt: nil, now: now))
    }

    private func askResponse(kind: String, includesBriefing: Bool) throws -> OpsAskResponse {
        let briefing = includesBriefing ? ",\"briefing\":{\"sessions\":[{\"id\":\"known-session\",\"title\":\"Known\",\"presence\":\"active\",\"lifecycle\":\"running\",\"activity\":\"running\",\"jobs\":{\"subagents\":0,\"bash\":0},\"verification\":\"passed\"}],\"blockers\":[],\"spoken\":\"Known is running.\"}" : ""
        return try JSONDecoder.moaOps.decode(OpsAskResponse.self, from: Data("{\"kind\":\"\(kind)\"\(briefing)}".utf8))
    }

    private func snapshot() -> OpsSnapshot {
        OpsSnapshot(projects: [
            OpsProject(canonicalCWD: "/work/moa", sessions: [
                OpsSession(
                    id: "known-session",
                    title: "Known",
                    presence: .active,
                    lifecycle: .running,
                    activity: .running,
                    jobs: .init(subagents: 1, bash: 2),
                    verification: .init(state: .passed),
                    milestones: []
                )
            ])
        ])
    }

    private func pulse(generatedAt: Date, nextCursor: String = "cursor-next", hasMore: Bool = false, changeID: String = "change") throws -> OpsPulse {
        let timestamp = ISO8601DateFormatter.moaOpsFractional.string(from: generatedAt)
        return try JSONDecoder.moaOps.decode(OpsPulse.self, from: Data("""
        {"generated_at":"\(timestamp)","summary":{"needs_attention":1,"in_progress":1,"on_track":1,"changes":1},"needs_attention":[{"id":"attention","session":{"id":"s1","title":"Release","project":"/work/release"},"category":"permission_needed","priority":2,"lifecycle":"running","activity":"permission","verification":"unknown","observed_at":"\(timestamp)","freshness":"fresh","facts":[{"kind":"attention_reason","value":"permission_needed","provenance":"derived"},{"kind":"activity","value":"permission","provenance":"observed"}],"directed_instruction":{"target_id":"directed-s1"}}],"in_progress":[{"id":"progress","session":{"id":"s2","title":"Build","project":"/work/build"},"category":"in_progress","lifecycle":"running","activity":"running","freshness":"fresh","facts":[]}],"on_track":[{"id":"track","session":{"id":"s3","title":"Tests","project":"/work/tests"},"category":"on_track","lifecycle":"running","activity":"running","verification":"passed","freshness":"fresh","facts":[]}],"changes":{"requested":true,"until":"\(timestamp)","items":[{"id":"\(changeID)","session":{"id":"s1","title":"Release","project":"/work/release"},"category":"run_started","lifecycle":"running","activity":"running","freshness":"fresh","facts":[{"kind":"milestone","value":"run_started","provenance":"observed"}]}],"next_cursor":"\(nextCursor)","has_more":\(hasMore)}}
        """.utf8))
    }
}

private final class CursorStore: PulseCursorStore {
    private var value: String?

    init(cursor: String?) { value = cursor }
    func cursor() -> String? { value }
    func save(cursor: String) { value = cursor }
    func clear() { value = nil }
}

private final class TokenRecorder: @unchecked Sendable {
    var value: String?
}

private final class PulseServiceStub: MoaOpsPresentationService, @unchecked Sendable {
    var pulseResults: [Result<OpsPulse, MoaOpsClientError>]
    private(set) var requestedCursors: [String?] = []
    private(set) var submittedInstructions: [OpsInstructionRequest] = []
    var instructionResults: [Result<OpsInstructionResponse, MoaOpsClientError>] = []

    init(pulseResults: [Result<OpsPulse, MoaOpsClientError>]) {
        self.pulseResults = pulseResults
    }

    func loadPulse(cursor: String?) async throws -> OpsPulse {
        requestedCursors.append(cursor)
        guard !pulseResults.isEmpty else { throw MoaOpsClientError.transport }
        return try pulseResults.removeFirst().get()
    }

    func loadOverview() async throws -> OpsSnapshot { throw MoaOpsClientError.transport }
    func loadSitrep() async throws -> OpsBriefing { throw MoaOpsClientError.transport }
    func loadBlockers() async throws -> OpsBriefing { throw MoaOpsClientError.transport }
    func ask(_ question: OpsAskRequest) async throws -> OpsAskResponse { throw MoaOpsClientError.transport }
    func submitInstruction(_ instruction: OpsInstructionRequest) async throws -> OpsInstructionResponse {
        submittedInstructions.append(instruction)
        if !instructionResults.isEmpty {
            return try instructionResults.removeFirst().get()
        }
        return try JSONDecoder.moaOps.decode(OpsInstructionResponse.self, from: Data("""
        {"action":"steer","target":{"id":"directed-s1","title":"Release","project":"/work/release"}}
        """.utf8))
    }
    func startUpdates() async {}
    func stopUpdates() async {}
    func snapshotUpdates() async -> AsyncStream<OpsSnapshotUpdate> { AsyncStream { $0.finish() } }
    func webSocketState() async -> OpsWebSocketState { .stopped }
}
