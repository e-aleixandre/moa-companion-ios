import Foundation
import XCTest
@testable import MoaOpsCore

final class PulseAttentionModelsTests: XCTestCase {
    func testInitDecodesServerWireContract() throws {
        let message = try JSONDecoder.moaOps.decode(PulseAttentionServerMessage.self, from: Data(#"""
        {"type":"init","v":1,"items":[{"id":"att_1","priority":0,"kind":"permission","session_id":"s1","alias":"build","spoken":"Necesita permiso","state":"pending","created_at":"2026-07-16T10:00:00Z","ref_id":"perm_1","risk_level":"high","risk_flags":["shell"],"verbatim":"rm -rf tmp"}],"sessions":[{"session_id":"s1","alias":"build","title":"Build","state":"permission","pending_asks":0,"pending_perms":1,"brief_attempting":"actualizar la app","brief_progress":"tests preparados","brief_updated":"2026-07-16T10:00:30Z","activity":{"kind":"tool","detail":"phpstan analyse","tool":"bash"}}],"terminations":[{"id":"run_1","session_id":"s1","alias":"build","spoken":"Terminó","summary":"ok","created_at":"2026-07-16T10:01:00Z","ref":{"session_id":"s1","run_gen":4,"messages_url":"/api/sessions/s1/messages"}}]}
        """#.utf8))
        XCTAssertEqual(message.type, .initial)
        XCTAssertEqual(message.version, 1)
        XCTAssertEqual(message.items?.first?.priority, .p0)
        XCTAssertEqual(message.items?.first?.verbatim, "rm -rf tmp")
        XCTAssertEqual(message.sessions?.first?.pendingPerms, 1)
        XCTAssertEqual(message.sessions?.first?.attempting, "actualizar la app")
        XCTAssertEqual(message.sessions?.first?.progress, "tests preparados")
        XCTAssertEqual(message.sessions?.first?.updated, ISO8601DateFormatter.moaOps.date(from: "2026-07-16T10:00:30Z"))
        XCTAssertEqual(message.sessions?.first?.activity?.kind, "tool")
        XCTAssertEqual(message.sessions?.first?.activity?.detail, "phpstan analyse")
        XCTAssertEqual(message.sessions?.first?.activity?.tool, "bash")
        XCTAssertEqual(message.terminations?.first?.ref.runGen, 4)
    }

    func testOptionalAttentionFieldsDecodeWhenServerOmitsEmptyValues() throws {
        let message = try JSONDecoder.moaOps.decode(PulseAttentionServerMessage.self, from: Data(#"{"type":"attention","item":{"id":"att_2","priority":0,"kind":"error","session_id":"s2","alias":"test","spoken":"Falló","state":"pending","created_at":"2026-07-16T10:00:00Z"}}"#.utf8))
        XCTAssertNil(message.item?.refID)
        XCTAssertNil(message.item?.riskFlags)
    }

    func testClientAcknowledgementsUseExactTaggedUnion() throws {
        let ack = try JSONSerialization.jsonObject(with: JSONEncoder.moaOps.encode(PulseAttentionClientMessage.ackTermination(terminationID: "run_1"))) as? [String: String]
        XCTAssertEqual(ack?["type"], "ack_termination")
        XCTAssertEqual(ack?["termination_id"], "run_1")
    }
}
