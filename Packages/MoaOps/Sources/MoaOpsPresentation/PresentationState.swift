import Foundation
import MoaOpsCore

public struct ServerConfiguration: Equatable, Sendable {
    public let baseURL: URL

    public init(urlText: String) throws {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let url = components.url,
              (components.scheme == "http" || components.scheme == "https"),
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw ServerConfigurationError.invalidURL
        }
        baseURL = url
    }
}

public enum ServerConfigurationError: Error, Equatable, Sendable {
    case invalidURL

    public var userMessage: String {
        "Enter a valid http:// or https:// server URL."
    }
}

public enum OpsConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)

    init(webSocketState: OpsWebSocketState) {
        switch webSocketState {
        case .stopped: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case let .reconnecting(attempt): self = .reconnecting(attempt: attempt)
        }
    }

    public var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Live"
        case .reconnecting: "Reconnecting…"
        }
    }
}

public struct OpsSessionTarget: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let projectName: String

    public init(id: String, title: String, projectName: String) {
        self.id = id
        self.title = title
        self.projectName = projectName
    }
}

public struct OpsSessionDetail: Equatable, Sendable {
    public let id: String
    public let title: String
    public let projectName: String
    public let lifecycle: String
    public let activity: String
    public let verification: String
    public let subagentJobs: Int
    public let shellJobs: Int
    public let lastTransitionAt: Date?

    public init(session: OpsSession, projectName: String) {
        id = session.id
        title = session.title
        self.projectName = projectName
        lifecycle = PresentationMapper.label(for: session.lifecycle)
        activity = PresentationMapper.label(for: session.activity)
        verification = PresentationMapper.label(for: session.verification.state)
        subagentJobs = session.jobs.subagents
        shellJobs = session.jobs.bash
        lastTransitionAt = session.lastTransitionAt
    }
}

public enum PresentationMapper {
    public static func sessionTargets(in snapshot: OpsSnapshot?) -> [OpsSessionTarget] {
        guard let snapshot else { return [] }
        return snapshot.projects.flatMap { project in
            project.sessions.map {
                OpsSessionTarget(id: $0.id, title: $0.title, projectName: project.canonicalCWD)
            }
        }
    }

    public static func detail(sessionID: String, in snapshot: OpsSnapshot?) -> OpsSessionDetail? {
        guard let snapshot else { return nil }
        for project in snapshot.projects {
            if let session = project.sessions.first(where: { $0.id == sessionID }) {
                return OpsSessionDetail(session: session, projectName: project.canonicalCWD)
            }
        }
        return nil
    }

    public static func isStale(lastSnapshotAt: Date?, connection: OpsConnectionState, now: Date, maximumAge: TimeInterval = 45) -> Bool {
        guard connection == .connected, let lastSnapshotAt else { return true }
        return now.timeIntervalSince(lastSnapshotAt) > maximumAge
    }

    public static func userMessage(for error: Error) -> String {
        guard let error = error as? MoaOpsClientError else {
            return "Could not reach the server. Check the address and try again."
        }
        switch error {
        case .invalidBaseURL:
            return "The server address is not valid."
        case .authentication:
            return "The server did not accept this connection."
        case .httpStatus, .transport, .invalidResponse:
            return "Could not reach the server. Check the address and try again."
        case .decoding:
            return "The server sent an unsupported response."
        case .instructionConflict:
            return "That session changed. Select it again before sending an instruction."
        }
    }

    static func label(for lifecycle: OpsLifecycle) -> String { lifecycle.rawValue.capitalized }
    static func label(for activity: OpsActivity) -> String { activity.rawValue.capitalized }
    static func label(for state: OpsVerificationState) -> String { state.rawValue.capitalized }
}
