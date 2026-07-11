import Foundation
import XCTest
@testable import MoaOpsCore

final class MoaOpsCoreTests: XCTestCase {
    func testSnapshotDecodesSafeWireShape() throws {
        let data = Data("""
        {"projects":[{"canonical_cwd":"/work/moa","sessions":[{"id":"s1","title":"Ops","presence":"active","lifecycle":"running","activity":"running","last_transition_at":"2026-07-11T06:00:00.123Z","jobs":{"subagents":1,"bash":2},"verification":{"state":"pending"},"milestones":[{"type":"run_started","at":"2026-07-11T06:00:00Z","ref_id":"run_1_started"}]}]}]}
        """.utf8)
        let snapshot = try JSONDecoder.moaOps.decode(OpsSnapshot.self, from: data)
        XCTAssertEqual(snapshot.projects[0].canonicalCWD, "/work/moa")
        XCTAssertEqual(snapshot.projects[0].sessions[0].jobs, OpsJobCounts(subagents: 1, bash: 2))
        XCTAssertEqual(snapshot.projects[0].sessions[0].milestones[0].refID, "run_1_started")
        XCTAssertNotNil(snapshot.projects[0].sessions[0].lastTransitionAt)
    }

    func testOverviewDecodesEmptyVerificationStateAsUnknown() throws {
        let data = Data("""
        {"projects":[{"canonical_cwd":"/work/moa","sessions":[{"id":"s1","title":"Ops","presence":"active","lifecycle":"running","activity":"running","jobs":{"subagents":0,"bash":0},"verification":{"state":""},"milestones":[]}]}]}
        """.utf8)

        let overview = try JSONDecoder.moaOps.decode(OpsSnapshot.self, from: data)

        XCTAssertEqual(overview.projects[0].sessions[0].verification.state, .unknown)
    }

    func testOverviewDecodesUnknownFutureVerificationStateAsUnknown() throws {
        let data = Data("""
        {"projects":[{"canonical_cwd":"/work/moa","sessions":[{"id":"s1","title":"Ops","presence":"active","lifecycle":"running","activity":"running","jobs":{"subagents":0,"bash":0},"verification":{"state":"in_progress"},"milestones":[]}]}]}
        """.utf8)

        let overview = try JSONDecoder.moaOps.decode(OpsSnapshot.self, from: data)

        XCTAssertEqual(overview.projects[0].sessions[0].verification.state, .unknown)
    }

    func testOverviewRejectsUnknownLifecycleAndActivityStates() throws {
        let invalidLifecycle = Data("""
        {"projects":[{"canonical_cwd":"/work/moa","sessions":[{"id":"s1","title":"Ops","presence":"active","lifecycle":"future","activity":"running","jobs":{"subagents":0,"bash":0},"verification":{"state":"unknown"},"milestones":[]}]}]}
        """.utf8)
        let invalidActivity = Data("""
        {"projects":[{"canonical_cwd":"/work/moa","sessions":[{"id":"s1","title":"Ops","presence":"active","lifecycle":"running","activity":"future","jobs":{"subagents":0,"bash":0},"verification":{"state":"unknown"},"milestones":[]}]}]}
        """.utf8)

        XCTAssertThrowsError(try JSONDecoder.moaOps.decode(OpsSnapshot.self, from: invalidLifecycle))
        XCTAssertThrowsError(try JSONDecoder.moaOps.decode(OpsSnapshot.self, from: invalidActivity))
    }

    func testInstructionEncodingUsesServerKeysAndCallerRequestID() throws {
        let request = OpsInstructionRequest(target: "s1", text: "continue", requestID: "retry-id")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder.moaOps.encode(request)) as? [String: String]
        XCTAssertEqual(object?["target"], "s1")
        XCTAssertEqual(object?["text"], "continue")
        XCTAssertEqual(object?["request_id"], "retry-id")
    }

    func testReconnectPolicyIsBounded() {
        let policy = OpsReconnectPolicy(initialDelay: 1, maximumDelay: 5)
        XCTAssertEqual(policy.delay(forAttempt: 1), 1)
        XCTAssertEqual(policy.delay(forAttempt: 3), 4)
        XCTAssertEqual(policy.delay(forAttempt: 4), 5)
    }

    func testInvalidBaseURLIsRejected() {
        XCTAssertThrowsError(try MoaOpsClient(baseURL: URL(string: "file:///tmp")!))
        XCTAssertThrowsError(try MoaOpsWebSocketClient(baseURL: URL(string: "https:///missing-host")!))
    }
}
