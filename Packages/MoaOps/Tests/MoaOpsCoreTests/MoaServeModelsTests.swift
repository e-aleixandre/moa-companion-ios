import Foundation
import XCTest
@testable import MoaOpsCore

final class MoaServeModelsTests: XCTestCase {
    func testSessionListFixtureDecodesTheServeContract() throws {
        let fixture = #"""
        [{"id":"session-1","title":"Fix tests","state":"running","model":"gpt-5","provider":"openai","thinking":"high","cwd":"/workspace","created":"2026-07-15T18:00:00Z","updated":"2026-07-15T18:02:00Z","context_percent":42,"permission_mode":"ask","cost_usd":0.125,"run_started_at":"2026-07-15T18:01:00Z"}]
        """#

        let sessions = try JSONDecoder.moaOps.decode([MoaServeSessionInfo].self, from: Data(fixture.utf8))

        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.id, "session-1")
        XCTAssertEqual(session.state, "running")
        XCTAssertEqual(session.contextPercent, 42)
        XCTAssertEqual(session.costUSD, 0.125)
        XCTAssertNotNil(session.runStartedAt)
        XCTAssertFalse(session.archived)
        XCTAssertFalse(session.untrustedMCP)
        XCTAssertNil(session.error)
    }

    func testAttentionFixtureDecodesItems() throws {
        let fixture = #"""
        {"items":[{"id":"att_1","priority":0,"kind":"permission","session_id":"session-1","alias":"Fix tests","spoken":"Moa necesita permiso.","state":"pending","created_at":"2026-07-15T18:02:00Z","ref_id":"perm_1","risk_level":"medium","risk_flags":["shell"],"requires_verbatim_confirm":true}]}
        """#

        let response = try JSONDecoder.moaOps.decode(MoaServeAttentionResponse.self, from: Data(fixture.utf8))

        let item = try XCTUnwrap(response.items.first)
        XCTAssertEqual(item.sessionID, "session-1")
        XCTAssertEqual(item.riskFlags, ["shell"])
        XCTAssertEqual(item.requiresVerbatimConfirm, true)
        XCTAssertNil(item.verbatim)
    }

    func testConversationAndToolDetailFixturesKeepTextAndToolMetadataSeparate() throws {
        let pageFixture = #"""
        {"session_id":"session-1","title":"Fix tests","branch":{"leaf_id":"leaf-1","source":"active"},"order":"newest_first","messages":[{"id":"tool:assistant-1:0","role":"tool","timestamp":"2026-07-15T18:02:00Z","tool":"bash","summary":"ejecutó `go test ./...`","status":"ok"},{"id":"assistant-1","role":"assistant","timestamp":"2026-07-15T18:01:00Z","text":"Los tests terminaron.","truncated":false},{"id":"user-1","role":"user","text":"Prueba los tests."}],"next_cursor":"opaque-cursor","has_more":true}
        """#
        let detailFixture = #"""
        {"output":"[non-sensitive fixture marker]","truncated":true}
        """#

        let page = try JSONDecoder.moaOps.decode(MoaServeConversationPage.self, from: Data(pageFixture.utf8))
        let detail = try JSONDecoder.moaOps.decode(MoaServeToolDetail.self, from: Data(detailFixture.utf8))

        XCTAssertEqual(page.messages[0].role, .tool)
        XCTAssertEqual(page.messages[0].tool, "bash")
        XCTAssertEqual(page.messages[0].summary, "ejecutó `go test ./...`")
        XCTAssertEqual(page.messages[0].status, "ok")
        XCTAssertNil(page.messages[0].text)
        XCTAssertEqual(page.messages[1].text, "Los tests terminaron.")
        XCTAssertEqual(page.messages[2].text, "Prueba los tests.")
        XCTAssertEqual(page.nextCursor, "opaque-cursor")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(detail.output, "[non-sensitive fixture marker]")
        XCTAssertTrue(detail.truncated)
    }
}
