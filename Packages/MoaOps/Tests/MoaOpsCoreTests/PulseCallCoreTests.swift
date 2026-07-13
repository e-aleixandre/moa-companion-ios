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
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(#"{"type":"session.update","session":{"type":"realtime","output_modalities":["text","audio"],"audio":{"input":{"format":{"type":"audio/pcm","rate":24000},"turn_detection":null},"output":{"format":{"type":"audio/pcm"},"voice":"marin"}}}}"#.utf8)) as? [String: Any])
        let session = try XCTUnwrap(fixture["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertNil(session["modalities"])
        XCTAssertNil(session["input_audio_format"])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        XCTAssertEqual((try XCTUnwrap(input["format"] as? [String: Any]))["type"] as? String, "audio/pcm")
        XCTAssertEqual((try XCTUnwrap(input["format"] as? [String: Any]))["rate"] as? Int, 24_000)
        let response = ["type": "response.create", "response": ["output_modalities": ["text", "audio"], "audio": ["output": ["format": ["type": "audio/pcm"], "voice": "marin"]]]] as [String : Any]
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
