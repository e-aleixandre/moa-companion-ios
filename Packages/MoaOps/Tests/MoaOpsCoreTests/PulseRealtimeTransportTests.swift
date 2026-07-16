import Foundation
import XCTest
@testable import MoaOpsCore

final class PulseRealtimeTransportTests: XCTestCase {
    func testSessionConfigurationAndMultipleFunctionCallsCreateOneFollowUpResponse() async throws {
        let socket = FixtureSocket(events: [
            #"{"type":"response.function_call_arguments.done","call_id":"call-1","name":"list_sessions","arguments":"{}"}"#,
            #"{"type":"response.function_call_arguments.done","call_id":"call-2","name":"list_sessions","arguments":"{}"}"#,
            #"{"type":"response.done"}"#,
        ])
        let client = OpenAIRealtimeClient(socketFactory: FixtureSocketFactory(socket: socket))
        let call = try await client.beginCall(credential: credential(), executor: PulseGenericToolExecutor(service: RealtimeStub()), initialContext: "initial", onState: { _ in }, onText: { _ in }, onAudio: { _ in })
        await waitUntil { await socket.sentJSON.contains { $0["type"] as? String == "response.create" } }
        let frames = await socket.sentJSON
        let session = try XCTUnwrap(frames.first { $0["type"] as? String == "session.update" })
        let payload = try XCTUnwrap(session["session"] as? [String: Any])
        let audio = try XCTUnwrap(payload["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let inputFormat = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(inputFormat["rate"] as? Int, 24_000)
        XCTAssertEqual((input["turn_detection"] as? [String: Any])?["type"] as? String, "semantic_vad")
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        let outputFormat = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(outputFormat["rate"] as? Int, 24_000)
        let outputs = frames.filter { ($0["item"] as? [String: Any])?["type"] as? String == "function_call_output" }
        XCTAssertEqual(outputs.count, 2)
        let functionOutput = try XCTUnwrap(outputs.first)
        let item = try XCTUnwrap(functionOutput["item"] as? [String: Any])
        let outputText = try XCTUnwrap(item["output"] as? String)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(outputText.utf8)))
        let responseCreates = frames.filter { $0["type"] as? String == "response.create" }
        XCTAssertEqual(responseCreates.count, 1)
        let lastOutput = try XCTUnwrap(frames.lastIndex { ($0["item"] as? [String: Any])?["type"] as? String == "function_call_output" })
        let responseCreate = try XCTUnwrap(frames.lastIndex { $0["type"] as? String == "response.create" })
        XCTAssertGreaterThan(responseCreate, lastOutput)
        await call.end()
    }

    func testCancellationClosesSocketAndNeverNeedsASecondSocket() async throws {
        let socket = FixtureSocket(events: [])
        let client = OpenAIRealtimeClient(socketFactory: FixtureSocketFactory(socket: socket))
        let call = try await client.beginCall(credential: credential(), executor: PulseGenericToolExecutor(service: RealtimeStub()), initialContext: "", onState: { _ in }, onText: { _ in }, onAudio: { _ in })
        await call.end()
        let cancelled = await socket.wasCancelled
        let resumes = await socket.resumeCount
        XCTAssertTrue(cancelled)
        XCTAssertEqual(resumes, 1)
    }

    private func credential() throws -> PulseRealtimeClientCredential {
        try JSONDecoder.moaOps.decode(PulseRealtimeClientCredential.self, from: Data(#"{"client_secret":"ek_fixture","expires_at":1900000000,"transport":"websocket","endpoint":"wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini","model":"gpt-realtime-2.1-mini"}"#.utf8))
    }

    private func waitUntil(_ condition: @Sendable () async -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor FixtureSocket: PulseRealtimeSocket {
    private var events: [String]
    private(set) var sentJSON: [[String: Any]] = []
    private(set) var wasCancelled = false
    private(set) var resumeCount = 0
    init(events: [String]) { self.events = events }
    func resume() { resumeCount += 1 }
    func send(text: String) throws { sentJSON.append((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]) }
    func receive() throws -> String {
        guard !events.isEmpty else { throw OpenAIRealtimeClientError.transport }
        return events.removeFirst()
    }
    func cancel() { wasCancelled = true }
}

private struct FixtureSocketFactory: PulseRealtimeSocketFactory {
    let socket: FixtureSocket
    func makeSocket(request _: URLRequest) async -> any PulseRealtimeSocket { socket }
}

private actor RealtimeStub: PulseGenericToolService {
    func listSessions() async throws -> [MoaServeSessionInfo] { [] }
    func attention() async throws -> MoaServeAttentionResponse { try decode(#"{"items":[]}"#) }
    func readSession(sessionID: String, limit: Int, cursor: String?) async throws -> MoaServeConversationPage { throw PulseCallError.operationUnavailable }
    func readToolDetail(sessionID: String, itemID: String) async throws -> MoaServeToolDetail { throw PulseCallError.operationUnavailable }
    func listSubagents(sessionID: String) async throws -> MoaServeSubagentListResponse { throw PulseCallError.operationUnavailable }
    func readSubagent(sessionID: String, jobID: String, limit: Int, cursor: String?) async throws -> MoaServeSubagentPage { throw PulseCallError.operationUnavailable }
    func sendMessage(sessionID: String, text: String) async throws -> MoaServeSendMessageResponse { throw PulseCallError.operationUnavailable }
    func respondAsk(sessionID: String, askID: String, answers: [String]) async throws {}
    func decidePermission(sessionID: String, permissionID: String, approved: Bool, feedback: String?) async throws {}
    func createSession(title: String?, cwd: String?, model: String?) async throws -> MoaServeSessionInfo { throw PulseCallError.operationUnavailable }
    func resumeSession(sessionID: String) async throws -> MoaServeSessionInfo { throw PulseCallError.operationUnavailable }
    func cancelRun(sessionID: String) async throws {}
    func archiveSession(sessionID: String) async throws -> MoaServeArchiveSessionResponse { throw PulseCallError.operationUnavailable }
    private func decode<T: Decodable>(_ value: String) throws -> T { try JSONDecoder.moaOps.decode(T.self, from: Data(value.utf8)) }
}
