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
}
