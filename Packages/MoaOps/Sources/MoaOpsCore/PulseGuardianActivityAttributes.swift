import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

/// The Guardian's Live Activity face. It does not keep the app alive and is
/// designed for the roughly eight-hour Live Activity system limit.
public struct PulseGuardianActivityAttributes: Codable, Hashable, Sendable {
    public let startedAt: Date
    public let ownerName: String?

    public init(startedAt: Date, ownerName: String?) {
        self.startedAt = startedAt
        self.ownerName = ownerName
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public let stateLabel: String
        public let sessionCount: Int
        public let pendingCount: Int
        public let lastEventLine: String?

        public init(stateLabel: String, sessionCount: Int, pendingCount: Int, lastEventLine: String?) {
            self.stateLabel = stateLabel
            self.sessionCount = sessionCount
            self.pendingCount = pendingCount
            self.lastEventLine = lastEventLine
        }
    }

    /// Pure snapshot mapper shared by the app and the future widget target.
    public static func contentState(state: PulseGuardianState, snapshot: PulseGuardianSnapshot) -> ContentState {
        let events = snapshot.items.map { ($0.createdAt, "\($0.alias): \($0.spoken)") }
            + snapshot.terminations.map { ($0.createdAt, "\($0.alias): \($0.spoken)") }
        let lastEventLine = events.max { $0.0 < $1.0 }.map { shortened($0.1) }
        return .init(
            stateLabel: state.spanishLabel,
            sessionCount: snapshot.sessions.count,
            pendingCount: snapshot.sessions.reduce(0) { $0 + $1.pendingAsks + $1.pendingPerms },
            lastEventLine: lastEventLine
        )
    }

    private static func shortened(_ text: String) -> String {
        String(text.prefix(80))
    }
}

#if canImport(ActivityKit)
extension PulseGuardianActivityAttributes: ActivityAttributes {}
#endif
