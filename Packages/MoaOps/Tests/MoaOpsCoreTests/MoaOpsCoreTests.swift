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
