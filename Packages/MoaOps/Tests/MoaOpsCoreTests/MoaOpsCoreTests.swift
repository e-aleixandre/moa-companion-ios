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

    func testAskRequestEncodingContainsOnlyQuestionText() throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder.moaOps.encode(OpsAskRequest(text: "Give me a sitrep."))) as? [String: String]

        XCTAssertEqual(object, ["text": "Give me a sitrep."])
    }

    func testAskResponseAcceptsOptionalResolutionAndBriefing() throws {
        let data = Data("""
        {"kind":"sitrep","briefing":{"sessions":[],"blockers":[],"spoken":"No sessions."}}
        """.utf8)

        let response = try JSONDecoder.moaOps.decode(OpsAskResponse.self, from: data)

        XCTAssertEqual(response.kind, .sitrep)
        XCTAssertNil(response.resolution)
        XCTAssertEqual(response.briefing?.blockers, [])
    }

    func testAskResponseMapsUnknownKindSafely() throws {
        let response = try JSONDecoder.moaOps.decode(OpsAskResponse.self, from: Data(#"{"kind":"future_answer"}"#.utf8))

        XCTAssertEqual(response.kind, .unknown)
        XCTAssertNil(response.briefing)
    }

    func testSubmitInstructionIncludesCSRFHeaderAndJSONBody() async throws {
        let recorder = RequestRecorder()
        RequestCapturingURLProtocol.handler = { request in
            recorder.record(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("""
            {"action":"send","target":{"id":"session-1","title":"Ops","project":"/work/moa"}}
            """.utf8))
        }
        defer { RequestCapturingURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCapturingURLProtocol.self]
        let client = try MoaOpsClient(baseURL: URL(string: "https://ops.example")!, session: URLSession(configuration: configuration))
        let instruction = OpsInstructionRequest(target: "session-1", text: "continue", requestID: "retry-id")

        _ = try await client.submitInstruction(instruction)

        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.url?.path, "/api/ops/instruction")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Request-ID"), "retry-id")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Moa-Request"), "1")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["target": "session-1", "text": "continue", "request_id": "retry-id"])
    }

    func testAskIncludesCSRFHeaderAndTextOnlyJSONBody() async throws {
        let recorder = RequestRecorder()
        RequestCapturingURLProtocol.handler = { request in
            recorder.record(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("""
            {"kind":"blockers","briefing":{"sessions":null,"blockers":[],"spoken":"No blockers."}}
            """.utf8))
        }
        defer { RequestCapturingURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCapturingURLProtocol.self]
        let client = try MoaOpsClient(baseURL: URL(string: "https://ops.example")!, session: URLSession(configuration: configuration))

        _ = try await client.ask(.init(text: "What is blocked?"))

        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.url?.path, "/api/ops/ask")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Moa-Request"), "1")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["text": "What is blocked?"])
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

    func testPulseDecodesExactSafeWireContract() throws {
        let data = Data("""
        {"generated_at":"2026-07-11T17:00:00Z","summary":{"needs_attention":1,"in_progress":1,"stale_work":1,"on_track":0,"changes":1},"needs_attention":[{"id":"pulse:attention:s1:permission_needed","session":{"id":"s1","title":"Release","project":"/work/release"},"category":"permission_needed","priority":2,"lifecycle":"running","activity":"permission","observed_at":"2026-07-11T16:59:00Z","freshness":"fresh","facts":[{"kind":"attention_reason","value":"permission_needed","provenance":"derived"},{"kind":"activity","value":"permission","at":"2026-07-11T16:59:00Z","provenance":"observed"}],"directed_instruction":{"target_id":"s1"}}],"in_progress":[{"id":"pulse:active:s2:in_progress","session":{"id":"s2","title":"Build","project":"/work/build"},"category":"in_progress","lifecycle":"running","activity":"running","freshness":"fresh","facts":[]}],"stale_work":[{"id":"pulse:stale_work:s3","session":{"id":"s3","title":"Old","project":"/work/old"},"category":"stale_work","lifecycle":"running","activity":"running","freshness":"stale","facts":[{"kind":"activity","value":"running","provenance":"observed"}]}],"on_track":[],"changes":{"requested":true,"until":"2026-07-11T17:00:00Z","items":[{"id":"pulse:change:s1:run_started:run-1","session":{"id":"s1","title":"Release","project":"/work/release"},"category":"run_started","lifecycle":"running","activity":"running","freshness":"fresh","facts":[{"kind":"milestone","value":"run_started","ref_id":"run-1","provenance":"observed"}]}],"next_cursor":"opaque-next-page","has_more":true}}
        """.utf8)

        let pulse = try JSONDecoder.moaOps.decode(OpsPulse.self, from: data)

        XCTAssertEqual(pulse.summary.needsAttention, 1)
        XCTAssertEqual(pulse.needsAttention[0].directedInstruction?.targetID, "s1")
        XCTAssertNil(pulse.needsAttention[0].verification)
        XCTAssertEqual(pulse.needsAttention[0].facts.count, 2)
        XCTAssertEqual(pulse.changes.items[0].facts[0].refID, "run-1")
        XCTAssertEqual(pulse.changes.nextCursor, "opaque-next-page")
        XCTAssertTrue(pulse.changes.hasMore)
        XCTAssertEqual(pulse.summary.staleWork, 1)
        XCTAssertEqual(pulse.staleWork.first?.category, "stale_work")
        XCTAssertTrue(pulse.changes.requested)
    }

    func testPulseUsesOpaqueCursorOnlyAndMapsRetentionGap() async throws {
        let recorder = RequestRecorder()
        RequestCapturingURLProtocol.handler = { request in
            recorder.record(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 410, httpVersion: nil, headerFields: nil)!
            return (response, Data("{\"reset\":true}".utf8))
        }
        defer { RequestCapturingURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCapturingURLProtocol.self]
        let client = try MoaOpsClient(baseURL: URL(string: "https://ops.example")!, session: URLSession(configuration: configuration))
        let cursor = "opaque-cursor-not-a-timestamp"

        do {
            _ = try await client.pulse(cursor: cursor)
            XCTFail("Expected retention status")
        } catch let error as MoaOpsClientError {
            XCTAssertEqual(error, .pulseResetRequired)
        }
        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.url?.path, "/api/ops/pulse")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query, [URLQueryItem(name: "cursor", value: cursor)])
    }

    func testUnknownInstructionActionIsRejected() throws {
        XCTAssertThrowsError(try JSONDecoder.moaOps.decode(OpsInstructionResponse.self, from: Data("""
        {"action":"sent","target":{"id":"s1"}}
        """.utf8)))
    }

    func testConversationSendUsesCanonicalHeadersAndTextOnlyAttachments() async throws {
        let recorder = RequestRecorder()
        RequestCapturingURLProtocol.handler = { request in
            recorder.record(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, Data(#"{"action":"steer"}"#.utf8))
        }
        defer { RequestCapturingURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCapturingURLProtocol.self]
        let client = try MoaOpsClient(baseURL: URL(string: "https://ops.example")!, session: URLSession(configuration: configuration))

        let response = try await client.sendConversation(sessionID: "session-1", text: "continúa")

        XCTAssertEqual(response.action, .steer)
        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.url?.path, "/api/sessions/session-1/send")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Moa-Request"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["text"] as? String, "continúa")
        XCTAssertEqual(object["attachments"] as? [String], [])
    }

    func testConversationCursorBadRequestMapsToSafeReload() async throws {
        RequestCapturingURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        defer { RequestCapturingURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCapturingURLProtocol.self]
        let client = try MoaOpsClient(baseURL: URL(string: "https://ops.example")!, session: URLSession(configuration: configuration))
        do {
            _ = try await client.conversation(sessionID: "s1", cursor: "expired")
            XCTFail("Expected reset")
        } catch let error as MoaOpsClientError {
            XCTAssertEqual(error, .conversationResetRequired)
        }
    }
}

private final class RequestRecorder {
    private let lock = NSLock()
    private var capturedRequest: URLRequest?

    func record(_ request: URLRequest) {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            request.httpBody = body
        }
        lock.lock()
        capturedRequest = request
        lock.unlock()
    }

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequest
    }
}

private final class RequestCapturingURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
