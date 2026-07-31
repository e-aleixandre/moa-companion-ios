import Foundation
import XCTest
@testable import MoaOpsCore

final class PulseRealtimeCostTests: XCTestCase {
    // A realistic `response.done`: audio in and out, a small text prompt, and a
    // cached slice of the input that must be billed at the cached rate.
    private let responseDone = """
    {"type":"response.done","response":{"id":"resp_1","status":"completed","usage":{
      "total_tokens":3300,"input_tokens":3000,"output_tokens":300,
      "input_token_details":{"text_tokens":1000,"audio_tokens":2000,"cached_tokens":1200,
        "cached_tokens_details":{"text_tokens":800,"audio_tokens":400}},
      "output_token_details":{"text_tokens":100,"audio_tokens":200}}}}
    """

    func testUsageIsReadFromAResponseDoneFrame() throws {
        let usage = try XCTUnwrap(PulseRealtimeUsage(responseDone: json(responseDone)))
        XCTAssertEqual(usage.inputTextTokens, 1_000)
        XCTAssertEqual(usage.inputAudioTokens, 2_000)
        XCTAssertEqual(usage.cachedTextTokens, 800)
        XCTAssertEqual(usage.cachedAudioTokens, 400)
        XCTAssertEqual(usage.outputTextTokens, 100)
        XCTAssertEqual(usage.outputAudioTokens, 200)
    }

    func testAResponseWithoutUsageIsNotBilled() throws {
        XCTAssertNil(PulseRealtimeUsage(responseDone: json(#"{"type":"response.done","response":{"status":"cancelled"}}"#)))
    }

    // Only the totals are reported: the unattributed input is charged as audio,
    // the expensive bucket, so the estimate never silently under-reports.
    func testUsageWithoutDetailsChargesInputAsAudio() throws {
        let usage = try XCTUnwrap(PulseRealtimeUsage(responseDone: json(#"{"type":"response.done","response":{"usage":{"input_tokens":500,"output_tokens":0}}}"#)))
        XCTAssertEqual(usage.inputAudioTokens, 500)
        XCTAssertEqual(usage.inputTextTokens, 0)
    }

    func testCostUsesThePriceTableAndDiscountsCachedInput() throws {
        let usage = try XCTUnwrap(PulseRealtimeUsage(responseDone: json(responseDone)))
        // (2000-400) audio in @32 + 400 cached audio @0.40 + 200 audio out @64
        // + (1000-800) text in @4 + 800 cached text @0.40 + 100 text out @16.
        let audioUSD: Double = 1_600.0 * 32.0 + 400.0 * 0.40 + 200.0 * 64.0
        let textUSD: Double = 200.0 * 4.0 + 800.0 * 0.40 + 100.0 * 16.0
        let expected: Double = (audioUSD + textUSD) / 1_000_000.0
        XCTAssertEqual(PulseRealtimePricing.gptRealtime.costUSD(for: usage), expected, accuracy: 1e-9)
    }

    func testSessionsAndCostAccumulateAcrossResponses() throws {
        let defaults = try suite()
        let store = UserDefaultsPulseRealtimeCostStore(defaults: defaults, timeZone: utc)
        let now = date("2026-07-14T10:00:00Z")
        let usage = try XCTUnwrap(PulseRealtimeUsage(responseDone: json(responseDone)))
        store.beginSession(at: now)
        store.record(usage: usage, at: now)
        store.record(usage: usage, at: now)
        let snapshot = store.snapshot(at: now)
        let single = PulseRealtimePricing.gptRealtime.costUSD(for: usage)
        XCTAssertEqual(snapshot.today.sessions, 1)
        XCTAssertEqual(snapshot.today.costUSD, single * 2, accuracy: 1e-9)
        XCTAssertEqual(snapshot.month.costUSD, single * 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(snapshot.lastSessionUSD), single * 2, accuracy: 1e-9)
    }

    /// Two Realtime sessions in the same day: the day keeps both, "last session"
    /// keeps only the newer one. That difference is the whole point of the row.
    func testANewSessionResetsOnlyTheLastSessionBucket() throws {
        let defaults = try suite()
        let store = UserDefaultsPulseRealtimeCostStore(defaults: defaults, timeZone: utc)
        let usage = try XCTUnwrap(PulseRealtimeUsage(responseDone: json(responseDone)))
        let single = PulseRealtimePricing.gptRealtime.costUSD(for: usage)
        store.beginSession(at: date("2026-07-14T10:00:00Z"))
        store.record(usage: usage, at: date("2026-07-14T10:00:01Z"))
        store.beginSession(at: date("2026-07-14T18:00:00Z"))
        store.record(usage: usage, at: date("2026-07-14T18:00:01Z"))
        let snapshot = store.snapshot(at: date("2026-07-14T18:00:02Z"))
        XCTAssertEqual(snapshot.today.sessions, 2)
        XCTAssertEqual(snapshot.today.costUSD, single * 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(snapshot.lastSessionUSD), single, accuracy: 1e-9)
    }

    func testTotalsSurviveANewLedgerInstanceOverTheSameDefaults() throws {
        let defaults = try suite()
        let usage = try XCTUnwrap(PulseRealtimeUsage(responseDone: json(responseDone)))
        let now = date("2026-07-14T10:00:00Z")
        let first = UserDefaultsPulseRealtimeCostStore(defaults: defaults, timeZone: utc)
        first.beginSession(at: now)
        first.record(usage: usage, at: now)
        let restarted = UserDefaultsPulseRealtimeCostStore(defaults: defaults, timeZone: utc)
        let snapshot = restarted.snapshot(at: date("2026-07-14T11:00:00Z"))
        XCTAssertEqual(snapshot.today.sessions, 1)
        XCTAssertEqual(snapshot.today.costUSD, PulseRealtimePricing.gptRealtime.costUSD(for: usage), accuracy: 1e-9)
    }

    /// Nothing is scheduled: the day and month buckets are empty as soon as
    /// their key stops matching the date being asked about.
    func testDayAndMonthRollOverOnRead() throws {
        let defaults = try suite()
        let store = UserDefaultsPulseRealtimeCostStore(defaults: defaults, timeZone: utc)
        let usage = try XCTUnwrap(PulseRealtimeUsage(responseDone: json(responseDone)))
        store.beginSession(at: date("2026-07-31T23:00:00Z"))
        store.record(usage: usage, at: date("2026-07-31T23:00:01Z"))
        let nextDay = store.snapshot(at: date("2026-08-01T00:30:00Z"))
        XCTAssertTrue(nextDay.today.isEmpty)
        XCTAssertTrue(nextDay.month.isEmpty)
        // The last session survives a rollover on purpose: it is "the last time
        // you used voice", not a period.
        XCTAssertNotNil(nextDay.lastSessionUSD)
        // The rollover is persisted, so August starts from zero.
        store.beginSession(at: date("2026-08-01T09:00:00Z"))
        let august = store.snapshot(at: date("2026-08-01T09:00:01Z"))
        XCTAssertEqual(august.month.sessions, 1)
        XCTAssertEqual(august.month.costUSD, 0, accuracy: 1e-9)
    }

    func testTheProviderReportsUsageOfEveryFinishedResponse() async throws {
        let socket = FixtureCostSocket(events: [
            #"{"type":"response.created"}"#,
            responseDone,
            #"{"type":"response.done","response":{"status":"cancelled"}}"#,
        ])
        let recorder = UsageRecorder()
        let client = OpenAIRealtimeClient(socketFactory: FixtureCostSocketFactory(socket: socket))
        let call = try await client.beginCall(credential: credential(), executor: PulseGenericToolExecutor(service: CostRealtimeStub()), initialContext: "", onState: { _ in }, onText: { _ in }, onAudio: { _, _ in }, onBargeIn: {}, onUsage: { recorder.append($0) })
        await waitUntil { recorder.usages.count == 1 }
        // The cancelled response carries no usage and must not be billed.
        XCTAssertEqual(recorder.usages.first?.inputAudioTokens, 2_000)
        XCTAssertEqual(recorder.usages.count, 1)
        await call.end()
    }

    // MARK: - Helpers

    private let utc = TimeZone(identifier: "UTC")!

    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private func suite() throws -> UserDefaults {
        let name = "pulse.cost.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter.moaOps.date(from: text) ?? Date(timeIntervalSince1970: 0)
    }

    private func credential() throws -> PulseRealtimeClientCredential {
        try JSONDecoder.moaOps.decode(PulseRealtimeClientCredential.self, from: Data(#"{"client_secret":"ek_fixture","expires_at":1900000000,"transport":"websocket","endpoint":"wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1","model":"gpt-realtime-2.1"}"#.utf8))
    }

    private func waitUntil(_ condition: @Sendable () async -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// `onUsage` fires from the read-loop task, not from the test's context, so the
/// storage carries its own lock.
private final class UsageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PulseRealtimeUsage] = []
    func append(_ usage: PulseRealtimeUsage) { lock.lock(); stored.append(usage); lock.unlock() }
    var usages: [PulseRealtimeUsage] { lock.lock(); defer { lock.unlock() }; return stored }
}

private actor FixtureCostSocket: PulseRealtimeSocket {
    private var events: [String]
    init(events: [String]) { self.events = events }
    func resume() {}
    func send(text _: String) throws {}
    func receive() async throws -> String {
        guard !events.isEmpty else { throw OpenAIRealtimeClientError.transport }
        return events.removeFirst()
    }
    func cancel() {}
}

private struct FixtureCostSocketFactory: PulseRealtimeSocketFactory {
    let socket: FixtureCostSocket
    func makeSocket(request _: URLRequest) async -> any PulseRealtimeSocket { socket }
}

private actor CostRealtimeStub: PulseGenericToolService {
    func listSessions() async throws -> [MoaServeSessionInfo] { [] }
    func attention() async throws -> MoaServeAttentionResponse { try JSONDecoder.moaOps.decode(MoaServeAttentionResponse.self, from: Data(#"{"items":[]}"#.utf8)) }
    func readSession(sessionID _: String, limit _: Int, cursor _: String?) async throws -> MoaServeConversationPage { throw PulseCallError.operationUnavailable }
    func readToolDetail(sessionID _: String, itemID _: String) async throws -> MoaServeToolDetail { throw PulseCallError.operationUnavailable }
    func listSubagents(sessionID _: String) async throws -> MoaServeSubagentListResponse { throw PulseCallError.operationUnavailable }
    func readSubagent(sessionID _: String, jobID _: String, limit _: Int, cursor _: String?) async throws -> MoaServeSubagentPage { throw PulseCallError.operationUnavailable }
    func sendMessage(sessionID _: String, text _: String) async throws -> MoaServeSendMessageResponse { throw PulseCallError.operationUnavailable }
    func respondAsk(sessionID _: String, askID _: String, answers _: [String]) async throws {}
    func decidePermission(sessionID _: String, permissionID _: String, approved _: Bool, feedback _: String?) async throws {}
    func createSession(title _: String?, cwd _: String?, model _: String?) async throws -> MoaServeSessionInfo { throw PulseCallError.operationUnavailable }
    func resumeSession(sessionID _: String) async throws -> MoaServeSessionInfo { throw PulseCallError.operationUnavailable }
    func cancelRun(sessionID _: String) async throws {}
    func archiveSession(sessionID _: String) async throws -> MoaServeArchiveSessionResponse { throw PulseCallError.operationUnavailable }
}
