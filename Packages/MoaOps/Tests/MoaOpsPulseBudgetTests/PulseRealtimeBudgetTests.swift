import Foundation
import XCTest
@testable import MoaOpsCore

final class PulseRealtimeBudgetTests: XCTestCase {
    func testZZDurableRealtimeBudgetReservationsAreAtomicAndRecoverAcrossRestart() async {
        let suite = "PulseRealtimeBudgetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPulseRealtimeBudgetStore(defaults: defaults, key: "ledger")
        let budget = PulseRealtimeBudget(perSessionHardUSD: 1, perDayHardUSD: 1)
        let firstLedger = PulseRealtimeBudgetLedger(store: store)
        let secondLedger = PulseRealtimeBudgetLedger(store: store)
        async let first = firstLedger.reserve(amountUSD: 0.6, budget: budget)
        async let second = secondLedger.reserve(amountUSD: 0.6, budget: budget)
        let (firstID, secondID) = await (first, second)
        let reservations = [firstID, secondID].compactMap { $0 }
        XCTAssertEqual(reservations.count, 1, "concurrent turns must not oversubscribe a hard cap")
        let recovered = PulseRealtimeBudgetLedger(store: store)
        let recoveredActive = await recovered.activeReservations()
        XCTAssertEqual(recoveredActive.count, 1, "restart keeps the persisted active reservation")
        let rejected = await recovered.reserve(amountUSD: 0.5, budget: budget)
        XCTAssertNil(rejected, "recovered reservation still constrains the cap")
    }

    func testRealtimeBudgetSettlesKnownOnceAndRetainsUnknownUntilNextDay() async {
        let suite = "PulseRealtimeBudgetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let ledger = PulseRealtimeBudgetLedger(store: .init(defaults: defaults, key: "ledger"), calendar: calendar)
        let budget = PulseRealtimeBudget(perSessionHardUSD: 2, perDayHardUSD: 2)
        let now = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 UTC
        let known = await ledger.reserve(amountUSD: 0.5, budget: budget, now: now)!
        await ledger.markRequestSent(turnID: known)
        await ledger.settle(turnID: known, knownCostUSD: 0.2)
        await ledger.settle(turnID: known, knownCostUSD: 0.2)
        let knownTotals = await ledger.totals(now: now)
        XCTAssertEqual(knownTotals.day, 0.2, "a duplicated done event cannot double count")
        let unknown = await ledger.reserve(amountUSD: 0.5, budget: budget, now: now)!
        await ledger.markRequestSent(turnID: unknown)
        let unknownActive = await ledger.activeReservations(now: now)
        XCTAssertEqual(unknownActive.count, 1)
        let tomorrow = now.addingTimeInterval(86_400)
        let expiredActive = await ledger.activeReservations(now: tomorrow)
        XCTAssertEqual(expiredActive.count, 0)
        // The unknown amount is settled on its original day, never zeroed.
        let expiredTotals = await ledger.totals(now: now)
        XCTAssertEqual(expiredTotals.day, 0.7)
    }

    func testRealtimeBudgetReleasesOnlyFailedPreSendAndSessionRotationIsExplicit() async {
        let suite = "PulseRealtimeBudgetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = PulseRealtimeBudgetLedger(store: .init(defaults: defaults, key: "ledger"))
        let budget = PulseRealtimeBudget(perSessionHardUSD: 1, perDayHardUSD: 2)
        let preSend = await ledger.reserve(amountUSD: 0.6, budget: budget)!
        await ledger.releaseIfPreSend(turnID: preSend)
        let releasedActive = await ledger.activeReservations()
        XCTAssertEqual(releasedActive.count, 0)
        let postSend = await ledger.reserve(amountUSD: 0.6, budget: budget)!
        await ledger.markRequestSent(turnID: postSend)
        await ledger.releaseIfPreSend(turnID: postSend)
        let retainedActive = await ledger.activeReservations()
        XCTAssertEqual(retainedActive.count, 1, "a post-send drop remains conservatively reserved")
        await ledger.rotateSession()
        let rotationRejected = await ledger.reserve(amountUSD: 0.6, budget: budget)
        XCTAssertNil(rotationRejected, "rotation never drops an active reservation")
    }

    func testRealtimeBudgetEnforcesDailyHardLimitIndependentlyOfSessionLimit() async {
        let suite = "PulseRealtimeBudgetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = PulseRealtimeBudgetLedger(store: .init(defaults: defaults, key: "ledger"))
        let budget = PulseRealtimeBudget(perSessionHardUSD: 5, perDayHardUSD: 1)
        let accepted = await ledger.reserve(amountUSD: 0.6, budget: budget)
        let rejected = await ledger.reserve(amountUSD: 0.5, budget: budget)
        XCTAssertNotNil(accepted)
        XCTAssertNil(rejected, "daily cap includes unsettled reservations")
    }
}
