import Foundation

/// Token usage of one Realtime response, as reported by OpenAI in
/// `response.done`. Cached tokens are a *subset* of the input tokens, not an
/// extra bucket: the billable uncached input is `input - cached`.
public struct PulseRealtimeUsage: Equatable, Sendable {
    public var inputTextTokens: Int
    public var inputAudioTokens: Int
    public var cachedTextTokens: Int
    public var cachedAudioTokens: Int
    public var outputTextTokens: Int
    public var outputAudioTokens: Int

    public init(inputTextTokens: Int = 0, inputAudioTokens: Int = 0, cachedTextTokens: Int = 0, cachedAudioTokens: Int = 0, outputTextTokens: Int = 0, outputAudioTokens: Int = 0) {
        self.inputTextTokens = inputTextTokens
        self.inputAudioTokens = inputAudioTokens
        self.cachedTextTokens = cachedTextTokens
        self.cachedAudioTokens = cachedAudioTokens
        self.outputTextTokens = outputTextTokens
        self.outputAudioTokens = outputAudioTokens
    }

    public var isEmpty: Bool {
        inputTextTokens == 0 && inputAudioTokens == 0 && outputTextTokens == 0 && outputAudioTokens == 0
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        .init(
            inputTextTokens: lhs.inputTextTokens + rhs.inputTextTokens,
            inputAudioTokens: lhs.inputAudioTokens + rhs.inputAudioTokens,
            cachedTextTokens: lhs.cachedTextTokens + rhs.cachedTextTokens,
            cachedAudioTokens: lhs.cachedAudioTokens + rhs.cachedAudioTokens,
            outputTextTokens: lhs.outputTextTokens + rhs.outputTextTokens,
            outputAudioTokens: lhs.outputAudioTokens + rhs.outputAudioTokens
        )
    }

    /// Reads the `usage` object of a `response.done` frame. Returns nil when the
    /// frame carries no usage at all (an interrupted or failed response), so the
    /// ledger can tell "nothing to bill" from "zero tokens".
    public init?(responseDone event: [String: Any]) {
        guard let usage = (event["response"] as? [String: Any])?["usage"] as? [String: Any] ?? event["usage"] as? [String: Any] else { return nil }
        let inputDetails = usage["input_token_details"] as? [String: Any] ?? [:]
        let outputDetails = usage["output_token_details"] as? [String: Any] ?? [:]
        let inputTotal = Self.int(usage["input_tokens"])
        let inputText = Self.int(inputDetails["text_tokens"])
        var inputAudio = Self.int(inputDetails["audio_tokens"])
        // Some responses report only the totals. Everything unaccounted for is
        // charged as audio: it is the expensive bucket, so an estimate that is
        // wrong errs upwards instead of quietly under-reporting the bill.
        if inputDetails.isEmpty || (inputText == 0 && inputAudio == 0) {
            inputAudio = max(0, inputTotal)
        }
        let cachedDetails = inputDetails["cached_tokens_details"] as? [String: Any]
        let cachedTotal = Self.int(inputDetails["cached_tokens"])
        var cachedText = Self.int(cachedDetails?["text_tokens"])
        var cachedAudio = Self.int(cachedDetails?["audio_tokens"])
        if cachedDetails == nil, cachedTotal > 0 {
            // Without the breakdown, discount text first: text is the cheaper
            // bucket, so this is the split that credits the least back and keeps
            // the estimate on the safe side.
            cachedText = min(cachedTotal, inputText)
            cachedAudio = min(max(0, cachedTotal - cachedText), inputAudio)
        }
        let outputText = Self.int(outputDetails["text_tokens"])
        var outputAudio = Self.int(outputDetails["audio_tokens"])
        if outputDetails.isEmpty || (outputText == 0 && outputAudio == 0) {
            outputAudio = Self.int(usage["output_tokens"])
        }
        self.init(
            inputTextTokens: inputText,
            inputAudioTokens: inputAudio,
            cachedTextTokens: min(cachedText, inputText),
            cachedAudioTokens: min(cachedAudio, inputAudio),
            outputTextTokens: outputText,
            outputAudioTokens: outputAudio
        )
    }

    private static func int(_ value: Any?) -> Int {
        if let int = value as? Int { return max(0, int) }
        if let double = value as? Double { return max(0, Int(double)) }
        if let number = value as? NSNumber { return max(0, number.intValue) }
        return 0
    }
}

/// Local price table for the Realtime model Pulse talks to, in USD per million
/// tokens.
///
/// These are a LOCAL ESTIMATE, not a bill: OpenAI's published `gpt-realtime`
/// prices as of mid-2026. They are here, in one struct, precisely so they are
/// trivial to update when the published prices move.
public struct PulseRealtimePricing: Equatable, Sendable {
    public var audioInputPerMillion: Double
    public var audioCachedInputPerMillion: Double
    public var audioOutputPerMillion: Double
    public var textInputPerMillion: Double
    public var textCachedInputPerMillion: Double
    public var textOutputPerMillion: Double

    public init(audioInputPerMillion: Double = 32, audioCachedInputPerMillion: Double = 0.40, audioOutputPerMillion: Double = 64, textInputPerMillion: Double = 4, textCachedInputPerMillion: Double = 0.40, textOutputPerMillion: Double = 16) {
        self.audioInputPerMillion = audioInputPerMillion
        self.audioCachedInputPerMillion = audioCachedInputPerMillion
        self.audioOutputPerMillion = audioOutputPerMillion
        self.textInputPerMillion = textInputPerMillion
        self.textCachedInputPerMillion = textCachedInputPerMillion
        self.textOutputPerMillion = textOutputPerMillion
    }

    /// gpt-realtime, as of mid-2026. Update as needed.
    public static let gptRealtime = PulseRealtimePricing()

    public func costUSD(for usage: PulseRealtimeUsage) -> Double {
        let uncachedAudioInput = max(0, usage.inputAudioTokens - usage.cachedAudioTokens)
        let uncachedTextInput = max(0, usage.inputTextTokens - usage.cachedTextTokens)
        let perToken = 1_000_000.0
        return (Double(uncachedAudioInput) * audioInputPerMillion
            + Double(usage.cachedAudioTokens) * audioCachedInputPerMillion
            + Double(usage.outputAudioTokens) * audioOutputPerMillion
            + Double(uncachedTextInput) * textInputPerMillion
            + Double(usage.cachedTextTokens) * textCachedInputPerMillion
            + Double(usage.outputTextTokens) * textOutputPerMillion) / perToken
    }
}

/// What the owner sees: what voice has cost today, this month, and in the last
/// Realtime session. Amounts are USD, always an estimate.
public struct PulseRealtimeCostSnapshot: Equatable, Sendable {
    public struct Bucket: Equatable, Sendable {
        public var costUSD: Double
        public var sessions: Int
        public init(costUSD: Double = 0, sessions: Int = 0) { self.costUSD = costUSD; self.sessions = sessions }
        public var isEmpty: Bool { sessions == 0 && costUSD == 0 }
    }

    public var today: Bucket
    public var month: Bucket
    /// Cost of the most recent Realtime session, whether it is still open or
    /// already closed. Nil until the first session of this device.
    public var lastSessionUSD: Double?
    public var lastSessionAt: Date?

    public init(today: Bucket = .init(), month: Bucket = .init(), lastSessionUSD: Double? = nil, lastSessionAt: Date? = nil) {
        self.today = today
        self.month = month
        self.lastSessionUSD = lastSessionUSD
        self.lastSessionAt = lastSessionAt
    }

    public var isEmpty: Bool { today.isEmpty && month.isEmpty && lastSessionUSD == nil }
}

/// Accumulates what the Realtime sessions cost. Both session owners — the
/// Guardián coordinator and the direct-call model — write into the same ledger,
/// so the totals are the device's, not one mode's.
///
/// Deliberately not the Keychain and not a server call: this is non-secret,
/// disposable bookkeeping whose worst failure is a forgotten total.
public protocol PulseRealtimeCostStore: Sendable {
    /// One Realtime socket was opened. Sessions are counted here, not on usage,
    /// so a session that produced no response is still visible.
    func beginSession(at date: Date)
    func record(usage: PulseRealtimeUsage, at date: Date)
    func snapshot(at date: Date) -> PulseRealtimeCostSnapshot
}

public extension PulseRealtimeCostStore {
    func beginSession() { beginSession(at: Date()) }
    func record(usage: PulseRealtimeUsage) { record(usage: usage, at: Date()) }
    func snapshot() -> PulseRealtimeCostSnapshot { snapshot(at: Date()) }
}

/// Day/month bucket keys. The month key ("2026-07") is the whole monthly reset
/// mechanism: a new month simply stops matching, so nothing has to be scheduled
/// or cleaned up.
public enum PulseRealtimeCostPeriod {
    public static func dayKey(_ date: Date, timeZone: TimeZone = .current) -> String { formatted(date, timeZone: timeZone, format: "yyyy-MM-dd") }
    public static func monthKey(_ date: Date, timeZone: TimeZone = .current) -> String { formatted(date, timeZone: timeZone, format: "yyyy-MM") }

    private static func formatted(_ date: Date, timeZone: TimeZone, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

public final class UserDefaultsPulseRealtimeCostStore: PulseRealtimeCostStore, @unchecked Sendable {
    /// Versioned: a future change of the stored shape starts from zero instead
    /// of decoding garbage into the owner's totals.
    private let key = "pulse.realtime.cost.v1"
    private let defaults: UserDefaults
    private let pricing: PulseRealtimePricing
    private let timeZone: TimeZone
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, pricing: PulseRealtimePricing = .gptRealtime, timeZone: TimeZone = .current) {
        self.defaults = defaults
        self.pricing = pricing
        self.timeZone = timeZone
    }

    private struct State: Codable {
        var dayKey = ""
        var dayCostUSD = 0.0
        var daySessions = 0
        var monthKey = ""
        var monthCostUSD = 0.0
        var monthSessions = 0
        var lastSessionCostUSD: Double?
        // Seconds since 1970 rather than `Date`: the shared moaOps coders speak
        // RFC 3339 for the server wire format, and this local blob has no
        // business depending on that contract.
        var lastSessionAt: TimeInterval?
    }

    public func beginSession(at date: Date) {
        mutate(at: date) { state in
            state.daySessions += 1
            state.monthSessions += 1
            state.lastSessionCostUSD = 0
            state.lastSessionAt = date.timeIntervalSince1970
        }
    }

    public func record(usage: PulseRealtimeUsage, at date: Date) {
        guard !usage.isEmpty else { return }
        let cost = pricing.costUSD(for: usage)
        mutate(at: date) { state in
            state.dayCostUSD += cost
            state.monthCostUSD += cost
            // Usage arriving before any `beginSession` (a socket this build did
            // not open, or a store created mid-session) still belongs to a
            // session the owner had: start one rather than dropping the cost.
            state.lastSessionCostUSD = (state.lastSessionCostUSD ?? 0) + cost
            if state.lastSessionAt == nil { state.lastSessionAt = date.timeIntervalSince1970 }
        }
    }

    public func snapshot(at date: Date) -> PulseRealtimeCostSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let state = rolledOver(load(), at: date)
        return .init(
            today: .init(costUSD: state.dayCostUSD, sessions: state.daySessions),
            month: .init(costUSD: state.monthCostUSD, sessions: state.monthSessions),
            lastSessionUSD: state.lastSessionCostUSD,
            lastSessionAt: state.lastSessionAt.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func mutate(at date: Date, _ body: (inout State) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var state = rolledOver(load(), at: date)
        body(&state)
        save(state)
    }

    /// Reading is enough to roll over: the buckets whose key no longer matches
    /// the current date are simply empty again.
    private func rolledOver(_ state: State, at date: Date) -> State {
        var state = state
        let day = PulseRealtimeCostPeriod.dayKey(date, timeZone: timeZone)
        let month = PulseRealtimeCostPeriod.monthKey(date, timeZone: timeZone)
        if state.dayKey != day {
            state.dayKey = day
            state.dayCostUSD = 0
            state.daySessions = 0
        }
        if state.monthKey != month {
            state.monthKey = month
            state.monthCostUSD = 0
            state.monthSessions = 0
        }
        return state
    }

    private func load() -> State {
        guard let data = defaults.data(forKey: key), let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    private func save(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
