@preconcurrency import Foundation

/// Persistent, non-secret accounting for Pulse's local Realtime protection.
/// Only dates, decimal amounts, and opaque turn UUIDs are stored here: never
/// API keys, audio, transcripts, Moa credentials, prompts, or tool payloads.
/// Unknown/post-send turns retain their full reservation until the following
/// local day, when it is conservatively settled at that amount against the day
/// on which it started. Thus a crash cannot turn an unknown provider charge
/// into free budget. `rotateSession` is explicit; it never discards active
/// reservations, which continue to constrain the new session.
public final class UserDefaultsPulseRealtimeBudgetStore: @unchecked Sendable {
    // A process-wide lock makes a read-modify-write transaction serial across
    // every ledger/store instance. UserDefaults' individual get/set calls do
    // not provide that guarantee themselves.
    private static let transactionLock = NSLock()
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "moa.pulse.realtime.budget-ledger.v1") {
        self.defaults = defaults
        self.key = key
    }

    fileprivate func withLockedData<T>(_ body: (Data?) -> (Data, T)) -> T {
        Self.transactionLock.lock()
        defer { Self.transactionLock.unlock() }
        let (updated, result) = body(defaults.data(forKey: key))
        defaults.set(updated, forKey: key)
        defaults.synchronize()
        return result
    }
}

public actor PulseRealtimeBudgetLedger {
    public struct Reservation: Codable, Equatable, Sendable {
        public let turnID: UUID
        public let amountUSD: Decimal
        public let day: String
        public let sessionID: UUID
        public let expiresAt: Date
        public var requestSent: Bool
    }

    private struct State: Codable {
        var sessionID: UUID
        var settledByDay: [String: Decimal]
        var settledBySession: [String: Decimal]
        var active: [UUID: Reservation]

        static func empty() -> State {
            State(sessionID: UUID(), settledByDay: [:], settledBySession: [:], active: [:])
        }
    }

    private let store: UserDefaultsPulseRealtimeBudgetStore
    private let calendar: Calendar

    public init(store: UserDefaultsPulseRealtimeBudgetStore = .init(), calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    /// Reserves before a socket is opened. A process-wide locked persisted
    /// transaction prevents separate ledger instances from oversubscribing a
    /// hard cap and makes the accepted reservation durable before returning.
    public func reserve(turnID: UUID = UUID(), amountUSD: Decimal, budget: PulseRealtimeBudget, now: Date = Date()) -> UUID? {
        guard amountUSD > 0 else { return nil }
        return withState { state in
            expireUnknownReservations(in: &state, now: now)
            let day = dayKey(now)
            let dayUsed = (state.settledByDay[day] ?? 0) + activeTotal(in: state, forDay: day)
            let sessionUsed = (state.settledBySession[state.sessionID.uuidString] ?? 0) + activeTotalForCurrentSession(in: state)
            guard dayUsed + amountUSD <= budget.perDayHardUSD,
                  sessionUsed + amountUSD <= budget.perSessionHardUSD else { return nil }
            state.active[turnID] = .init(turnID: turnID, amountUSD: amountUSD, day: day, sessionID: state.sessionID, expiresAt: nextDay(after: now), requestSent: false)
            return turnID
        }
    }

    /// Call immediately before the first WebSocket event that can reach OpenAI.
    public func markRequestSent(turnID: UUID) {
        withState { state in
            guard var reservation = state.active[turnID] else { return }
            reservation.requestSent = true
            state.active[turnID] = reservation
        }
    }

    /// A known `response.done` usage settles exactly this reservation once.
    /// The actual known amount is recorded (even if greater than the local
    /// reservation); removing the active amount releases only its remainder.
    public func settle(turnID: UUID, knownCostUSD: Decimal?) {
        withState { state in
            guard let reservation = state.active.removeValue(forKey: turnID) else { return }
            let cost = max(0, knownCostUSD ?? reservation.amountUSD)
            state.settledByDay[reservation.day, default: 0] += cost
            state.settledBySession[reservation.sessionID.uuidString, default: 0] += cost
        }
    }

    /// A cancelled turn with no sent request is provably free. Once anything
    /// was sent, retain the reservation for the next-day conservative policy.
    public func releaseIfPreSend(turnID: UUID) {
        withState { state in
            guard let reservation = state.active[turnID], !reservation.requestSent else { return }
            state.active.removeValue(forKey: turnID)
        }
    }

    public func rotateSession() {
        withState { state in
            state.sessionID = UUID()
        }
    }

    public func activeReservations(now: Date = Date()) -> [Reservation] {
        withState { state in
            expireUnknownReservations(in: &state, now: now)
            return Array(state.active.values)
        }
    }

    public func totals(now: Date = Date()) -> (session: Decimal, day: Decimal, active: Decimal) {
        withState { state in
            expireUnknownReservations(in: &state, now: now)
            let day = dayKey(now)
            return ((state.settledBySession[state.sessionID.uuidString] ?? 0) + activeTotalForCurrentSession(in: state), (state.settledByDay[day] ?? 0) + activeTotal(in: state, forDay: day), activeTotal(in: state, forDay: day))
        }
    }

    private func withState<T>(_ body: (inout State) -> T) -> T {
        store.withLockedData { data in
            var state: State
            if let data {
                guard let restored = try? JSONDecoder().decode(State.self, from: data) else {
                    fatalError("Realtime budget ledger is corrupted; refusing to reset its hard limits")
                }
                state = restored
            } else {
                state = .empty()
            }
            let result = body(&state)
            guard let encoded = try? JSONEncoder().encode(state) else { fatalError("Unable to encode realtime budget ledger") }
            return (encoded, result)
        }
    }

    private func expireUnknownReservations(in state: inout State, now: Date) {
        let expired = state.active.values.filter { $0.expiresAt <= now }
        for reservation in expired {
            state.active.removeValue(forKey: reservation.turnID)
            // Both sent-but-unknown and recovered unsent records are charged
            // conservatively rather than silently dropped after a restart.
            state.settledByDay[reservation.day, default: 0] += reservation.amountUSD
            state.settledBySession[reservation.sessionID.uuidString, default: 0] += reservation.amountUSD
        }
    }

    private func activeTotal(in state: State, forDay day: String) -> Decimal {
        state.active.values.filter { $0.day == day }.reduce(0) { $0 + $1.amountUSD }
    }

    private func activeTotalForCurrentSession(in state: State) -> Decimal {
        state.active.values.reduce(0) { $0 + $1.amountUSD }
    }

    private func dayKey(_ date: Date) -> String {
        var formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func nextDay(after date: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
    }
}
