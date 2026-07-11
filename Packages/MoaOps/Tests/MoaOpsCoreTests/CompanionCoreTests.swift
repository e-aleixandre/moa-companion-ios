import Foundation
import XCTest
@testable import MoaOpsCore

final class CompanionCoreTests: XCTestCase {
    func testConversationPageDecodesNewestFirstOwnerDisplayContract() throws {
        let page = try JSONDecoder.moaOps.decode(ConversationPage.self, from: Data("""
        {"session_id":"s1","title":"Entrega","branch":{"leaf_id":"leaf-a","source":"saved"},"order":"newest_first","messages":[{"id":"m2","role":"assistant","text":"Listo","truncated":true,"omitted":true,"omitted_blocks":2},{"id":"m1","role":"user","timestamp":"2026-07-11T18:00:00Z","text":"Hola"}],"next_cursor":"opaque-next","has_more":true}
        """.utf8))
        XCTAssertEqual(page.order, "newest_first")
        XCTAssertEqual(page.messages.map(\.id), ["m2", "m1"])
        XCTAssertEqual(page.messages[0].omittedBlocks, 2)
        XCTAssertTrue(page.messages[0].truncated)
    }

    func testBriefingDecodesProvenanceAndExactActionTarget() throws {
        let briefing = try JSONDecoder.moaOps.decode(ConversationBriefing.self, from: Data("""
        {"kind":"ops","generated_at":"2026-07-11T18:00:00Z","mode":"model","verified_ops":[{"source_id":"ops:s1:status","text":"Entrega is running","provenance":"verified_ops"}],"items":[{"text":"Moa sigue trabajando","source_ids":["conversation:s1:m2"],"provenance":"agent_reported","suggested_action":{"kind":"directed_instruction","target_id":"s1"}}]}
        """.utf8))
        XCTAssertEqual(briefing.verifiedOps[0].provenance, "verified_ops")
        XCTAssertEqual(briefing.items[0].suggestedAction?.targetID, "s1")
    }

    func testCompanionWebSocketDecodesOnlyExactSafeSchema() throws {
        let initial = try ConversationLiveEvent.decodeServerEvent(Data("""
        {"type":"init","init":{"session_id":"s1","title":"Entrega","branch":{"leaf_id":"leaf","source":"active"},"state":"running","tail_order":"oldest_first","tail":[{"id":"m1","role":"assistant","text":"cola"}],"older_cursor":"opaque","has_older":true,"last_seq":7,"display_max_bytes":1024}}
        """.utf8))
        let delta = try ConversationLiveEvent.decodeServerEvent(Data(#"{"type":"assistant_delta","delta":{"text":"res"}}"#.utf8))
        let final = try ConversationLiveEvent.decodeServerEvent(Data(#"{"type":"assistant_final","message":{"id":"m2","role":"assistant","text":"respuesta"}}"#.utf8))
        let state = try ConversationLiveEvent.decodeServerEvent(Data(#"{"type":"state","state":{"state":"idle"}}"#.utf8))

        XCTAssertEqual(initial, .initial(.init(sessionID: "s1", title: "Entrega", branch: .init(leafID: "leaf", source: "active"), state: "running", tail: [.init(id: "m1", role: "assistant", text: "cola")], olderCursor: "opaque", hasOlder: true)))
        XCTAssertEqual(delta, .assistantDelta(text: "res", truncated: false))
        XCTAssertEqual(final, .assistantFinal(.init(id: "m2", role: "assistant", text: "respuesta")))
        XCTAssertEqual(state, .state("idle"))
    }

    func testCompanionWebSocketRejectsRawDashboardFramesAndBadSafeFrames() {
        XCTAssertThrowsError(try ConversationLiveEvent.decodeServerEvent(Data(#"{"type":"text_delta","data":{"delta":"private"}}"#.utf8)))
        XCTAssertThrowsError(try ConversationLiveEvent.decodeServerEvent(Data(#"{"type":"assistant_final","message":{"id":"bad","role":"user","text":"no"}}"#.utf8)))
        XCTAssertThrowsError(try ConversationLiveEvent.decodeServerEvent(Data(#"{"type":"tool_end","data":{"result":"private"}}"#.utf8)))
    }

    func testConversationLiveReducerAppendsOnlyFinalAfterPreview() {
        var state = ConversationLiveState(messages: [.init(id: "old", role: "user", text: "Persistido")])
        state.apply(.assistantDelta(text: "Res", truncated: false))
        state.apply(.assistantDelta(text: "puesta", truncated: false))
        state.apply(.assistantFinal(.init(id: "final", role: "assistant", text: "Respuesta")))
        state.apply(.state("idle"))
        XCTAssertEqual(state.messages.map(\.id), ["old", "final"])
        XCTAssertEqual(state.state, "idle")
        XCTAssertEqual(state.partialText, "")
    }

    func testSendRequestContainsTextAndExplicitEmptyAttachments() throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder.moaOps.encode(ConversationSendRequest(text: "continúa"))) as? [String: Any]
        XCTAssertEqual(body?["text"] as? String, "continúa")
        XCTAssertEqual(body?["attachments"] as? [String], [])
    }
}
