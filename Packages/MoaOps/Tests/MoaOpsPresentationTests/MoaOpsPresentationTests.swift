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
