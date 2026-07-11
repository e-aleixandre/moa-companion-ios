import Foundation
import XCTest
@testable import MoaOpsPresentation
@testable import MoaOpsCore

@MainActor
final class CompanionAppModelTests: XCTestCase {
    func testNewestFirstPagesRenderChronologicallyAndOlderPagePrepends() async throws {
        let session = activeSession()
        let recent = page(sessionID: "s1", newestFirst: ["m4", "m3", "m2"], cursor: "rest-old")
        let older = page(sessionID: "s1", newestFirst: ["m1"], cursor: nil)
        let service = CompanionServiceStub(sessions: [session], pages: [.success(recent), .success(older)])
        let model = model(service)

        await model.connect()
        await model.openConversation(session)
        await model.loadMoreConversation()

        XCTAssertEqual(service.requestedCursors, [nil, "rest-old"])
        XCTAssertEqual(model.conversationMessages.map(\.id), ["m1", "m2", "m3", "m4"])
    }

    func testInitTailOverlapDeduplicatesUsesAuthoritativeOlderCursorAndReconnectAppendsSafely() async throws {
        let session = activeSession()
        let recent = page(sessionID: "s1", newestFirst: ["m4", "m3", "m2"], cursor: "rest-old")
        let older = page(sessionID: "s1", newestFirst: ["m1"], cursor: nil)
        let firstInit = ConversationLiveEvent.initial(.init(sessionID: "s1", title: "Entrega", branch: .init(leafID: "leaf", source: "active"), state: "running", tail: messages(["m2", "m3", "m4", "m5"]), olderCursor: "init-old", hasOlder: true))
        let reconnectInit = ConversationLiveEvent.initial(.init(sessionID: "s1", title: "Entrega", branch: .init(leafID: "leaf", source: "active"), state: "idle", tail: messages(["m3", "m4", "m5", "m6"]), olderCursor: "reconnect-old", hasOlder: true))
        let service = CompanionServiceStub(sessions: [session], pages: [.success(recent), .success(older)], liveEvents: [firstInit, reconnectInit])
        let model = model(service)

        await model.connect()
        await model.openConversation(session)
        await waitForLiveEvents()
        await model.loadMoreConversation()

        XCTAssertEqual(service.requestedCursors, [nil, "reconnect-old"])
        XCTAssertEqual(model.conversationMessages.map(\.id), ["m1", "m2", "m3", "m4", "m5", "m6"])
        XCTAssertFalse(model.conversationWasReset)
        XCTAssertEqual(model.liveState, "idle")
    }

    func testInvalidOlderCursorReloadsSafelyWithoutCombiningPages() async throws {
        let session = activeSession()
        let recent = page(sessionID: "s1", newestFirst: ["m3", "m2"], cursor: "expired")
        let reset = page(sessionID: "s1", newestFirst: ["fresh"], cursor: nil)
        let service = CompanionServiceStub(sessions: [session], pages: [.success(recent), .failure(.conversationResetRequired), .success(reset)])
        let model = model(service)

        await model.connect()
        await model.openConversation(session)
        await model.loadMoreConversation()

        XCTAssertEqual(service.requestedCursors, [nil, "expired", nil])
        XCTAssertEqual(model.conversationMessages.map(\.id), ["fresh"])
        XCTAssertTrue(model.conversationWasReset)
    }

    func testNonOverlappingReconnectTailResetsRatherThanClaimingOrder() async throws {
        let session = activeSession()
        let recent = page(sessionID: "s1", newestFirst: ["m3", "m2"], cursor: "old")
        let init = ConversationLiveEvent.initial(.init(sessionID: "s1", title: "Entrega", branch: .init(leafID: "leaf", source: "active"), state: "idle", tail: messages(["new1", "new2"]), olderCursor: "tail-old", hasOlder: true))
        let service = CompanionServiceStub(sessions: [session], pages: [.success(recent)], liveEvents: [init])
        let model = model(service)

        await model.connect()
        await model.openConversation(session)
        await waitForLiveEvents()

        XCTAssertEqual(model.conversationMessages.map(\.id), ["new1", "new2"])
        XCTAssertTrue(model.conversationWasReset)
    }

    func testActiveIdleAndErrorSessionsRemainWritableOnlySavedIsReadOnly() {
        XCTAssertTrue(CompanionSession(id: "idle", title: "", state: "idle", updated: .now).isLive)
        XCTAssertTrue(CompanionSession(id: "error", title: "", state: "error", updated: .now).isLive)
        XCTAssertFalse(CompanionSession(id: "saved", title: "", state: "saved", updated: .now).isLive)
        XCTAssertEqual(CompanionSession(id: "permission", title: "", state: "permission", updated: .now).spanishState, "Espera permiso")
    }

    func testAmbiguousChatSendDoesNotLeaveRetryTextOrClaimDelivery() async throws {
        let session = activeSession()
        let service = CompanionServiceStub(sessions: [session], pages: [.success(page(sessionID: "s1", newestFirst: [], cursor: nil))])
        service.sendResults = [.failure(.transport)]
        let model = model(service)
        await model.connect()
        await model.openConversation(session)
        model.chatText = "continúa"

        await model.sendChat()

        XCTAssertEqual(service.sentChats.map { "\($0.0):\($0.1)" }, ["s1:continúa"])
        XCTAssertEqual(model.chatText, "")
        XCTAssertTrue(model.chatDeliveryUnconfirmed)
        XCTAssertNil(model.chatReceipt)
        XCTAssertEqual(model.userMessage, "No se confirmó la entrega. Comprueba la conversación antes de enviar de nuevo.")
    }

    func testSuggestedActionUses1024UnicodeScalarLimitAndKeepsIdempotentRetry() async throws {
        let session = activeSession(id: "exact")
        let service = CompanionServiceStub(sessions: [session], pages: [])
        service.instructionResults = [.failure(.transport), .success(.init(action: .steer, target: .init(id: "exact", title: "Entrega", project: nil)))]
        let model = model(service)
        await model.connect()
        let item = try JSONDecoder.moaOps.decode(ConversationBriefingItem.self, from: Data("""
        {"text":"Pide una actualización","source_ids":["conversation:exact:m1"],"provenance":"user_provided","suggested_action":{"kind":"directed_instruction","target_id":"exact"}}
        """.utf8))
        model.beginSuggestedAction(item)
        model.actionText = String(repeating: "😀", count: 1_025)
        await model.submitSuggestedAction()
        XCTAssertTrue(service.instructions.isEmpty)

        model.actionText = "Confirma el estado actual"
        await model.submitSuggestedAction()
        await model.submitSuggestedAction()
        XCTAssertEqual(service.instructions.map(\.target), ["exact", "exact"])
        XCTAssertEqual(service.instructions[0], service.instructions[1])
    }

    private func model(_ service: CompanionServiceStub) -> MoaCompanionAppModel {
        MoaCompanionAppModel(serverURLText: "https://ops.example", serviceFactory: { _, _ in service })
    }

    private func activeSession(id: String = "s1") -> CompanionSession {
        CompanionSession(id: id, title: "Entrega", state: "idle", updated: .now)
    }

    private func messages(_ ids: [String]) -> [ConversationMessage] {
        ids.map { .init(id: $0, role: "assistant", text: $0) }
    }

    private func page(sessionID: String, newestFirst ids: [String], cursor: String?) -> ConversationPage {
        ConversationPage(sessionID: sessionID, title: "Entrega", branch: .init(leafID: "leaf", source: "active"), order: "newest_first", messages: messages(ids), nextCursor: cursor, hasMore: cursor != nil)
    }

    private func waitForLiveEvents() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

private final class CompanionServiceStub: MoaCompanionPresentationService, @unchecked Sendable {
    let sessionsValue: [CompanionSession]
    var pages: [Result<ConversationPage, MoaOpsClientError>]
    let liveEvents: [ConversationLiveEvent]
    private(set) var requestedCursors: [String?] = []
    private(set) var instructions: [OpsInstructionRequest] = []
    private(set) var sentChats: [(String, String)] = []
    var instructionResults: [Result<OpsInstructionResponse, MoaOpsClientError>] = []
    var sendResults: [Result<ConversationSendResponse, MoaOpsClientError>] = []

    init(sessions: [CompanionSession], pages: [Result<ConversationPage, MoaOpsClientError>], liveEvents: [ConversationLiveEvent] = []) {
        sessionsValue = sessions
        self.pages = pages
        self.liveEvents = liveEvents
    }

    func loadSessions() async throws -> [CompanionSession] { sessionsValue }
    func loadConversation(sessionID: String, limit: Int, cursor: String?) async throws -> ConversationPage {
        requestedCursors.append(cursor)
        return try pages.removeFirst().get()
    }
    func sendConversation(sessionID: String, text: String) async throws -> ConversationSendResponse {
        sentChats.append((sessionID, text))
        if !sendResults.isEmpty { return try sendResults.removeFirst().get() }
        return .init(action: .send)
    }
    func loadBriefing(sessionIDs: [String]) async throws -> ConversationBriefing { throw MoaOpsClientError.transport }
    func submitInstruction(_ instruction: OpsInstructionRequest) async throws -> OpsInstructionResponse {
        instructions.append(instruction)
        return try instructionResults.removeFirst().get()
    }
    func loadPulse(cursor: String?) async throws -> OpsPulse { throw MoaOpsClientError.transport }
    func startConversationUpdates(sessionID: String) async {}
    func stopConversationUpdates() async {}
    func conversationUpdates() async -> AsyncStream<ConversationLiveEvent> {
        AsyncStream { continuation in
            for event in liveEvents { continuation.yield(event) }
            continuation.finish()
        }
    }
    func invalidate() async {}
}
