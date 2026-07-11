import Foundation

public struct OpsSnapshot: Codable, Equatable, Sendable {
    public let projects: [OpsProject]

    public init(projects: [OpsProject]) {
        self.projects = projects
    }
}

// MARK: - Pulse

/// The bounded, server-derived mobile inbox returned by `/api/ops/pulse`.
/// It deliberately has no transcript, command output, or arbitrary error text.
public struct OpsPulse: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let summary: OpsPulseSummary
    public let needsAttention: [OpsPulseItem]
    public let inProgress: [OpsPulseItem]
    public let onTrack: [OpsPulseItem]
    public let changes: OpsPulseChanges

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case summary
        case needsAttention = "needs_attention"
        case inProgress = "in_progress"
        case onTrack = "on_track"
        case changes
    }
}

public struct OpsPulseSummary: Codable, Equatable, Sendable {
    public let needsAttention: Int
    public let inProgress: Int
    public let onTrack: Int
    public let changes: Int

    enum CodingKeys: String, CodingKey {
        case needsAttention = "needs_attention"
        case inProgress = "in_progress"
        case onTrack = "on_track"
        case changes
    }
}

public struct OpsPulseChanges: Codable, Equatable, Sendable {
    public let requested: Bool
    public let since: Date?
    public let until: Date
    public let items: [OpsPulseItem]
    public let truncated: Bool
}

public struct OpsPulseItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let session: OpsPulseSession
    public let category: String
    public let priority: Int?
    public let lifecycle: OpsLifecycle
    public let activity: OpsActivity
    /// The API omits this value when verification is not known. Clients must
    /// not substitute an "unknown" status in its place.
    public let verification: OpsVerificationState?
    public let observedAt: Date?
    public let freshness: OpsPulseFreshness
    public let facts: [OpsPulseFact]
    public let directedInstruction: OpsPulseDirectedInstruction?

    enum CodingKeys: String, CodingKey {
        case id, session, category, priority, lifecycle, activity, verification, freshness, facts
        case observedAt = "observed_at"
        case directedInstruction = "directed_instruction"
    }
}

public struct OpsPulseSession: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let project: String
}

public enum OpsPulseFreshness: String, Codable, Equatable, Sendable {
    case fresh, stale, unknown
}

public enum OpsPulseProvenance: String, Codable, Equatable, Sendable {
    case observed, derived
}

public struct OpsPulseFact: Codable, Equatable, Sendable {
    public let kind: String
    public let value: String
    public let at: Date?
    public let refID: String?
    public let provenance: OpsPulseProvenance

    enum CodingKeys: String, CodingKey {
        case kind, value, at, provenance
        case refID = "ref_id"
    }
}

public struct OpsPulseDirectedInstruction: Codable, Equatable, Sendable {
    public let targetID: String

    enum CodingKeys: String, CodingKey {
        case targetID = "target_id"
    }
}

public struct OpsProject: Codable, Equatable, Sendable {
    public let canonicalCWD: String
    public let aliases: [String]?
    public let sessions: [OpsSession]

    public init(canonicalCWD: String, aliases: [String]? = nil, sessions: [OpsSession]) {
        self.canonicalCWD = canonicalCWD
        self.aliases = aliases
        self.sessions = sessions
    }

    enum CodingKeys: String, CodingKey {
        case canonicalCWD = "canonical_cwd"
        case aliases, sessions
    }
}

public struct OpsSession: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let aliases: [String]?
    public let presence: OpsPresence
    public let lifecycle: OpsLifecycle
    public let activity: OpsActivity
    public let lastTransitionAt: Date?
    public let jobs: OpsJobCounts
    public let verification: OpsVerification
    public let milestones: [OpsMilestone]

    public init(id: String, title: String, aliases: [String]? = nil, presence: OpsPresence, lifecycle: OpsLifecycle, activity: OpsActivity, lastTransitionAt: Date? = nil, jobs: OpsJobCounts, verification: OpsVerification, milestones: [OpsMilestone]) {
        self.id = id
        self.title = title
        self.aliases = aliases
        self.presence = presence
        self.lifecycle = lifecycle
        self.activity = activity
        self.lastTransitionAt = lastTransitionAt
        self.jobs = jobs
        self.verification = verification
        self.milestones = milestones
    }

    enum CodingKeys: String, CodingKey {
        case id, title, aliases, presence, lifecycle, activity, jobs, verification, milestones
        case lastTransitionAt = "last_transition_at"
    }
}

public enum OpsPresence: String, Codable, Sendable {
    case active, saved
}

public enum OpsLifecycle: String, Codable, Sendable {
    case idle, running, stopped, error
}

public enum OpsActivity: String, Codable, Sendable {
    case idle, running, permission, error
}

public enum OpsVerificationState: String, Codable, Sendable {
    case unknown, pending, passed, failed

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = OpsVerificationState(rawValue: value) ?? .unknown
    }
}

public enum OpsMilestoneType: String, Codable, Sendable {
    case runStarted = "run_started"
    case runEnded = "run_ended"
    case error, permission
    case askUser = "ask_user"
    case verification
}

public enum OpsTargetKind: String, Codable, Sendable {
    case session, project
}

public enum OpsBlockerKind: String, Codable, Sendable {
    case error, permission
    case verificationFailed = "verification_failed"
}

public struct OpsJobCounts: Codable, Equatable, Sendable {
    public let subagents: Int
    public let bash: Int

    public init(subagents: Int, bash: Int) {
        self.subagents = subagents
        self.bash = bash
    }
}

public struct OpsVerification: Codable, Equatable, Sendable {
    public let state: OpsVerificationState
    public let at: Date?

    public init(state: OpsVerificationState, at: Date? = nil) {
        self.state = state
        self.at = at
    }
}

public struct OpsMilestone: Codable, Equatable, Sendable {
    public let type: OpsMilestoneType
    public let at: Date
    public let refID: String

    public init(type: OpsMilestoneType, at: Date, refID: String) {
        self.type = type
        self.at = at
        self.refID = refID
    }

    enum CodingKeys: String, CodingKey {
        case type, at
        case refID = "ref_id"
    }
}

public struct OpsSessionStatus: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let presence: OpsPresence
    public let lifecycle: OpsLifecycle
    public let activity: OpsActivity
    public let jobs: OpsJobCounts
    public let verification: OpsVerificationState
}

public struct OpsBlocker: Codable, Equatable, Sendable {
    public let kind: OpsBlockerKind
    public let sessionID: String
    public let title: String

    enum CodingKeys: String, CodingKey {
        case kind, title
        case sessionID = "session_id"
    }
}

public struct OpsBriefing: Codable, Equatable, Sendable {
    public let sessions: [OpsSessionStatus]?
    public let blockers: [OpsBlocker]
    public let spoken: String
}

public struct OpsCandidate: Codable, Equatable, Sendable {
    public let kind: OpsTargetKind
    public let id: String?
    public let title: String?
    public let canonicalCWD: String?

    enum CodingKeys: String, CodingKey {
        case kind, id, title
        case canonicalCWD = "canonical_cwd"
    }
}

public struct OpsResolution: Codable, Equatable, Sendable {
    public let target: String
    public let candidates: [OpsCandidate]
}

public struct OpsStatusResult: Codable, Equatable, Sendable {
    public let resolution: OpsResolution
    public let briefing: OpsBriefing?
}

public struct OpsAskRequest: Encodable, Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// The server decides whether a question can be answered from verified Ops data.
/// Unknown future kinds deliberately decode as `unknown` so callers never present
/// an unrecognised payload as a verified answer.
public enum OpsAskKind: Equatable, Sendable {
    case sitrep
    case blockers
    case status
    case unsupported
    case unknown
}

extension OpsAskKind: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "sitrep": self = .sitrep
        case "blockers": self = .blockers
        case "status": self = .status
        case "unsupported": self = .unsupported
        default: self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let value: String
        switch self {
        case .sitrep: value = "sitrep"
        case .blockers: value = "blockers"
        case .status: value = "status"
        case .unsupported: value = "unsupported"
        case .unknown: value = "unknown"
        }
        try container.encode(value)
    }
}

public struct OpsAskResponse: Codable, Equatable, Sendable {
    public let kind: OpsAskKind
    public let resolution: OpsResolution?
    public let briefing: OpsBriefing?

    public init(kind: OpsAskKind, resolution: OpsResolution? = nil, briefing: OpsBriefing? = nil) {
        self.kind = kind
        self.resolution = resolution
        self.briefing = briefing
    }
}

public struct OpsInstructionRequest: Encodable, Equatable, Sendable {
    public let target: String
    public let text: String
    public let requestID: String

    public init(target: String, text: String, requestID: String = UUID().uuidString) {
        self.target = target
        self.text = text
        self.requestID = requestID
    }

    enum CodingKeys: String, CodingKey {
        case target, text
        case requestID = "request_id"
    }
}

public struct OpsInstructionTarget: Codable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let project: String?
}

public struct OpsInstructionResponse: Codable, Equatable, Sendable {
    public let action: String
    public let target: OpsInstructionTarget
}

public struct OpsInstructionConflict: Codable, Equatable, Sendable {
    public let candidates: [OpsInstructionTarget]
}

public struct OpsWebSocketEnvelope: Codable, Equatable, Sendable {
    public let type: String
    public let version: UInt64
    public let snapshot: OpsSnapshot
}
