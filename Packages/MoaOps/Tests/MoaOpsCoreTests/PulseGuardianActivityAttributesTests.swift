import Foundation
import XCTest
@testable import MoaOpsCore

final class PulseGuardianActivityAttributesTests: XCTestCase {
    func testMapperReportsAnEmptyGuardian() {
        let content = PulseGuardianActivityAttributes.contentState(state: .idle, snapshot: .init())

        XCTAssertEqual(content.stateLabel, "Guardia detenida")
        XCTAssertEqual(content.sessionCount, 0)
        XCTAssertEqual(content.pendingCount, 0)
        XCTAssertNil(content.lastEventLine)
    }

    func testMapperSumsPendingAsksAndPermissions() throws {
        var snapshot = PulseGuardianSnapshot()
        snapshot.sessions = [
            try decodeSession(#"{"session_id":"s1","alias":"token","title":"Token","state":"waiting","pending_asks":1,"pending_perms":2}"#),
            try decodeSession(#"{"session_id":"s2","alias":"tests","title":"Tests","state":"running","pending_asks":3,"pending_perms":0}"#),
        ]

        let content = PulseGuardianActivityAttributes.contentState(state: .guardianStandby, snapshot: snapshot)

        XCTAssertEqual(content.stateLabel, "Guardián en espera")
        XCTAssertEqual(content.sessionCount, 2)
        XCTAssertEqual(content.pendingCount, 6)
    }

    func testMapperUsesMostRecentTerminationAsLastEvent() throws {
        var snapshot = PulseGuardianSnapshot()
        snapshot.terminations = [
            try decodeTermination(#"{"id":"older","session_id":"s1","alias":"build","spoken":"Terminó antes","summary":"ok","created_at":"2026-07-16T10:00:00Z","ref":{"session_id":"s1","run_gen":1,"messages_url":"/api/sessions/s1/messages"}}"#),
            try decodeTermination(#"{"id":"newer","session_id":"s2","alias":"tests","spoken":"Los tests están en verde","summary":"ok","created_at":"2026-07-16T10:01:00Z","ref":{"session_id":"s2","run_gen":2,"messages_url":"/api/sessions/s2/messages"}}"#),
        ]

        let content = PulseGuardianActivityAttributes.contentState(state: .speaking, snapshot: snapshot)

        XCTAssertEqual(content.lastEventLine, "tests: Los tests están en verde")
    }

    func testMapperTruncatesLastEventToEightyCharacters() throws {
        let text = String(repeating: "x", count: 100)
        var snapshot = PulseGuardianSnapshot()
        snapshot.terminations = [
            try decodeTermination("""
            {"id":"run","session_id":"s1","alias":"build","spoken":"\(text)","summary":"ok","created_at":"2026-07-16T10:01:00Z","ref":{"session_id":"s1","run_gen":1,"messages_url":"/api/sessions/s1/messages"}}
            """)
        ]

        let content = PulseGuardianActivityAttributes.contentState(state: .speaking, snapshot: snapshot)

        XCTAssertEqual(content.lastEventLine?.count, 80)
        XCTAssertEqual(content.lastEventLine, "build: " + String(repeating: "x", count: 73))
    }

    private func decodeSession(_ json: String) throws -> PulseSessionBrief {
        try JSONDecoder.moaOps.decode(PulseSessionBrief.self, from: Data(json.utf8))
    }

    private func decodeTermination(_ json: String) throws -> PulseRunTermination {
        try JSONDecoder.moaOps.decode(PulseRunTermination.self, from: Data(json.utf8))
    }
}
