import Foundation
import XCTest
@testable import MoaOpsPresentation
@testable import MoaOpsCore

final class CompanionPresentationTests: XCTestCase {
    func testSelectionDefaultsToActiveThenRecentAndIsBoundedByExactIDs() {
        let now = Date()
        let sessions = [
            CompanionSession(id: "saved", title: "Guardada", state: "idle", updated: now),
            CompanionSession(id: "live", title: "Activa", state: "running", updated: now.addingTimeInterval(-100)),
            CompanionSession(id: "third", title: "Tercera", state: "idle", updated: now.addingTimeInterval(-200)),
            CompanionSession(id: "fourth", title: "Cuarta", state: "idle", updated: now.addingTimeInterval(-300)),
        ]
        XCTAssertEqual(CompanionMapper.defaultSelection(in: sessions), ["live", "saved", "third"])
        XCTAssertEqual(CompanionMapper.toggling(sessionID: "fourth", selected: ["live", "saved", "third"]), ["live", "saved", "third"])
        XCTAssertEqual(CompanionMapper.toggling(sessionID: "saved", selected: ["live", "saved"]), ["live"])
    }

    func testOnlyVerifiedOpsFactsCanCarryVerifiedPresentation() throws {
        let briefing = try JSONDecoder.moaOps.decode(ConversationBriefing.self, from: Data("""
        {"kind":"ops","generated_at":"2026-07-11T18:00:00Z","mode":"model","verified_ops":[{"source_id":"ops:s1","text":"verified","provenance":"verified_ops"}],"items":[{"text":"prose","source_ids":["conversation:s1:m1"],"provenance":"agent_reported"}]}
        """.utf8))
        XCTAssertTrue(CompanionMapper.isVerified(briefing.verifiedOps[0]))
        XCTAssertEqual(CompanionMapper.provenanceLabel(briefing.items[0].provenance), "Resumen de conversación · informado por Moa")
        XCTAssertFalse(CompanionMapper.provenanceLabel(briefing.items[0].provenance).contains("Moa verificó"))
    }

    func testSuggestedActionBindsOnlyExactServerTargetWithoutFuzzyTitleMatching() throws {
        let item = try JSONDecoder.moaOps.decode(ConversationBriefingItem.self, from: Data("""
        {"text":"Propón una instrucción","source_ids":["conversation:exact:m1"],"provenance":"user_provided","suggested_action":{"kind":"directed_instruction","target_id":"exact"}}
        """.utf8))
        let sessions = [CompanionSession(id: "exact", title: "Entrega", state: "running", updated: .now)]
        XCTAssertEqual(CompanionMapper.actionProposal(item: item, sessions: sessions)?.target.id, "exact")
        XCTAssertNil(CompanionMapper.actionProposal(item: item, sessions: [CompanionSession(id: "other", title: "Entrega", state: "running", updated: .now)]))
    }
}
