import Foundation
import XCTest
@testable import MoaOpsCore

final class PulseGenericRealtimeToolsTests: XCTestCase {
    func testCatalogIsStrictAndContainsGenericV1ToolsIncludingSubagent() throws {
        let definitions = PulseGenericToolCatalog.definitions
        XCTAssertEqual(definitions.map(\.name), ["list_sessions", "read_session", "read_tool_detail", "read_subagent", "send_message", "respond_ask", "decide_permission", "create_session", "resume_session", "cancel_run", "archive_session"])
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder.moaOps.encode(definitions)) as! [[String: Any]]
        for item in encoded { XCTAssertEqual((item["parameters"] as? [String: Any])?["additionalProperties"] as? Bool, false) }
        let readSubagent = try XCTUnwrap(encoded.first { $0["name"] as? String == "read_subagent" })
        XCTAssertEqual((readSubagent["parameters"] as? [String: Any])?["required"] as? [String], ["session_id"])
        XCTAssertFalse(encoded.contains { (($0["name"] as? String) ?? "").contains("prepare") || (($0["name"] as? String) ?? "").contains("confirm") })
    }

    func testParserRejectsAdditionalPropertiesWrongTypesAndBounds() throws {
        XCTAssertEqual(try PulseGenericToolRequest(name: "read_subagent", arguments: Data(#"{"session_id":"s1","job_id":"job1","limit":100,"cursor":"next"}"#.utf8)), .readSubagent(sessionID: "s1", jobID: "job1", limit: 100, cursor: "next"))
        XCTAssertEqual(try PulseGenericToolRequest(name: "read_subagent", arguments: Data(#"{"session_id":"s1"}"#.utf8)), .readSubagent(sessionID: "s1", jobID: nil, limit: 20, cursor: nil))
        for input in [#"{"session_id":"s1","job_id":"job1","extra":1}"#, #"{"session_id":"s1","job_id":"job1","limit":"20"}"#, #"{"session_id":"s1","job_id":"job1","limit":101}"#, #"{"session_id":"../s","job_id":"job1"}"#] {
            XCTAssertThrowsError(try PulseGenericToolRequest(name: "read_subagent", arguments: Data(input.utf8)))
        }
        XCTAssertThrowsError(try PulseGenericToolRequest(name: "send_message", arguments: Data(#"{"session_id":"s1","text":false}"#.utf8)))
    }

    func testSubagentKeepsToolOutputsOutOfMetadataAndAttentionIncludesItsDetail() async throws {
        let executor = PulseGenericToolExecutor(service: Stub())
        let subagent = await executor.execute(.init(id: "1", name: "read_subagent", arguments: Data(#"{"session_id":"s1","job_id":"job1"}"#.utf8)))
        XCTAssertFalse(subagent.isError)
        XCTAssertFalse(subagent.output.contains("tool-output-detail"))
        XCTAssertTrue(subagent.output.contains("job1"))
        let list = await executor.execute(.init(id: "2", name: "list_sessions", arguments: Data("{}".utf8)))
        XCTAssertTrue(list.output.contains("spoken-secret"))
        XCTAssertTrue(list.output.contains("verbatim-secret"))
        XCTAssertTrue(list.output.contains("alias-secret"))
        XCTAssertTrue(list.output.contains("pending"))
        XCTAssertTrue(list.output.contains("\"session_id\":\"s1\""))
        XCTAssertLessThanOrEqual(list.output.utf8.count, PulseGenericToolBounds.resultBytes)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(list.output.utf8)))
    }

    func testListSessionsIncludesNonEmptyAttentionRiskMetadata() async throws {
        let executor = PulseGenericToolExecutor(service: Stub())
        let result = await executor.execute(.init(id: "risks", name: "list_sessions", arguments: Data("{}".utf8)))
        XCTAssertFalse(result.isError)
        let object = try transcriptObject(result.output)
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        let attention = try XCTUnwrap(sessions.first?["attention"] as? [[String: Any]])
        let risk = try XCTUnwrap(attention.first { $0["alias"] as? String == "alias-secret" })
        let emptyRisk = try XCTUnwrap(attention.first { $0["alias"] as? String == "empty-risk" })

        XCTAssertEqual(risk["risk_level"] as? String, "high")
        XCTAssertEqual(risk["risk_flags"] as? [String], ["shell", "write"])
        XCTAssertNil(emptyRisk["risk_level"])
        XCTAssertNil(emptyRisk["risk_flags"])
    }

    func testTranscriptResultsAreChronological() async throws {
        let executor = PulseGenericToolExecutor(service: Stub(orderedTranscript: true))
        let session = await executor.execute(.init(id: "session", name: "read_session", arguments: Data(#"{"session_id":"s1"}"#.utf8)))
        let subagent = await executor.execute(.init(id: "subagent", name: "read_subagent", arguments: Data(#"{"session_id":"s1","job_id":"job1"}"#.utf8)))

        for (result, expectedIDs) in [(session, ["oldest", "middle", "newest"]), (subagent, ["sub-oldest", "sub-newest"])] {
            XCTAssertFalse(result.isError)
            let object = try transcriptObject(result.output)
            XCTAssertEqual(object["order"] as? String, "chronological")
            let items = try XCTUnwrap(object["items"] as? [[String: Any]])
            XCTAssertEqual(items.compactMap { $0["id"] as? String }, expectedIDs)
        }
    }

    func testReadSubagentWithoutJobIDListsDiscoverableTasks() async throws {
        let executor = PulseGenericToolExecutor(service: Stub())
        let result = await executor.execute(.init(id: "subagents", name: "read_subagent", arguments: Data(#"{"session_id":"s1"}"#.utf8)))
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("job1"))
        XCTAssertTrue(result.output.contains("restored task"))
        XCTAssertTrue(result.output.contains("running"))
    }

    func testReadToolDetailIsOnlyOutputRouteAndResultFallbackIsValidJSON() async throws {
        let executor = PulseGenericToolExecutor(service: Stub())
        let detail = await executor.execute(.init(id: "1", name: "read_tool_detail", arguments: Data(#"{"session_id":"s1","item_id":"tool1"}"#.utf8)))
        XCTAssertTrue(detail.output.contains("explicit-detail"))
        let huge = await executor.execute(.init(id: "2", name: "read_session", arguments: Data(#"{"session_id":"s1","limit":100}"#.utf8)))
        XCTAssertLessThanOrEqual(huge.output.utf8.count, PulseGenericToolBounds.resultBytes)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(huge.output.utf8)))
    }

    func testMaximumTranscriptTextFitsInsideTheLargerJSONEnvelope() async throws {
        let text = String(repeating: "z", count: PulseGenericToolBounds.transcriptText)
        let executor = PulseGenericToolExecutor(service: Stub(singleLargeItem: true))
        let result = await executor.execute(.init(id: "large", name: "read_session", arguments: Data(#"{"session_id":"s1"}"#.utf8)))
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains(text))
        XCTAssertLessThanOrEqual(result.output.utf8.count, PulseGenericToolBounds.resultBytes)
    }

    func testRejectedArgumentsAlsoReturnBoundedJSONRatherThanRawModelInput() async throws {
        let executor = PulseGenericToolExecutor(service: Stub())
        let result = await executor.execute(.init(id: "bad", name: "send_message", arguments: Data(#"{"session_id":"s1","text":"ok","headers":"Bearer never"}"#.utf8)))
        XCTAssertTrue(result.isError)
        XCTAssertLessThanOrEqual(result.output.utf8.count, PulseGenericToolBounds.resultBytes)
        let object = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        XCTAssertNotNil(object?["error"])
        XCTAssertFalse(result.output.contains("Bearer"))
    }

    func testServiceErrorNeverReturnsRawTransportDetails() async throws {
        let executor = PulseGenericToolExecutor(service: Stub(failSend: true))
        let result = await executor.execute(.init(id: "error", name: "send_message", arguments: Data(#"{"session_id":"s1","text":"ok"}"#.utf8)))
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.output.contains("https://"))
        XCTAssertFalse(result.output.contains("Authorization"))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(result.output.utf8)))
    }

    func testActionStateErrorsTellTheModelToRereadState() async throws {
        for status in [400, 404, 409] {
            let executor = PulseGenericToolExecutor(service: Stub(actionStatusCode: status))
            let result = await executor.execute(.init(id: "state", name: "send_message", arguments: Data(#"{"session_id":"s1","text":"ok"}"#.utf8)))
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.output.contains("ya no está esperando"))
            XCTAssertTrue(result.output.contains("relee el estado"))
        }
    }
}

private actor Stub: PulseGenericToolService {
    private let failSend: Bool
    private let actionStatusCode: Int?
    private let singleLargeItem: Bool
    private let orderedTranscript: Bool
    init(failSend: Bool = false, actionStatusCode: Int? = nil, singleLargeItem: Bool = false, orderedTranscript: Bool = false) { self.failSend = failSend; self.actionStatusCode = actionStatusCode; self.singleLargeItem = singleLargeItem; self.orderedTranscript = orderedTranscript }
    func listSessions() async throws -> [MoaServeSessionInfo] { [try session()] }
    func attention() async throws -> MoaServeAttentionResponse { try decode(#"{"items":[{"id":"a","priority":0,"kind":"permission","session_id":"s1","alias":"alias-secret","spoken":"spoken-secret","verbatim":"verbatim-secret","state":"pending","created_at":"2026-01-01T00:00:00Z","ref_id":"p1","risk_level":"high","risk_flags":["shell","write"]},{"id":"b","priority":1,"kind":"ask","session_id":"s1","alias":"empty-risk","spoken":"empty-risk","state":"pending","created_at":"2026-01-01T00:00:00Z","risk_level":"","risk_flags":[]}]}"#) }
    func readSession(sessionID: String, limit: Int, cursor: String?) async throws -> MoaServeConversationPage { try decode(orderedTranscript ? orderedSessionPage() : page()) }
    func readToolDetail(sessionID: String, itemID: String) async throws -> MoaServeToolDetail { try decode(#"{"output":"explicit-detail","truncated":false}"#) }
    func listSubagents(sessionID: String) async throws -> MoaServeSubagentListResponse { try decode(#"{"session_id":"s1","subagents":[{"job_id":"job1","task":"restored task","model":"gpt-5","status":"running","async":true,"started_at":"2026-01-01T00:00:00Z","source":"active"}]}"#) }
    func readSubagent(sessionID: String, jobID: String, limit: Int, cursor: String?) async throws -> MoaServeSubagentPage { try decode(orderedTranscript ? orderedSubagentPage() : #"{"session_id":"s1","job_id":"job1","order":"newest_first","messages":[{"id":"t","role":"tool","text":"tool-output-detail","tool":"bash","status":"ok"}],"has_more":false}"#) }
    func sendMessage(sessionID: String, text: String) async throws -> MoaServeSendMessageResponse {
        if failSend { throw StubError.server("https://secret.example Authorization: Bearer hidden") }
        if let actionStatusCode { throw PulseCallError.httpStatus(code: actionStatusCode, retryAfter: nil) }
        return try decode(#"{"action":"send"}"#)
    }
    func respondAsk(sessionID: String, askID: String, answers: [String]) async throws {}
    func decidePermission(sessionID: String, permissionID: String, approved: Bool, feedback: String?) async throws {}
    func createSession(title: String?, cwd: String?, model: String?) async throws -> MoaServeSessionInfo { try session() }
    func resumeSession(sessionID: String) async throws -> MoaServeSessionInfo { try session() }
    func cancelRun(sessionID: String) async throws {}
    func archiveSession(sessionID: String) async throws -> MoaServeArchiveSessionResponse { try decode(#"{"ok":true,"archived":true}"#) }
    private func session() throws -> MoaServeSessionInfo { try decode(#"{"id":"s1","title":"Test","state":"idle","model":"gpt-5","provider":"openai","thinking":"low","cwd":"/private","created":"2026-01-01T00:00:00Z","updated":"2026-01-01T00:00:00Z","context_percent":0,"permission_mode":"ask","cost_usd":0}"#) }
    private func page() -> String {
        let count = singleLargeItem ? 1 : 20
        let text = String(repeating: singleLargeItem ? "z" : "x", count: singleLargeItem ? PulseGenericToolBounds.transcriptText : 2000)
        return "{\"session_id\":\"s1\",\"title\":\"Test\",\"branch\":{\"source\":\"active\"},\"order\":\"newest_first\",\"messages\":[" + Array(repeating: "{\"id\":\"m\",\"role\":\"assistant\",\"text\":\"" + text + "\"}", count: count).joined(separator: ",") + "],\"has_more\":false}"
    }
    private func orderedSessionPage() -> String {
        #"{"session_id":"s1","title":"Test","branch":{"source":"active"},"order":"newest_first","messages":[{"id":"newest","role":"assistant","text":"newest"},{"id":"middle","role":"tool","tool":"bash","status":"ok"},{"id":"oldest","role":"user","text":"oldest"}],"has_more":false}"#
    }
    private func orderedSubagentPage() -> String {
        #"{"session_id":"s1","job_id":"job1","order":"newest_first","messages":[{"id":"sub-newest","role":"assistant","text":"newest"},{"id":"sub-oldest","role":"user","text":"oldest"}],"has_more":false}"#
    }
    private func decode<T: Decodable>(_ string: String) throws -> T { try JSONDecoder.moaOps.decode(T.self, from: Data(string.utf8)) }
}

private func transcriptObject(_ output: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
}

private enum StubError: Error { case server(String) }
