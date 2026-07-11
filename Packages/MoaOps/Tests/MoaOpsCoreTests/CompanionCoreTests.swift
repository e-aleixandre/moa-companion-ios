import Foundation
import XCTest
@testable import MoaOpsCore

final class CompanionCoreTests: XCTestCase {
    func testConversationPageDecodesOwnerDisplayOnlyContract() throws {
        let page = try JSONDecoder.moaOps.decode(ConversationPage.self, from: Data("""
        {"session_id":"s1","title":"Entrega","branch":{"leaf_id":"leaf-a","source":"saved"},"messages":[{"id":"m1","role":"user","timestamp":"2026-07-11T18:00:00Z","text":"Hola"},{"id":"m2","role":"assistant","text":"Listo","truncated":true,"omitted":true,"omitted_blocks":2}],"next_cursor":"opaque-next","has_more":true}
        """.utf8))
        XCTAssertEqual(page.sessionID, "s1")
        XCTAssertEqual(page.branch, .init(leafID: "leaf-a", source: "saved"))
        XCTAssertEqual(page.messages[1].omittedBlocks, 2)
        XCTAssertTrue(page.messages[1].truncated)
        XCTAssertEqual(page.nextCursor, "opaque-next")
    }

    func testBriefingDecodesProvenanceAndExactActionTarget() throws {
        let briefing = try JSONDecoder.moaOps.decode(ConversationBriefing.self, from: Data("""
        {"kind":"ops","generated_at":"2026-07-11T18:00:00Z","mode":"model","verified_ops":[{"source_id":"ops:s1:status","text":"Entrega is running","provenance":"verified_ops"}],"items":[{"text":"Moa sigue trabajando","source_ids":["conversation:s1:m2"],"provenance":"agent_reported","suggested_action":{"kind":"directed_instruction","target_id":"s1"}}]}
        """.utf8))
        XCTAssertEqual(briefing.verifiedOps[0].provenance, "verified_ops")
        XCTAssertEqual(briefing.items[0].suggestedAction?.targetID, "s1")
        XCTAssertEqual(briefing.items[0].sourceIDs, ["conversation:s1:m2"])
    }

    func testConversationLiveReducerKeepsRESTHistoryAndOnlyAppliesSafeEvents() {
        var state = ConversationLiveState(messages: [.init(id: "old", role: "user", text: "Persistido")])
        state.apply(.initial(messages: [.init(id: "tail", role: "assistant", text: "Cola")], state: "running", historyTruncated: true))
        state.apply(.textDelta("Res"))
        state.apply(.textDelta("puesta"))
        state.apply(.messageEnded(.init(id: "final", role: "assistant", text: "Respuesta")))
        state.apply(.stateChanged("idle"))

        XCTAssertEqual(state.messages.map(\.id), ["old", "tail", "final"])
        XCTAssertEqual(state.state, "idle")
        XCTAssertTrue(state.historyIsBounded)
        XCTAssertEqual(state.partialText, "")
    }

    func testWebSocketDecodesInitMessageEndAndStateWithoutToolFrames() throws {
        let initial = try ConversationLiveEvent.decodeServerEvent(Data("""
        {"type":"init","data":{"messages":[{"msg_id":"m1","role":"assistant","timestamp":1700000000,"content":[{"type":"text","text":"cola"}]}],"state":"running","history_truncated":true}}
        """.utf8))
        let ended = try ConversationLiveEvent.decodeServerEvent(Data(#"{"type":"message_end","data":{"msg_id":"m2","text":"final"}}"#.utf8))
        let state = try ConversationLiveEvent.decodeServerEvent(Data(#"{"type":"state_change","data":{"state":"idle"}}"#.utf8))
        let tool = try ConversationLiveEvent.decodeServerEvent(Data(#"{"type":"tool_end","data":{"result":"private"}}"#.utf8))

        XCTAssertEqual(initial, .initial(messages: [.init(id: "m1", role: "assistant", timestamp: Date(timeIntervalSince1970: 1_700_000_000), text: "cola")], state: "running", historyTruncated: true))
        XCTAssertEqual(ended, .messageEnded(.init(id: "m2", role: "assistant", text: "final")))
        XCTAssertEqual(state, .stateChanged("idle"))
        XCTAssertNil(tool)
    }

    func testSendRequestContainsTextAndExplicitEmptyAttachments() throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder.moaOps.encode(ConversationSendRequest(text: "continúa"))) as? [String: Any]
        XCTAssertEqual(body?["text"] as? String, "continúa")
        XCTAssertEqual(body?["attachments"] as? [String], [])
    }
}
