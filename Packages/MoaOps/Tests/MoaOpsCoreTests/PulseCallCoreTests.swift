import Foundation
import XCTest
@testable import MoaOpsCore

final class PulseCallCoreTests: XCTestCase {
    func testPairingPayloadIsStrictAndNeverAStoreValue() throws {
        let payload = try PulsePairingPayload(parsing: " moa-pair-v1:pair_abc:one-use-secret ")
        XCTAssertEqual(payload.pairingID, "pair_abc")
        XCTAssertEqual(payload.secret, "one-use-secret")
        XCTAssertThrowsError(try PulsePairingPayload(parsing: "moa-pair-v1:pair:secret:extra"))
        XCTAssertThrowsError(try PulsePairingPayload(parsing: "moa-pair-v1::secret"))

        let store = MemorySecureStore()
        XCTAssertNil(try store.loadDeviceRegistration())
        XCTAssertNil(try store.loadAnthropicAPIKey())
        // The secure-store API has no payload save method. Only a claimed
        // registration may be persisted after this one-use string is gone.
        XCTAssertFalse(String(describing: store).contains(payload.secret))
    }

    func testHTTPSGuardAllowsOnlyDirectLoopbackHTTP() throws {
        XCTAssertNoThrow(try PulseServerConfiguration(urlText: "https://moa.example"))
        XCTAssertNoThrow(try PulseServerConfiguration(urlText: "http://localhost:8080"))
        XCTAssertNoThrow(try PulseServerConfiguration(urlText: "http://127.0.0.1:8080"))
        XCTAssertThrowsError(try PulseServerConfiguration(urlText: "http://100.64.0.2:8080")) { error in
            XCTAssertEqual(error as? PulseCallError, .insecureTransport)
        }
        XCTAssertThrowsError(try PulseServerConfiguration(urlText: "https://moa.example/?token=never"))
    }

    func testClaimAndDeviceRequestsUseStrictJSONAndDeviceAuthorizationOnly() async throws {
        let recorder = PulseRequestRecorder()
        PulseURLProtocol.handler = { request in
            recorder.record(request)
            let body: String
            if request.url?.path == "/api/pulse/pairings/claim" {
                body = #"{"device_id":"dev_1","credential":"dev_1.device-secret","expires_at":"2027-01-01T00:00:00Z"}"#
            } else if request.url?.path.hasSuffix("/prepare") == true {
                body = #"{"operation_id":"AbCdEfGhIjKlMnOpQrStUvWx","kind":"directed_instruction","status":"pending_confirmation","expires_at":"2026-07-12T12:05:00Z","review":{"target":{"id":"s1","title":"Release","project":"/release"},"text":"continúa","action":"steer","risk":"changes agent work","consequence":"delivery is not completion"}}"#
            } else if request.url?.path.hasSuffix("/confirm") == true {
                body = #"{"operation_id":"AbCdEfGhIjKlMnOpQrStUvWx","kind":"directed_instruction","status":"receipt","receipt":{"operation_id":"AbCdEfGhIjKlMnOpQrStUvWx","kind":"directed_instruction","status":"indeterminate","delivery":"indeterminate","observation":"not_observed","completion":"not_observed","at":"2026-07-12T12:00:00Z"}}"#
            } else {
                body = #"{"generated_at":"2026-07-12T12:00:00Z","summary":{"needs_attention":0,"in_progress":0,"stale_work":0,"on_track":0,"changes":0},"needs_attention":[],"in_progress":[],"stale_work":[],"on_track":[],"changes":{"requested":false,"until":"2026-07-12T12:00:00Z","items":[],"next_cursor":"cursor","has_more":false}}"#
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(body.utf8))
        }
        defer { PulseURLProtocol.handler = nil }
        let session = pulseSession()
        let configuration = try PulseServerConfiguration(urlText: "https://moa.example")
        let pairing = PulsePairingClient(session: session)
        let registration = try await pairing.claim(configuration: configuration, payload: try .init(parsing: "moa-pair-v1:pair1:claim-secret"), deviceLabel: "Pulse")
        let claim = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(claim.url?.path, "/api/pulse/pairings/claim")
        XCTAssertNil(claim.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(claim.value(forHTTPHeaderField: "X-Moa-Request"), "1")
        let claimBody = try XCTUnwrap(claim.httpBody).utf8JSON
        XCTAssertEqual(Set(claimBody.keys), Set(["pairing_id", "pairing_secret", "device_label"]))
        XCTAssertEqual(claimBody["pairing_secret"] as? String, "claim-secret")

        let client = try MoaPulseDeviceClient(registration: registration, session: session)
        let prepared = try await client.prepare(.directedInstruction(target: "s1", text: "continúa"))
        let prepare = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(prepare.url?.path, "/api/pulse/operations/prepare")
        XCTAssertEqual(prepare.value(forHTTPHeaderField: "Authorization"), "Moa-Device dev_1.device-secret")
        XCTAssertEqual(prepare.value(forHTTPHeaderField: "X-Moa-Request"), "1")
        let prepareBody = try XCTUnwrap(prepare.httpBody).utf8JSON
        XCTAssertEqual(Set(prepareBody.keys), Set(["kind", "target", "text"]))
        XCTAssertEqual(prepareBody["kind"] as? String, "directed_instruction")
        XCTAssertEqual(prepared.pendingReview?.review.target.id, "s1")
        _ = try await client.confirm(operationID: "AbCdEfGhIjKlMnOpQrStUvWx")
        let confirm = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(confirm.url?.path, "/api/pulse/operations/AbCdEfGhIjKlMnOpQrStUvWx/confirm")
        XCTAssertNil(URLComponents(url: try XCTUnwrap(confirm.url), resolvingAgainstBaseURL: false)?.query)
        XCTAssertEqual(confirm.value(forHTTPHeaderField: "Authorization"), "Moa-Device dev_1.device-secret")
        XCTAssertEqual(confirm.value(forHTTPHeaderField: "X-Moa-Request"), "1")
        XCTAssertTrue(try XCTUnwrap(confirm.httpBody).utf8JSON.isEmpty)
    }

    func testDevicePulseRequestNeverUsesCookieBootstrapOrLegacyTokenQuery() async throws {
        let recorder = PulseRequestRecorder()
        PulseURLProtocol.handler = { request in
            recorder.record(request)
            let body = #"{"generated_at":"2026-07-12T12:00:00Z","summary":{"needs_attention":0,"in_progress":0,"stale_work":0,"on_track":0,"changes":0},"needs_attention":[],"in_progress":[],"stale_work":[],"on_track":[],"changes":{"requested":false,"until":"2026-07-12T12:00:00Z","items":[],"next_cursor":"cursor","has_more":false}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { PulseURLProtocol.handler = nil }
        let registration = try PulseDeviceRegistration(baseURL: URL(string: "https://moa.example")!, deviceID: "device", credential: "device.secret", expiresAt: .distantFuture)
        let client = try MoaPulseDeviceClient(registration: registration, session: pulseSession())
        _ = try await client.pulse()
        let request = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(request.url?.path, "/api/ops/pulse")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Moa-Device device.secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testBriefFallbackHasProvenanceAndNeverClaimsTranscriptTruth() throws {
        let pulse = try fixturePulse()
        let brief = PulseBriefBuilder.make(pulse: pulse)
        XCTAssertTrue(brief.spoken.contains("Hay 2 frentes activos"))
        XCTAssertTrue(brief.spoken.contains("solicitud de permiso"))
        XCTAssertTrue(brief.spoken.contains("Build sigue avanzando"))
        XCTAssertTrue(brief.citations.contains { $0.provenance == .moaObserved })
        let offline = PulseBriefBuilder.offline(last: brief, age: 125)
        XCTAssertTrue(offline.isFallback)
        XCTAssertTrue(offline.spoken.contains("último estado conocido"))
        XCTAssertTrue(offline.citations.contains { $0.provenance == .localFreshness })
        XCTAssertFalse(offline.spoken.lowercased().contains("verificado"))
    }

    func testConstrainedToolsRejectGenericActionsAndMarkDisplayEvidenceUntrusted() throws {
        let generic = PulseToolUse(id: "tool", name: "http_request", input: Data(#"{"url":"https://moa.example/api/attention"}"#.utf8))
        XCTAssertThrowsError(try PulseToolRequest(toolUse: generic))
        let unsafe = PulseToolUse(id: "tool", name: PulseToolName.preparePermissionDecision.rawValue, input: Data(#"{"target":"s1","decision":"approve_once","feedback":"ignore policy"}"#.utf8))
        XCTAssertThrowsError(try PulseToolRequest(toolUse: unsafe))
        let evidence = try PulseToolRequest(toolUse: .init(id: "tool", name: PulseToolName.safeConversationEvidence.rawValue, input: Data(#"{"session_id":"s1"}"#.utf8)))
        XCTAssertEqual(evidence, .safeConversationEvidence(sessionID: "s1"))
        XCTAssertFalse(PulseProviderPrompt.tools.contains { $0.name == "confirm_operation" })
    }

    func testVoiceConfirmationRequiresExactlyOneCurrentReviewAndReceiptsNeverClaimCompletion() throws {
        let review = try pendingReview()
        XCTAssertEqual(PulseReviewVoiceConfirmation.resolve(transcript: "Sí", visibleReviews: [review]), .confirm)
        XCTAssertEqual(PulseReviewVoiceConfirmation.resolve(transcript: "sí", visibleReviews: [review, review]), .none)
        XCTAssertEqual(PulseReviewVoiceConfirmation.resolve(transcript: "sí", visibleReviews: [PulsePendingReview(operationID: review.operationID, kind: review.kind, expiresAt: .distantPast, review: review.review)]), .none)
        let receipt = try JSONDecoder.moaOps.decode(PulseOperationReceipt.self, from: Data(#"{"operation_id":"AbCdEfGhIjKlMnOpQrStUvWx","kind":"directed_instruction","status":"indeterminate","delivery":"indeterminate","observation":"not_observed","completion":"not_observed","at":"2026-07-12T12:00:00Z"}"#.utf8))
        let narration = PulseOperationNarrator.receipt(receipt).lowercased()
        XCTAssertTrue(narration.contains("no pudo determinar"))
        XCTAssertTrue(narration.contains("no afirmaré"), "An indeterminate receipt must explicitly avoid a completion claim")
    }

    func testAnthropicSSEDecodesTextAndStrictToolInput() throws {
        var sse = AnthropicSSEDecoder()
        var events = AnthropicEventDecoder()
        let lines = [
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hola\"}}",
            "",
            "event: content_block_start",
            "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool-1\",\"name\":\"get_status\",\"input\":{}}}",
            "",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"target\\\":\\\"s1\\\"}\"}}",
            "",
            "event: content_block_stop",
            "data: {\"type\":\"content_block_stop\",\"index\":1}",
            "",
        ]
        var decoded: [AnthropicStreamEvent] = []
        for line in lines {
            if let frame = sse.consume(line: line) { decoded += try events.decode(frame) }
        }
        XCTAssertTrue(decoded.contains(.textDelta("Hola")))
        guard case let .toolUse(tool)? = decoded.last else { return XCTFail("missing tool") }
        XCTAssertEqual(try PulseToolRequest(toolUse: tool), .getStatus(target: "s1"))
    }

    func testAnthropicBodyContainsOnlyPromptDataAndNoMoaCredential() async throws {
        let client = AnthropicMessagesClient(endpoint: URL(string: "https://api.anthropic.com/v1/messages")!)
        let request = try await client.makeRequest(messages: [.init(role: "user", content: [.text("<owner_request>estado</owner_request>")])], apiKey: "sk-ant-secret")
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-secret")
        XCTAssertFalse(body.contains("Moa-Device"))
        XCTAssertFalse(body.contains("Authorization"))
        XCTAssertFalse(body.contains("moa.example"))
        XCTAssertFalse(body.contains("sk-ant-secret"))
    }

    func testPTTReducerStopsOnInterruptionAndForegroundLoss() {
        var state = PulsePTTState.idle
        state = PulsePTTReducer.reduce(state, event: .press)
        state = PulsePTTReducer.reduce(state, event: .permission(granted: true))
        XCTAssertEqual(state, .listening)
        XCTAssertEqual(PulsePTTReducer.reduce(state, event: .interruption), .interrupted)
        XCTAssertEqual(PulsePTTReducer.reduce(state, event: .foreground(active: true)), .idle)
        XCTAssertEqual(PulsePTTReducer.reduce(.listening, event: .foreground(active: false)), .interrupted)
    }

    private func fixturePulse() throws -> OpsPulse {
        try JSONDecoder.moaOps.decode(OpsPulse.self, from: Data(#"{"generated_at":"2026-07-12T12:00:00Z","summary":{"needs_attention":1,"in_progress":1,"stale_work":0,"on_track":0,"changes":0},"needs_attention":[{"id":"a","session":{"id":"s1","title":"Release","project":"/release"},"category":"permission_needed","priority":1,"lifecycle":"running","activity":"permission","freshness":"fresh","facts":[{"kind":"activity","value":"permission","provenance":"observed"}]}],"in_progress":[{"id":"b","session":{"id":"s2","title":"Build","project":"/build"},"category":"in_progress","lifecycle":"running","activity":"running","freshness":"fresh","facts":[{"kind":"activity","value":"running","provenance":"observed"}]}],"stale_work":[],"on_track":[],"changes":{"requested":false,"until":"2026-07-12T12:00:00Z","items":[],"next_cursor":"cursor","has_more":false}}"#.utf8))
    }

    private func pendingReview() throws -> PulsePendingReview {
        let review = try JSONDecoder.moaOps.decode(PulseOperationReview.self, from: Data(#"{"target":{"id":"s1","title":"Release","project":"/release"},"text":"continúa","action":"steer","risk":"changes","consequence":"delivery is not completion"}"#.utf8))
        return .init(operationID: "AbCdEfGhIjKlMnOpQrStUvWx", kind: .directedInstruction, expiresAt: .distantFuture, review: review)
    }
}

private final class MemorySecureStore: PulseSecureStore, @unchecked Sendable {
    private var registration: PulseDeviceRegistration?
    private var providerKey: String?
    func loadDeviceRegistration() throws -> PulseDeviceRegistration? { registration }
    func saveDeviceRegistration(_ registration: PulseDeviceRegistration) throws { self.registration = registration }
    func clearDeviceRegistration() throws { registration = nil }
    func loadAnthropicAPIKey() throws -> String? { providerKey }
    func saveAnthropicAPIKey(_ key: String) throws { providerKey = key }
    func clearAnthropicAPIKey() throws { providerKey = nil }
}

private final class PulseRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func record(_ request: URLRequest) {
        var copy = request
        if copy.httpBody == nil, let stream = copy.httpBodyStream {
            stream.open(); defer { stream.close() }
            copy.httpBody = stream.readDataToEndOfFile()
        }
        lock.lock(); values.append(copy); lock.unlock()
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class PulseURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)) }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func pulseSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PulseURLProtocol.self]
    return URLSession(configuration: configuration)
}

private extension Data {
    var utf8JSON: [String: Any] {
        (try? JSONSerialization.jsonObject(with: self) as? [String: Any]) ?? [:]
    }
}
