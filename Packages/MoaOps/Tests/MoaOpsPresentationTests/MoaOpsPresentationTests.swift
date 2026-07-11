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
        let sent = OpsInstructionReceipt(title: "Known", action: "sent")
        let steered = OpsInstructionReceipt(title: "Known", action: "steered")

        XCTAssertEqual(sent.message, "Delivered to Known — sent")
        XCTAssertEqual(steered.message, "Delivered to Known — steered")
        XCTAssertEqual(sent.completionNotice, "Delivery is not proof of completion. Check verified status for progress.")
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
        let cursor = Date().addingTimeInterval(-60)
        let generatedAt = Date()
        let store = CursorStore(cursor: cursor)
        let service = PulseServiceStub(pulseResults: [.failure(.httpStatus(code: 410, retryAfter: nil)), .success(try pulse(generatedAt: generatedAt))])
        let model = MoaOpsAppModel(
            serverURLText: "https://ops.example",
            cursorStore: store,
            serviceFactory: { _ in service }
        )

        await model.testConnection()

        XCTAssertEqual(service.requestedCursors, [cursor, nil])
        XCTAssertEqual(store.lastSeen(), model.pulse?.generatedAt)
        XCTAssertTrue(model.historyUnavailable)
        XCTAssertNotNil(model.pulse)
    }

    @MainActor
    func testInstructionUsesOnlyPulseSuppliedTargetBinding() async throws {
        let service = PulseServiceStub(pulseResults: [.success(try pulse(generatedAt: Date()))])
        let model = MoaOpsAppModel(
            serverURLText: "https://ops.example",
            cursorStore: CursorStore(cursor: nil),
            serviceFactory: { _ in service }
        )
        await model.testConnection()
        let card = try XCTUnwrap(model.pulseSections.first?.cards.first)

        model.beginInstruction(for: card)
        await model.submitInstruction(text: "Continúa con la entrega")

        XCTAssertEqual(service.submittedInstructions.map(\.target), ["directed-s1"])
        XCTAssertEqual(model.instructionReceipt?.message, "Delivered to Release — steered")
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

    private func pulse(generatedAt: Date) throws -> OpsPulse {
        let timestamp = ISO8601DateFormatter.moaOpsFractional.string(from: generatedAt)
        return try JSONDecoder.moaOps.decode(OpsPulse.self, from: Data("""
        {"generated_at":"\(timestamp)","summary":{"needs_attention":1,"in_progress":1,"on_track":1,"changes":1},"needs_attention":[{"id":"attention","session":{"id":"s1","title":"Release","project":"/work/release"},"category":"permission_needed","priority":2,"lifecycle":"running","activity":"permission","verification":"unknown","observed_at":"\(timestamp)","freshness":"fresh","facts":[{"kind":"attention_reason","value":"permission_needed","provenance":"derived"},{"kind":"activity","value":"permission","provenance":"observed"}],"directed_instruction":{"target_id":"directed-s1"}}],"in_progress":[{"id":"progress","session":{"id":"s2","title":"Build","project":"/work/build"},"category":"in_progress","lifecycle":"running","activity":"running","freshness":"fresh","facts":[]}],"on_track":[{"id":"track","session":{"id":"s3","title":"Tests","project":"/work/tests"},"category":"on_track","lifecycle":"running","activity":"running","verification":"passed","freshness":"fresh","facts":[]}],"changes":{"requested":true,"since":"\(timestamp)","until":"\(timestamp)","items":[{"id":"change","session":{"id":"s1","title":"Release","project":"/work/release"},"category":"run_started","lifecycle":"running","activity":"running","freshness":"fresh","facts":[{"kind":"milestone","value":"run_started","provenance":"observed"}]}],"truncated":false}}
        """.utf8))
    }
}

private final class CursorStore: PulseCursorStore {
    private var value: Date?

    init(cursor: Date?) { value = cursor }
    func lastSeen() -> Date? { value }
    func save(lastSeen: Date) { value = lastSeen }
    func clear() { value = nil }
}

private final class PulseServiceStub: MoaOpsPresentationService, @unchecked Sendable {
    var pulseResults: [Result<OpsPulse, MoaOpsClientError>]
    private(set) var requestedCursors: [Date?] = []
    private(set) var submittedInstructions: [OpsInstructionRequest] = []

    init(pulseResults: [Result<OpsPulse, MoaOpsClientError>]) {
        self.pulseResults = pulseResults
    }

    func loadPulse(since: Date?) async throws -> OpsPulse {
        requestedCursors.append(since)
        guard !pulseResults.isEmpty else { throw MoaOpsClientError.transport }
        return try pulseResults.removeFirst().get()
    }

    func loadOverview() async throws -> OpsSnapshot { throw MoaOpsClientError.transport }
    func loadSitrep() async throws -> OpsBriefing { throw MoaOpsClientError.transport }
    func loadBlockers() async throws -> OpsBriefing { throw MoaOpsClientError.transport }
    func ask(_ question: OpsAskRequest) async throws -> OpsAskResponse { throw MoaOpsClientError.transport }
    func submitInstruction(_ instruction: OpsInstructionRequest) async throws -> OpsInstructionResponse {
        submittedInstructions.append(instruction)
        return try JSONDecoder.moaOps.decode(OpsInstructionResponse.self, from: Data("""
        {"action":"steered","target":{"id":"directed-s1","title":"Release","project":"/work/release"}}
        """.utf8))
    }
    func startUpdates() async {}
    func stopUpdates() async {}
    func snapshotUpdates() async -> AsyncStream<OpsSnapshotUpdate> { AsyncStream { $0.finish() } }
    func webSocketState() async -> OpsWebSocketState { .stopped }
}
