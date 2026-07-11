import Foundation
import XCTest
@testable import MoaOpsPresentation
@testable import MoaOpsCore

@MainActor
final class CompanionAppModelTests: XCTestCase {
    func testConversationPaginationAndExpiredCursorReloadFromFirstPage() async throws {
        let session = CompanionSession(id: "s1", title: "Entrega", state: "idle", updated: .now)
        let first = page(sessionID: "s1", ids: ["m1"], cursor: "old")
        let reset = page(sessionID: "s1", ids: ["new"], cursor: nil)
        let service = CompanionServiceStub(sessions: [session], pages: [.success(first), .failure(.conversationResetRequired), .success(reset)])
        let model = MoaCompanionAppModel(serverURLText: "https://ops.example", serviceFactory: { _, _ in service })

        await model.connect()
        await model.openConversation(session)
        await model.loadMoreConversation()

        XCTAssertEqual(service.requestedCursors, [nil, "old", nil])
        XCTAssertEqual(model.conversationMessages.map(\.id), ["new"])
        XCTAssertTrue(model.conversationWasReset)
    }

    func testSuggestedActionRequiresExactBindingAndKeepsIdempotentInstructionOnRetry() async throws {
        let session = CompanionSession(id: "exact", title: "Entrega", state: "running", updated: .now)
        let service = CompanionServiceStub(sessions: [session], pages: [])
        service.instructionResults = [.failure(.transport), .success(.init(action: .steer, target: .init(id: "exact", title: "Entrega", project: nil)))]
        let model = MoaCompanionAppModel(serverURLText: "https://ops.example", serviceFactory: { _, _ in service })
        await model.connect()
        let item = try JSONDecoder.moaOps.decode(ConversationBriefingItem.self, from: Data("""
        {"text":"Pide una actualización","source_ids":["conversation:exact:m1"],"provenance":"user_provided","suggested_action":{"kind":"directed_instruction","target_id":"exact"}}
        """.utf8))

        model.beginSuggestedAction(item)
        model.actionText = "Confirma el estado actual"
        await model.submitSuggestedAction()
        await model.submitSuggestedAction()

        XCTAssertEqual(service.instructions.map(\.target), ["exact", "exact"])
        XCTAssertEqual(service.instructions[0], service.instructions[1])
        XCTAssertEqual(model.actionReceipt?.message, "Entregada a Entrega — dirigida")
    }

    private func page(sessionID: String, ids: [String], cursor: String?) -> ConversationPage {
        ConversationPage(sessionID: sessionID, title: "Entrega", branch: .init(leafID: "leaf", source: "saved"), messages: ids.map { .init(id: $0, role: "assistant", text: $0) }, nextCursor: cursor, hasMore: cursor != nil)
    }
}

private final class CompanionServiceStub: MoaCompanionPresentationService, @unchecked Sendable {
    let sessionsValue: [CompanionSession]
    var pages: [Result<ConversationPage, MoaOpsClientError>]
    private(set) var requestedCursors: [String?] = []
    private(set) var instructions: [OpsInstructionRequest] = []
    var instructionResults: [Result<OpsInstructionResponse, MoaOpsClientError>] = []

    init(sessions: [CompanionSession], pages: [Result<ConversationPage, MoaOpsClientError>]) {
        sessionsValue = sessions
        self.pages = pages
    }

    func loadSessions() async throws -> [CompanionSession] { sessionsValue }
    func loadConversation(sessionID: String, limit: Int, cursor: String?) async throws -> ConversationPage {
        requestedCursors.append(cursor)
        return try pages.removeFirst().get()
    }
    func sendConversation(sessionID: String, text: String) async throws -> ConversationSendResponse { .init(action: .send) }
    func loadBriefing(sessionIDs: [String]) async throws -> ConversationBriefing { throw MoaOpsClientError.transport }
    func submitInstruction(_ instruction: OpsInstructionRequest) async throws -> OpsInstructionResponse {
        instructions.append(instruction)
        return try instructionResults.removeFirst().get()
    }
    func loadPulse(cursor: String?) async throws -> OpsPulse { throw MoaOpsClientError.transport }
    func startConversationUpdates(sessionID: String) async {}
    func stopConversationUpdates() async {}
    func conversationUpdates() async -> AsyncStream<ConversationLiveEvent> { AsyncStream { $0.finish() } }
    func invalidate() async {}
}
