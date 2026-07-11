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
            {"action":"sent","target":{"id":"session-1","title":"Ops","project":"/work/moa"}}
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
