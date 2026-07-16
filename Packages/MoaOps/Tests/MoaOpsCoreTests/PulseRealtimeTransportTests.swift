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
        let call = try await client.beginCall(credential: credential(), executor: PulseGenericToolExecutor(service: RealtimeStub()), initialContext: "initial", onState: { _ in }, onText: { _ in }, onAudio: { _, _ in }, onBargeIn: {})
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
        let call = try await client.beginCall(credential: credential(), executor: PulseGenericToolExecutor(service: RealtimeStub()), initialContext: "", onState: { _ in }, onText: { _ in }, onAudio: { _, _ in }, onBargeIn: {})
        await call.end()
        let cancelled = await socket.wasCancelled
        let resumes = await socket.resumeCount
        XCTAssertTrue(cancelled)
        XCTAssertEqual(resumes, 1)
    }

    func testSpeechStartedFlushesPlaybackAndDropsInterruptedAudio() async throws {
        let firstAudio = Data([1, 2]).base64EncodedString()
        let interruptedAudio = Data([3, 4]).base64EncodedString()
        let nextAudio = Data([5, 6]).base64EncodedString()
        let socket = FixtureSocket(events: [
            #"{"type":"response.created"}"#,
            #"{"type":"response.output_audio.delta","delta":"\#(firstAudio)"}"#,
            #"{"type":"input_audio_buffer.speech_started"}"#,
            #"{"type":"response.output_audio.delta","delta":"\#(interruptedAudio)"}"#,
            #"{"type":"response.created"}"#,
            #"{"type":"response.output_audio.delta","delta":"\#(nextAudio)"}"#,
        ])
        let recorder = BargeInRecorder()
        let client = OpenAIRealtimeClient(socketFactory: FixtureSocketFactory(socket: socket))
        // onAudio/onBargeIn fire synchronously from the read loop in wire order;
        // recording synchronously keeps that order deterministic (an intervening
        // Task per delta would interleave and make the assertion flaky).
        let call = try await client.beginCall(credential: credential(), executor: PulseGenericToolExecutor(service: RealtimeStub()), initialContext: "", onState: { _ in }, onText: { _ in }, onAudio: { pcm, _ in recorder.append(pcm) }, onBargeIn: { recorder.recordBargeIn() })
        await waitUntil { recorder.hasExpectedBargeIn() }
        XCTAssertEqual(recorder.bargeInCount, 1)
        XCTAssertEqual(recorder.audio, [Data([1, 2]), Data([5, 6])])
        await call.end()
    }

    func testSpeechStartedTruncatesInProgressAudioResponse() async throws {
        let audio = Data([1, 2, 3, 4]).base64EncodedString()
        let socket = FixtureSocket(events: [
            #"{"type":"response.created"}"#,
            #"{"type":"response.output_audio.delta","item_id":"item-audio-1","delta":"\#(audio)"}"#,
            #"{"type":"input_audio_buffer.speech_started"}"#,
        ])
        let client = OpenAIRealtimeClient(socketFactory: FixtureSocketFactory(socket: socket))
        let call = try await client.beginCall(credential: credential(), executor: PulseGenericToolExecutor(service: RealtimeStub()), initialContext: "", onState: { _ in }, onText: { _ in }, onAudio: { _, _ in }, onBargeIn: {})
        await waitUntil { await socket.sentJSON.contains { $0["type"] as? String == "conversation.item.truncate" } }
        let frames = await socket.sentJSON
        let truncate = try XCTUnwrap(frames.first { $0["type"] as? String == "conversation.item.truncate" })
        XCTAssertEqual(truncate["item_id"] as? String, "item-audio-1")
        XCTAssertEqual(truncate["content_index"] as? Int, 0)
        XCTAssertEqual(truncate["audio_end_ms"] as? Int, 0)
        await call.end()
    }

    func testSessionEnablesInputAudioTranscription() async throws {
        let socket = FixtureSocket(events: [])
        let client = OpenAIRealtimeClient(socketFactory: FixtureSocketFactory(socket: socket))
        let call = try await client.beginCall(credential: credential(), executor: PulseGenericToolExecutor(service: RealtimeStub()), initialContext: "", onState: { _ in }, onText: { _ in }, onAudio: { _, _ in }, onBargeIn: {})
        await waitUntil { await socket.sentJSON.contains { $0["type"] as? String == "session.update" } }
        let frames = await socket.sentJSON
        let session = try XCTUnwrap(frames.first { $0["type"] as? String == "session.update" })
        let payload = try XCTUnwrap(session["session"] as? [String: Any])
        let input = try XCTUnwrap((payload["audio"] as? [String: Any])?["input"] as? [String: Any])
        XCTAssertNotNil(input["transcription"])
        await call.end()
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

private final class BargeInRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _bargeInCount = 0
    private var _audio: [Data] = []
    var bargeInCount: Int { lock.lock(); defer { lock.unlock() }; return _bargeInCount }
    var audio: [Data] { lock.lock(); defer { lock.unlock() }; return _audio }
    func recordBargeIn() { lock.lock(); _bargeInCount += 1; lock.unlock() }
    func append(_ value: Data) { lock.lock(); _audio.append(value); lock.unlock() }
    func hasExpectedBargeIn() -> Bool { lock.lock(); defer { lock.unlock() }; return _bargeInCount == 1 && _audio == [Data([1, 2]), Data([5, 6])] }
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
