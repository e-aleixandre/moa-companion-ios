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
        // The secure-store API has no payload save method. Only a claimed
        // registration may be persisted after this one-use string is gone.
        XCTAssertFalse(String(describing: store).contains(payload.secret))
    }

    func testPairingQREnvelopeStrictlyBindsServerAndPayload() throws {
        let json = #"{"server_url":"https://moa.example:8443","pairing_payload":"moa-pair-v1:pair_abc:one-use-secret"}"#
        let qr = "moa-pulse-pair-v1:" + base64URL(json)

        let envelope = try PulsePairingEnvelope(parsing: qr)

        XCTAssertEqual(envelope.configuration.baseURL, URL(string: "https://moa.example:8443"))
        XCTAssertEqual(envelope.payload.pairingID, "pair_abc")
        XCTAssertEqual(envelope.payload.secret, "one-use-secret")
        // The raw v1 format remains the manual fallback, not a QR envelope.
        XCTAssertNoThrow(try PulsePairingPayload(parsing: "moa-pair-v1:pair_abc:one-use-secret"))
        XCTAssertThrowsError(try PulsePairingEnvelope(parsing: "moa-pair-v1:pair_abc:one-use-secret"))
    }

    func testPairingQREnvelopeRejectsNonCanonicalOrUnexpectedInput() {
        XCTAssertThrowsError(try PulsePairingEnvelope(parsing: "moa-pulse-pair-v1:not_base64!"))
        XCTAssertThrowsError(try PulsePairingEnvelope(parsing: "moa-pulse-pair-v1:e30="), "Padding is not part of canonical base64url")
        XCTAssertThrowsError(try PulsePairingEnvelope(parsing: "moa-pulse-pair-v1:" + base64URL(#"{"server_url":"https://moa.example","pairing_payload":"moa-pair-v1:p:s","extra":true}"#)))
        XCTAssertThrowsError(try PulsePairingEnvelope(parsing: "moa-pulse-pair-v1:" + base64URL(#"{"server_url":"http://moa.example","pairing_payload":"moa-pair-v1:p:s"}"#)))
        XCTAssertThrowsError(try PulsePairingEnvelope(parsing: "moa-pulse-pair-v1:" + base64URL(#"{"server_url":"https://moa.example","pairing_payload":"moa-pair-v1:p:s:extra"}"#)))
    }

    private func base64URL(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func testHTTPSGuardAllowsOnlyDirectLoopbackHTTP() throws {
        XCTAssertNoThrow(try PulseServerConfiguration(urlText: "https://moa.example"))
        XCTAssertNoThrow(try PulseServerConfiguration(urlText: "http://localhost:8080"))
        XCTAssertNoThrow(try PulseServerConfiguration(urlText: "http://127.0.0.1:8080"))
        XCTAssertNoThrow(try PulseServerConfiguration(urlText: "http://127.255.255.255:8080"))
        XCTAssertNoThrow(try PulseServerConfiguration(urlText: "http://[::1]:8080"))
        XCTAssertThrowsError(try PulseServerConfiguration(urlText: "http://100.64.0.2:8080")) { error in
            XCTAssertEqual(error as? PulseCallError, .insecureTransport)
        }
        XCTAssertThrowsError(try PulseServerConfiguration(urlText: "https://moa.example/?token=never"))
    }

    func testHTTPPlaintextLoopbackGuardRejectsPrefixHostnamesAndMalformedIPv4() throws {
        XCTAssertTrue(PulseServerConfiguration.isLoopback("localhost"))
        XCTAssertTrue(PulseServerConfiguration.isLoopback("::1"))
        XCTAssertTrue(PulseServerConfiguration.isLoopback("[::1]"), "URLComponents may retain IPv6 brackets")
        XCTAssertTrue(PulseServerConfiguration.isLoopback("127.0.0.1"))
        XCTAssertFalse(PulseServerConfiguration.isLoopback("127.evil.example"))
        XCTAssertFalse(PulseServerConfiguration.isLoopback("127.0.0.1.evil"))
        XCTAssertFalse(PulseServerConfiguration.isLoopback("127.0.0.999"))
        XCTAssertFalse(PulseServerConfiguration.isLoopback("127.1"))
        XCTAssertFalse(PulseServerConfiguration.isLoopback("128.0.0.1"))
        XCTAssertFalse(PulseServerConfiguration.isLoopback("localhost.evil.example"))

        for url in [
            "http://127.evil.example:8080",
            "http://127.0.0.1.evil:8080",
            "http://127.0.0.999:8080",
            "http://127.1:8080",
            "http://128.0.0.1:8080",
        ] {
            XCTAssertThrowsError(try PulseServerConfiguration(urlText: url), "\(url) must not receive the HTTP exception") { error in
                XCTAssertEqual(error as? PulseCallError, .insecureTransport)
            }
        }
    }

    func testDeviceRegistrationSecureEncodingRoundTripsWithoutPairingPayload() throws {
        let registration = try PulseDeviceRegistration(
            baseURL: URL(string: "https://moa.example")!,
            deviceID: "device_1",
            credential: "device_1.credential-secret",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let encoded = try PulseDeviceRegistrationCodec.encode(registration)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("moa-pair-v1"))
        XCTAssertEqual(try PulseDeviceRegistrationCodec.decode(encoded), registration)
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
        defer { session.invalidateAndCancel() }
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
        let session = pulseSession()
        defer { session.invalidateAndCancel() }
        let client = try MoaPulseDeviceClient(registration: registration, session: session)
        _ = try await client.pulse()
        let request = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(request.url?.path, "/api/ops/pulse")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Moa-Device device.secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testGenericServeRequestsUseEscapedQueriesAndRejectInvalidRoutesOrResponses() async throws {
        let recorder = PulseRequestRecorder()
        PulseURLProtocol.handler = { request in
            recorder.record(request)
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let body: String
            switch request.url?.path {
            case "/api/sessions":
                body = #"[{"id":"session-1","title":"Fix tests","state":"idle","model":"gpt-5","provider":"openai","thinking":"low","cwd":"/workspace","created":"2026-07-15T18:00:00Z","updated":"2026-07-15T18:01:00Z","context_percent":0,"permission_mode":"ask","cost_usd":0}]"#
            case "/api/attention":
                body = #"{"items":[]}"#
            case "/api/sessions/session-1/messages":
                if components?.queryItems?.contains(where: { $0.name == "detail" && $0.value == "full" }) == true {
                    body = #"{"output":"[non-sensitive fixture marker]"}"#
                } else {
                    body = #"{"session_id":"session-1","title":"Fix tests","branch":{"source":"active"},"order":"newest_first","messages":[],"has_more":false}"#
                }
            default:
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { PulseURLProtocol.handler = nil }

        let session = pulseSession()
        defer { session.invalidateAndCancel() }
        let registration = try PulseDeviceRegistration(baseURL: URL(string: "https://moa.example")!, deviceID: "device", credential: "device.secret", expiresAt: .distantFuture)
        let client = try MoaPulseDeviceClient(registration: registration, session: session)

        let sessions = try await client.listSessions()
        XCTAssertEqual(sessions.map(\.id), ["session-1"])
        let attention = try await client.attention()
        XCTAssertTrue(attention.items.isEmpty)
        _ = try await client.displayMessages(sessionID: "session-1", limit: 20, cursor: "cursor with spaces")
        let messagesRequest = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(messagesRequest.url?.path, "/api/sessions/session-1/messages")
        let messageQuery = try XCTUnwrap(URLComponents(url: try XCTUnwrap(messagesRequest.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(messageQuery.first { $0.name == "limit" }?.value, "20")
        XCTAssertEqual(messageQuery.first { $0.name == "cursor" }?.value, "cursor with spaces")

        _ = try await client.toolDetail(sessionID: "session-1", itemID: "tool:assistant-1:0")
        let detailRequest = try XCTUnwrap(recorder.requests.last)
        let detailQuery = try XCTUnwrap(URLComponents(url: try XCTUnwrap(detailRequest.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(detailQuery.first { $0.name == "detail" }?.value, "full")
        XCTAssertEqual(detailQuery.first { $0.name == "item_id" }?.value, "tool:assistant-1:0")

        do {
            _ = try await client.displayMessages(sessionID: "../other", limit: 20)
            XCTFail("path traversal must be rejected before a request is made")
        } catch let error as PulseCallError {
            XCTAssertEqual(error, .operationUnavailable)
        }
        do {
            _ = try await client.displayMessages(sessionID: "session-1", limit: 101)
            XCTFail("out-of-range limit must be rejected before a request is made")
        } catch let error as PulseCallError {
            XCTAssertEqual(error, .operationUnavailable)
        }

        PulseURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await client.listSessions()
            XCTFail("non-success responses must not decode")
        } catch let error as PulseCallError {
            XCTAssertEqual(error, .httpStatus(code: 403, retryAfter: nil))
        }
    }

    func testGenericServeMutationsUseDeviceAuthorizationStrictPayloadsAndContractStatuses() async throws {
        let recorder = PulseRequestRecorder()
        let sessionFixture = #"{"id":"session-1","title":"Fix tests","state":"idle","model":"gpt-5","provider":"openai","thinking":"low","cwd":"/workspace","created":"2026-07-15T18:00:00Z","updated":"2026-07-15T18:01:00Z","context_percent":0,"permission_mode":"ask","cost_usd":0}"#
        PulseURLProtocol.handler = { request in
            recorder.record(request)
            let response: (Int, String)
            switch request.url?.path {
            case "/api/sessions": response = (201, sessionFixture)
            case "/api/sessions/session-1/send": response = (202, #"{"action":"steer","steer_id":"steer-1"}"#)
            case "/api/sessions/session-1/ask", "/api/sessions/session-1/permission", "/api/sessions/session-1/cancel": response = (204, "")
            case "/api/sessions/session-1/resume": response = (200, sessionFixture)
            case "/api/sessions/session-1/archive": response = (200, #"{"ok":true,"archived":true}"#)
            default: response = (404, "")
            }
            return (HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(response.1.utf8))
        }
        defer { PulseURLProtocol.handler = nil }

        let session = pulseSession(); defer { session.invalidateAndCancel() }
        let registration = try PulseDeviceRegistration(baseURL: URL(string: "https://moa.example")!, deviceID: "device", credential: "device.secret", expiresAt: .distantFuture)
        let client = try MoaPulseDeviceClient(registration: registration, session: session)

        let created = try await client.createSession(.init(model: "gpt-5", title: "Fix tests", cwd: "/workspace"))
        let sent = try await client.sendMessage(sessionID: "session-1", request: .init(text: "continue", attachments: [.init(name: "note.txt", mime: "text/plain", data: "aGVsbG8=")], steerID: "steer-1"))
        try await client.answerAsk(sessionID: "session-1", request: .init(id: "ask-1", answers: [""]))
        try await client.decidePermission(sessionID: "session-1", request: .init(id: "permission-1", approved: true, feedback: "approved", allow: "read:*", rule: "allow read", action: "add_rule"))
        let resumed = try await client.resumeSession(sessionID: "session-1")
        try await client.cancelSession(sessionID: "session-1")
        let archived = try await client.archiveSession(sessionID: "session-1", archived: true)

        XCTAssertEqual(created.id, "session-1")
        XCTAssertEqual(sent.action, "steer")
        XCTAssertEqual(sent.steerID, "steer-1")
        XCTAssertEqual(resumed.id, "session-1")
        XCTAssertTrue(archived.ok)
        XCTAssertTrue(archived.archived)

        let requests = recorder.requests
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/sessions",
            "/api/sessions/session-1/send",
            "/api/sessions/session-1/ask",
            "/api/sessions/session-1/permission",
            "/api/sessions/session-1/resume",
            "/api/sessions/session-1/cancel",
            "/api/sessions/session-1/archive",
        ])
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Moa-Device device.secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Moa-Request"), "1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.url?.query)
        }
        let createBody = try XCTUnwrap(requests[0].httpBody).utf8JSON
        XCTAssertEqual(Set(createBody.keys), Set(["model", "title", "cwd"]))
        XCTAssertEqual(createBody["cwd"] as? String, "/workspace")
        let sendBody = try XCTUnwrap(requests[1].httpBody).utf8JSON
        XCTAssertEqual(Set(sendBody.keys), Set(["text", "attachments", "steer_id"]))
        XCTAssertEqual((sendBody["attachments"] as? [[String: Any]])?.first?["mime"] as? String, "text/plain")
        let askBody = try XCTUnwrap(requests[2].httpBody).utf8JSON
        XCTAssertEqual(Set(askBody.keys), Set(["id", "answers"]))
        XCTAssertEqual(askBody["answers"] as? [String], [""])
        let permissionBody = try XCTUnwrap(requests[3].httpBody).utf8JSON
        XCTAssertEqual(Set(permissionBody.keys), Set(["id", "approved", "feedback", "allow", "rule", "action"]))
        XCTAssertTrue(try XCTUnwrap(requests[4].httpBody).utf8JSON.isEmpty)
        XCTAssertTrue(try XCTUnwrap(requests[5].httpBody).utf8JSON.isEmpty)
        XCTAssertEqual(try XCTUnwrap(requests[6].httpBody).utf8JSON["archived"] as? Bool, true)

        PulseURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"action":"send"}"#.utf8))
        }
        do {
            _ = try await client.sendMessage(sessionID: "session-1", request: .init(text: "continue"))
            XCTFail("send must require the Serve 202 contract status")
        } catch let error as PulseCallError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testGenericServeMutationBodyLimitUsesFinalEncodedDataSize() throws {
        let request = MoaServeAskAnswerRequest(id: "ask-1", answers: [""])
        let encoded = try JSONEncoder.moaOps.encode(request)

        XCTAssertEqual(try XCTUnwrap(encodeMoaServeMutationBody(request, maximumBytes: encoded.count)), encoded)
        XCTAssertNil(encodeMoaServeMutationBody(request, maximumBytes: encoded.count - 1))
        XCTAssertEqual(MoaServeMutationBodyLimit.normal, 1 << 20)
        XCTAssertEqual(MoaServeMutationBodyLimit.send, 90 << 20)
    }

    func testGenericServeMutationsRejectInvalidIdentifiersRoutesAndPayloadsBeforeTransport() async throws {
        let recorder = PulseRequestRecorder()
        PulseURLProtocol.handler = { request in
            recorder.record(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { PulseURLProtocol.handler = nil }

        let session = pulseSession(); defer { session.invalidateAndCancel() }
        let registration = try PulseDeviceRegistration(baseURL: URL(string: "https://moa.example")!, deviceID: "device", credential: "device.secret", expiresAt: .distantFuture)
        let client = try MoaPulseDeviceClient(registration: registration, session: session)

        let invalidCalls: [() async -> Void] = [
            { _ = try? await client.createSession(.init(model: "bad\0model")) },
            { _ = try? await client.sendMessage(sessionID: "../other", request: .init(text: "message")) },
            { _ = try? await client.sendMessage(sessionID: "session-1", request: .init(text: "")) },
            { _ = try? await client.sendMessage(sessionID: "session-1", request: .init(text: "message", attachments: [.init(name: "note.txt", mime: "text/plain", data: "not-base64")])) },
            { try? await client.answerAsk(sessionID: "../other", request: .init(id: "ask-1", answers: ["yes"])) },
            { try? await client.answerAsk(sessionID: "session-1", request: .init(id: "ask/1", answers: [])) },
            { try? await client.decidePermission(sessionID: "session-1", request: .init(id: "permission-1", approved: true, action: "bad\0action")) },
            { _ = try? await client.resumeSession(sessionID: "../other") },
            { try? await client.cancelSession(sessionID: "../other") },
            { _ = try? await client.archiveSession(sessionID: "../other", archived: true) },
        ]
        for call in invalidCalls { await call() }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testRealtimeSecretMintUsesOnlyDeviceAuthAndStrictEmptyBody() async throws {
        let recorder = PulseRequestRecorder()
        PulseURLProtocol.handler = { request in
            recorder.record(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: ["Cache-Control": "no-store"])!, Data(#"{"client_secret":"ek_one_socket","expires_at":1900000000,"transport":"websocket","endpoint":"wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini","model":"gpt-realtime-2.1-mini"}"#.utf8))
        }
        defer { PulseURLProtocol.handler = nil }
        let session = pulseSession(); defer { session.invalidateAndCancel() }
        let registration = try PulseDeviceRegistration(baseURL: URL(string: "https://moa.example")!, deviceID: "device", credential: "device.secret", expiresAt: .distantFuture)
        let credential = try await MoaPulseDeviceClient(registration: registration, session: session).mintRealtimeClientSecret()
        let request = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(request.url?.path, "/api/pulse/realtime/client-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Moa-Device device.secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Moa-Request"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8), "{}")
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Beta"))
        XCTAssertEqual(credential.clientSecret, "ek_one_socket")
        XCTAssertFalse(String(describing: MemorySecureStore()).contains("ek_one_socket"))
    }

    func testRealtimeCredentialRejectsExpiredAndUntrustedEndpoints() throws {
        let expired = Data(#"{"client_secret":"ek_x","expires_at":1,"transport":"websocket","endpoint":"wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini","model":"gpt-realtime-2.1-mini"}"#.utf8)
        let hostile = Data(#"{"client_secret":"ek_x","expires_at":1900000000,"transport":"websocket","endpoint":"wss://evil.example/v1/realtime?model=gpt-realtime-2.1-mini","model":"gpt-realtime-2.1-mini"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder.moaOps.decode(PulseRealtimeClientCredential.self, from: expired).validated())
        XCTAssertThrowsError(try JSONDecoder.moaOps.decode(PulseRealtimeClientCredential.self, from: hostile).validated())
    }

    func testRealtimeCredentialBindsExactConfigurationAndCanonicalOrigin() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func credential(endpoint: String, model: String = OpenAIRealtimeProviderConfiguration.defaultModel) throws -> PulseRealtimeClientCredential {
            try JSONDecoder.moaOps.decode(PulseRealtimeClientCredential.self, from: Data("{\"client_secret\":\"ek_x\",\"expires_at\":1800000000,\"transport\":\"websocket\",\"endpoint\":\"\(endpoint)\",\"model\":\"\(model)\"}".utf8))
        }
        XCTAssertNoThrow(try credential(endpoint: "wss://api.openai.com:443/v1/realtime?model=gpt-realtime-2.1-mini").validated(now: now, configuration: .init()))
        for endpoint in [
            "ws://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini",
            "wss://api.openai.com:444/v1/realtime?model=gpt-realtime-2.1-mini",
            "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini&x=1",
            "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini#fragment",
            "wss://api.openai.com.evil/v1/realtime?model=gpt-realtime-2.1-mini",
        ] { XCTAssertThrowsError(try credential(endpoint: endpoint).validated(now: now)) }
        XCTAssertThrowsError(try credential(endpoint: "wss://api.openai.com/v1/realtime?model=unapproved", model: "unapproved").validated(now: now))
        XCTAssertThrowsError(try credential(endpoint: "wss://api.openai.com/v1/realtime?model=gpt-realtime", model: "gpt-realtime").validated(now: now, configuration: .init()))
        XCTAssertThrowsError(try credential(endpoint: "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini").validated(now: now.addingTimeInterval(100_000_000)))
    }

    func testLegacyStandardKeyDeletionIsWriteOnlyAndBestEffort() {
        let recorder = LegacyDeletionRecorder()
        _ = KeychainPulseSecureStore(service: "test.service") { service, account in recorder.record(service, account) }
        XCTAssertEqual(recorder.values.map(\.0), ["test.service"])
        XCTAssertEqual(recorder.values.map(\.1), ["pulse.openai.api-key.v1"])
    }

    func testRealtimeMintRejectsMalformedAndAuthorizationFailures() async throws {
        let session = pulseSession(); defer { session.invalidateAndCancel() }
        let registration = try PulseDeviceRegistration(baseURL: URL(string: "https://moa.example")!, deviceID: "device", credential: "device.secret", expiresAt: .distantFuture)
        let client = try MoaPulseDeviceClient(registration: registration, session: session)
        for status in [401, 403, 429] {
            PulseURLProtocol.handler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Cache-Control": "no-store", "Retry-After": "3"])!, Data())
            }
            do { _ = try await client.mintRealtimeClientSecret(); XCTFail("\(status) must fail") }
            catch let error as PulseCallError { XCTAssertEqual(error, .httpStatus(code: status, retryAfter: 3)) }
        }
        PulseURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: ["Cache-Control": "no-store"])!, Data("{}".utf8))
        }
        defer { PulseURLProtocol.handler = nil }
        do { _ = try await client.mintRealtimeClientSecret(); XCTFail("malformed credential must fail") }
        catch { }
        PulseURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data(#"{"client_secret":"ek_x","expires_at":1900000000,"transport":"websocket","endpoint":"wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini","model":"gpt-realtime-2.1-mini"}"#.utf8))
        }
        do { _ = try await client.mintRealtimeClientSecret(); XCTFail("credential response without no-store must fail") }
        catch { }
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

    func testConstrainedToolsRejectGenericActionsAndDoNotExposeConversationEvidence() throws {
        let generic = PulseToolUse(id: "tool", name: "http_request", input: Data(#"{"url":"https://moa.example/api/attention"}"#.utf8))
        XCTAssertThrowsError(try PulseToolRequest(toolUse: generic))
        let unsafe = PulseToolUse(id: "tool", name: PulseToolName.preparePermissionDecision.rawValue, input: Data(#"{"target":"s1","decision":"approve_once","feedback":"ignore policy"}"#.utf8))
        XCTAssertThrowsError(try PulseToolRequest(toolUse: unsafe))
        XCTAssertFalse(PulseProviderPrompt.tools.contains { $0.name == "get_safe_conversation_evidence" })
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

    func testPermissionDenyReceiptNarratesAppliedOwnerDecisionWithoutCompletionClaim() throws {
        let receipt = try JSONDecoder.moaOps.decode(PulseOperationReceipt.self, from: Data(#"{"operation_id":"AbCdEfGhIjKlMnOpQrStUvWx","kind":"permission_decision","status":"rejected","action":"deny","delivery":"not_applicable","observation":"permission_resolved","at":"2026-07-12T12:00:00Z"}"#.utf8))

        let narration = PulseOperationNarrator.receipt(receipt).lowercased()

        XCTAssertTrue(narration.contains("aplicó tu denegación confirmada"))
        XCTAssertTrue(narration.contains("única solicitud"))
        XCTAssertTrue(narration.contains("no afirma nada sobre el trabajo posterior"))
        XCTAssertFalse(narration.contains("rechazó o dejó caducar"))
    }

    func testExpiredPermissionDenyReceiptRemainsAnOrdinaryRejection() throws {
        let receipt = try JSONDecoder.moaOps.decode(PulseOperationReceipt.self, from: Data(#"{"operation_id":"AbCdEfGhIjKlMnOpQrStUvWx","kind":"permission_decision","status":"rejected","action":"deny","delivery":"not_applicable","observation":"not_observed","reason":"review_expired","at":"2026-07-12T12:00:00Z"}"#.utf8))

        XCTAssertTrue(PulseOperationNarrator.receipt(receipt).contains("rechazó o dejó caducar"))
    }

    func testOpenAIRealtimeRequestIsDirectAndNeverContainsMoaCredential() async throws {
        let client = OpenAIRealtimeClient(endpoint: URL(string: "wss://api.openai.com/v1/realtime")!)
        let request = try await client.makeRequest(credential: realtimeCredential())
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.host, "api.openai.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ek_test-secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Beta"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(Set(request.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []), ["authorization"])
        XCTAssertFalse(request.url?.absoluteString.contains("Moa-Device") == true)
        XCTAssertFalse(request.url?.absoluteString.contains("moa.example") == true)
    }

    func testRealtimeBrokerCredentialFixtureLocksCanonicalEndpointAndModel() async throws {
        let fixture = Data(#"{"client_secret":"ek_test-secret","expires_at":1900000000,"transport":"websocket","endpoint":"wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini","model":"gpt-realtime-2.1-mini"}"#.utf8)
        let credential = try JSONDecoder.moaOps.decode(PulseRealtimeClientCredential.self, from: fixture)

        XCTAssertNoThrow(try credential.validated(configuration: .init()))
        let request = try await OpenAIRealtimeClient().makeRequest(credential: credential, configuration: .init())
        XCTAssertEqual(request.url?.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")
        XCTAssertEqual(credential.model, OpenAIRealtimeProviderConfiguration.defaultModel)
    }

    func testRealtimePCMAppendCommitAndCancelUseDocumentedSchema() throws {
        let pcm = Data([0, 0, 1, 0])
        let append = OpenAIRealtimePCM16.appendEvent(pcm)
        XCTAssertEqual(append["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(append["audio"] as? String)), pcm)
        XCTAssertEqual(OpenAIRealtimePCM16.commitEvent["type"] as? String, "input_audio_buffer.commit")
        XCTAssertEqual(OpenAIRealtimePCM16.cancelEvent["type"] as? String, "response.cancel")
        XCTAssertEqual(OpenAIRealtimePCM16.clearEvent["type"] as? String, "input_audio_buffer.clear")
        XCTAssertEqual(OpenAIRealtimePCM16.sampleRate, 24_000)
        XCTAssertEqual(OpenAIRealtimePCM16.channels, 1)
    }

    func testRealtimePCM16ConvertsLittleEndianSamplesForPlayback() throws {
        let pcm = Data([0x00, 0x80, 0x00, 0x00, 0xFF, 0x7F])
        let samples = try XCTUnwrap(OpenAIRealtimePCM16.float32Samples(pcm))
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0], -1, accuracy: 0.0001)
        XCTAssertEqual(samples[1], 0, accuracy: 0.0001)
        XCTAssertEqual(samples[2], 32767.0 / 32768.0, accuracy: 0.0001)
        XCTAssertNil(OpenAIRealtimePCM16.float32Samples(Data([0x00])))
    }

    func testRealtimeJSONOutboundEventsAreTextFrames() throws {
        let text = try OpenAIRealtimeOutboundEvent.text(["type": "response.create"])
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])["type"] as? String, "response.create")
    }

    func testRealtimeProviderBoundsKeepCloudInputsFinite() async throws {
        XCTAssertEqual(OpenAIRealtimeBounds.string(String(repeating: "x", count: 20), maximum: 8).count, 8)
        let client = OpenAIRealtimeClient(endpoint: URL(string: "wss://api.openai.com/v1/realtime")!)
        do {
            _ = try await client.respond(question: String(repeating: "x", count: OpenAIRealtimeBounds.ownerText + 1), context: .init(brief: try fixtureBrief()), credential: realtimeCredential(), configuration: .init(), executor: RejectingToolExecutor()) { _ in }
            XCTFail("oversized owner text must be rejected before opening a provider request")
        } catch let error as OpenAIRealtimeClientError {
            XCTAssertEqual(error, .inputTooLarge)
        }
    }

    func testRealtimeGAAudioSessionAndResponseFixturesUseNestedDescriptors() throws {
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(#"{"type":"session.update","session":{"type":"realtime","output_modalities":["audio"],"audio":{"input":{"format":{"type":"audio/pcm","rate":24000},"turn_detection":null},"output":{"format":{"type":"audio/pcm","rate":24000},"voice":"marin"}}}}"#.utf8)) as? [String: Any])
        let session = try XCTUnwrap(fixture["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertEqual(session["output_modalities"] as? [String], ["audio"])
        XCTAssertNil(session["modalities"])
        XCTAssertNil(session["input_audio_format"])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        XCTAssertEqual((try XCTUnwrap(input["format"] as? [String: Any]))["type"] as? String, "audio/pcm")
        XCTAssertEqual((try XCTUnwrap(input["format"] as? [String: Any]))["rate"] as? Int, 24_000)
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        XCTAssertEqual((try XCTUnwrap(output["format"] as? [String: Any]))["rate"] as? Int, 24_000)
        let response = ["type": "response.create", "response": ["output_modalities": ["audio"], "audio": ["output": ["format": ["type": "audio/pcm", "rate": 24_000], "voice": "marin"]]]] as [String : Any]
        XCTAssertEqual((response["response"] as? [String: Any])?["output_modalities"] as? [String], ["audio"])
        XCTAssertNotNil((((response["response"] as? [String: Any])?["audio"] as? [String: Any])?["output"] as? [String: Any])?["format"])
    }

    func testPTTPreconnectBufferKeepsShortPressOrderAndNeverCommitsEmpty() {
        var buffer = PulsePTTPreconnectBuffer(maximumBytes: 6)
        buffer.append(Data([1, 0])); buffer.append(Data([2, 0])); buffer.release()
        let flushed = buffer.takeForFlush()
        XCTAssertEqual(flushed.chunks, [Data([1, 0]), Data([2, 0])])
        XCTAssertTrue(flushed.shouldCommit)
        var capped = PulsePTTPreconnectBuffer(maximumBytes: 2)
        capped.append(Data([1, 0])); capped.append(Data([2, 0])); capped.release()
        XCTAssertEqual(capped.takeForFlush().chunks, [Data([1, 0])])
        var cancelled = PulsePTTPreconnectBuffer(); cancelled.append(Data([1, 0])); cancelled.cancel()
        XCTAssertFalse(cancelled.takeForFlush().shouldCommit)
    }

    func testRealtimeUsagePreservesUnknownAndAppliesBudget() throws {
        let pricing = PulseRealtimePricing(textInput: 5, cachedTextInput: 2.5, textOutput: 20, audioInput: 40, audioOutput: 80)
        let event = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(#"{"type":"response.done","response":{"usage":{"input_tokens":100,"output_tokens":20,"input_token_details":{"cached_tokens":10,"audio_tokens":30},"output_token_details":{"audio_tokens":40}}}}"#.utf8)) as? [String: Any])
        let entry = try XCTUnwrap(OpenAIRealtimeUsage.entry(from: event, model: "gpt-realtime-2.1-mini", startedAt: Date(), pricing: pricing))
        XCTAssertEqual(entry.audioInputTokens, 30)
        XCTAssertEqual(entry.audioOutputTokens, 40)
        XCTAssertNotNil(entry.estimatedCostUSD)
        XCTAssertNil(OpenAIRealtimeUsage.entry(from: ["type": "response.done"], model: "gpt-realtime-2.1-mini", startedAt: Date(), pricing: pricing))
        let budget = PulseRealtimeBudget(perSessionHardUSD: 1, perDayHardUSD: 2)
        XCTAssertTrue(budget.permitsNewCall(sessionTotal: 0.99, dayTotal: 1.99))
        XCTAssertFalse(budget.permitsNewCall(sessionTotal: 1, dayTotal: 0))
        XCTAssertFalse(budget.permitsNewCall(sessionTotal: 0, dayTotal: 2))
    }

    func testAudioPlaybackPlanActivatesBeforeEngineAndScheduling() {
        XCTAssertEqual(PulseAudioPlaybackPlan.steps(sessionIsActive: false, engineIsRunning: false), [.activateSession, .startEngine, .schedule])
        XCTAssertEqual(PulseAudioPlaybackPlan.steps(sessionIsActive: true, engineIsRunning: true), [.schedule])
        var drain = PulseAudioPlaybackDrain()
        drain.schedule(); drain.schedule(); drain.schedule()
        XCTAssertFalse(drain.isDrained)
        drain.finishBuffer(); drain.finishBuffer()
        XCTAssertFalse(drain.isDrained, "response.done must not stop playback before the last buffer")
        drain.finishBuffer()
        XCTAssertTrue(drain.isDrained)
    }

    func testRealtimeAudioTurnOnlyTreatsCompletedResponseDoneAsSuccess() {
        XCTAssertEqual(OpenAIRealtimeAudioTurnCompletion.responseDoneCompletion(["response": ["status": "completed"]]), .completed)
        XCTAssertEqual(OpenAIRealtimeAudioTurnCompletion.responseDoneCompletion(["response": ["status": "failed"]]), .providerFailed)
        XCTAssertEqual(OpenAIRealtimeAudioTurnCompletion.responseDoneCompletion(["response": ["status": "incomplete"]]), .providerFailed)
        XCTAssertEqual(OpenAIRealtimeAudioTurnCompletion.responseDoneCompletion([:]), .providerFailed)
    }

    func testPTTReducerStopsOnInterruptionAndForegroundLoss() {
        var state = PulsePTTState.idle
        state = PulsePTTReducer.reduce(state, event: .press)
        state = PulsePTTReducer.reduce(state, event: .permission(granted: true))
        XCTAssertEqual(state, .listening)
        XCTAssertEqual(PulsePTTReducer.reduce(state, event: .interruption), .interrupted)
        XCTAssertEqual(PulsePTTReducer.reduce(.interrupted, event: .foreground(active: true)), .idle)
        XCTAssertEqual(PulsePTTReducer.reduce(.listening, event: .foreground(active: false)), .interrupted)
    }

    func testVoiceCaptureGateRejectsLateCallbacksAfterInvalidation() {
        let interrupted = PulseVoiceCaptureToken(generation: 41)
        let next = PulseVoiceCaptureToken(generation: 42)
        var gate = PulseVoiceCaptureGate()

        gate.begin(interrupted)
        XCTAssertTrue(gate.accepts(interrupted))
        gate.invalidate(interrupted)
        XCTAssertFalse(gate.accepts(interrupted), "An interrupted Speech callback must be ignored")

        gate.begin(next)
        XCTAssertTrue(gate.accepts(next))
        XCTAssertFalse(gate.accepts(interrupted), "A prior generation cannot become a later capture")
    }

    private func fixturePulse() throws -> OpsPulse {
        try JSONDecoder.moaOps.decode(OpsPulse.self, from: Data(#"{"generated_at":"2026-07-12T12:00:00Z","summary":{"needs_attention":1,"in_progress":1,"stale_work":0,"on_track":0,"changes":0},"needs_attention":[{"id":"a","session":{"id":"s1","title":"Release","project":"/release"},"category":"permission_needed","priority":1,"lifecycle":"running","activity":"permission","freshness":"fresh","facts":[{"kind":"activity","value":"permission","provenance":"observed"}]}],"in_progress":[{"id":"b","session":{"id":"s2","title":"Build","project":"/build"},"category":"in_progress","lifecycle":"running","activity":"running","freshness":"fresh","facts":[{"kind":"activity","value":"running","provenance":"observed"}]}],"stale_work":[],"on_track":[],"changes":{"requested":false,"until":"2026-07-12T12:00:00Z","items":[],"next_cursor":"cursor","has_more":false}}"#.utf8))
    }

    private func fixtureBrief() throws -> PulseDeterministicBrief {
        PulseBriefBuilder.make(pulse: try fixturePulse())
    }

    private func realtimeCredential() -> PulseRealtimeClientCredential {
        try! JSONDecoder.moaOps.decode(PulseRealtimeClientCredential.self, from: Data(#"{"client_secret":"ek_test-secret","expires_at":1900000000,"transport":"websocket","endpoint":"wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini","model":"gpt-realtime-2.1-mini"}"#.utf8))
    }

    private func pendingReview() throws -> PulsePendingReview {
        let review = try JSONDecoder.moaOps.decode(PulseOperationReview.self, from: Data(#"{"target":{"id":"s1","title":"Release","project":"/release"},"text":"continúa","action":"steer","risk":"changes","consequence":"delivery is not completion"}"#.utf8))
        return .init(operationID: "AbCdEfGhIjKlMnOpQrStUvWx", kind: .directedInstruction, expiresAt: .distantFuture, review: review)
    }
}

private struct RejectingToolExecutor: PulseToolExecuting {
    func execute(_ toolUse: PulseToolUse) async -> PulseToolExecution { .init(toolUseID: toolUse.id, content: "unavailable", isError: true) }
}

private final class MemorySecureStore: PulseSecureStore, @unchecked Sendable {
    private var registration: PulseDeviceRegistration?
    func loadDeviceRegistration() throws -> PulseDeviceRegistration? { registration }
    func saveDeviceRegistration(_ registration: PulseDeviceRegistration) throws { self.registration = registration }
    func clearDeviceRegistration() throws { registration = nil }
}

private final class PulseRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func record(_ request: URLRequest) {
        var copy = request
        if copy.httpBody == nil, let stream = copy.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            copy.httpBody = data
        }
        lock.lock(); values.append(copy); lock.unlock()
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class LegacyDeletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pairs: [(String, String)] = []
    func record(_ service: String, _ account: String) { lock.lock(); pairs.append((service, account)); lock.unlock() }
    var values: [(String, String)] { lock.lock(); defer { lock.unlock() }; return pairs }
}

private final class PulseURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with _: URLRequest) -> Bool { true }
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
