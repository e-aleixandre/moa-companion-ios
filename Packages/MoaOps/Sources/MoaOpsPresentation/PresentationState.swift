import Foundation
import MoaOpsCore

public protocol PulseCursorStore: AnyObject {
    func lastSeen() -> Date?
    func save(lastSeen: Date)
    func clear()
}

/// Stores only the non-secret Pulse cursor. URLs, credentials, instruction
/// text, and server payloads are intentionally not persisted.
public final class UserDefaultsPulseCursorStore: PulseCursorStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "moa.ops.pulse.lastSeen") {
        self.defaults = defaults
        self.key = key
    }

    public func lastSeen() -> Date? { defaults.object(forKey: key) as? Date }
    public func save(lastSeen: Date) { defaults.set(lastSeen, forKey: key) }
    public func clear() { defaults.removeObject(forKey: key) }
}

public struct PulseInstructionTarget: Equatable, Sendable {
    public let id: String
    public let title: String
    public let project: String

    public init(id: String, title: String, project: String) {
        self.id = id
        self.title = title
        self.project = project
    }
}

public struct PulseFactDisplay: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let provenance: String
    public let at: Date?
}

public struct PulseCard: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let project: String
    public let category: String
    public let categoryDetail: String
    public let lifecycle: String
    public let activity: String
    public let verification: String?
    public let freshness: String
    public let observedAt: Date?
    public let facts: [PulseFactDisplay]
    public let instructionTarget: PulseInstructionTarget?
}

public enum PulseSectionKind: Int, Equatable, Sendable {
    case needsAttention
    case changes
    case inProgress
    case onTrack

    public var title: String {
        switch self {
        case .needsAttention: "Necesita de ti"
        case .changes: "Cambios desde tu última visita"
        case .inProgress: "En marcha"
        case .onTrack: "En buen camino"
        }
    }
}

public struct PulseSection: Identifiable, Equatable, Sendable {
    public let kind: PulseSectionKind
    public let cards: [PulseCard]

    public var id: Int { kind.rawValue }
}

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

public struct OpsAskHistoryEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let question: String
    public let kind: OpsAskKind
    public let resolution: OpsResolution?
    public let briefing: OpsBriefing

    public init(id: UUID = UUID(), question: String, kind: OpsAskKind, resolution: OpsResolution?, briefing: OpsBriefing) {
        self.id = id
        self.question = question
        self.kind = kind
        self.resolution = resolution
        self.briefing = briefing
    }

    public var statusLabel: String {
        switch kind {
        case .sitrep: "Verified sitrep"
        case .blockers: "Verified blockers"
        case .status: "Verified status"
        case .unsupported, .unknown: "Unsupported"
        }
    }
}

public enum OpsAskFeedback: Equatable, Sendable {
    case unsupported
    case unavailable

    public var message: String {
        switch self {
        case .unsupported:
            "Moa could not provide a verified answer for that question. Try a suggested verified prompt."
        case .unavailable:
            "Moa could not retrieve a verified answer. Check the connection and try again."
        }
    }
}

public struct OpsInstructionReceipt: Equatable, Sendable {
    public let title: String
    public let delivery: Delivery

    public enum Delivery: Equatable, Sendable {
        case sent
        case steered

        init(action: String) {
            self = action.lowercased() == "steered" ? .steered : .sent
        }

        var label: String {
            switch self {
            case .sent: "sent"
            case .steered: "steered"
            }
        }
    }

    public init(title: String, action: String) {
        self.title = title
        delivery = Delivery(action: action)
    }

    public var message: String { "Delivered to \(title) — \(delivery.label)" }
    public var completionNotice: String { "Delivery is not proof of completion. Check verified status for progress." }
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

    public static func askHistoryEntry(question: String, response: OpsAskResponse) -> OpsAskHistoryEntry? {
        guard let briefing = response.briefing else { return nil }
        switch response.kind {
        case .sitrep, .blockers, .status:
            return OpsAskHistoryEntry(question: question, kind: response.kind, resolution: response.resolution, briefing: briefing)
        case .unsupported, .unknown:
            return nil
        }
    }

    public static func appendingAskHistory(_ entry: OpsAskHistoryEntry, to history: [OpsAskHistoryEntry], maximumCount: Int = 6) -> [OpsAskHistoryEntry] {
        Array((history + [entry]).suffix(maximumCount))
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
        case let .httpStatus(code, _):
            switch code {
            case 401:
                return "The server requires authentication. Check your access and try again."
            case 403:
                return "The server did not authorize this request. Check authentication and request authorization."
            case 404:
                return "This server does not support the requested Ops API."
            case 429:
                return "The server is rate limiting requests. Try again shortly."
            default:
                return "The server refused the request. Try again later."
            }
        case .transport, .invalidResponse:
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

    public static func pulseSections(for pulse: OpsPulse) -> [PulseSection] {
        let candidates: [(PulseSectionKind, [OpsPulseItem])] = [
            (.needsAttention, pulse.needsAttention),
            (.changes, pulse.changes.requested ? pulse.changes.items : []),
            (.inProgress, pulse.inProgress),
            (.onTrack, pulse.onTrack),
        ]
        return candidates.compactMap { kind, items in
            let cards = items.compactMap(pulseCard)
            return cards.isEmpty ? nil : PulseSection(kind: kind, cards: cards)
        }
    }

    /// Only known, safe enum values are converted to visible copy. This
    /// prevents a future wire value from becoming a status or a raw error.
    public static func pulseCard(_ item: OpsPulseItem) -> PulseCard? {
        guard let category = pulseCategory(item.category) else { return nil }
        let verification = knownVerificationLabel(item.verification)
        let facts = Array(item.facts.prefix(3)).enumerated().compactMap { index, fact in
            pulseFact(fact, id: "\(item.id):\(index)")
        }
        let target = item.directedInstruction.map {
            PulseInstructionTarget(id: $0.targetID, title: item.session.title, project: item.session.project)
        }
        return PulseCard(
            id: item.id,
            title: item.session.title,
            project: item.session.project,
            category: category.title,
            categoryDetail: category.detail,
            lifecycle: pulseLifecycle(item.lifecycle),
            activity: pulseActivity(item.activity),
            verification: verification,
            freshness: pulseFreshness(item.freshness),
            observedAt: item.observedAt,
            facts: facts,
            instructionTarget: target
        )
    }

    public static func knownVerificationLabel(_ verification: OpsVerificationState?) -> String? {
        guard let verification else { return nil }
        switch verification {
        case .passed: return "Verificación superada"
        case .pending: return "Verificación pendiente"
        case .failed: return "Verificación fallida"
        case .unknown: return nil
        }
    }

    private static func pulseCategory(_ value: String) -> (title: String, detail: String)? {
        switch value {
        case "lifecycle_error": return ("Error de ciclo", "La sesión requiere revisión.")
        case "activity_error": return ("Error de actividad", "La actividad necesita atención.")
        case "permission_needed": return ("Permiso necesario", "Moa espera una decisión o permiso.")
        case "verification_failed": return ("Verificación fallida", "La comprobación conocida no pasó.")
        case "in_progress": return ("En marcha", "La sesión sigue trabajando.")
        case "on_track": return ("En buen camino", "El trabajo sigue en marcha con verificación superada.")
        case "run_started": return ("Trabajo iniciado", "Se registró el inicio de una ejecución.")
        case "run_ended": return ("Trabajo finalizado", "Se registró el final de una ejecución.")
        case "error": return ("Error registrado", "Se registró un cambio de error.")
        case "permission": return ("Permiso registrado", "Se registró una solicitud de permiso.")
        case "ask_user": return ("Respuesta solicitada", "Se registró una solicitud para ti.")
        case "verification": return ("Verificación actualizada", "Se registró un cambio de verificación.")
        default: return nil
        }
    }

    private static func pulseFact(_ fact: OpsPulseFact, id: String) -> PulseFactDisplay? {
        let title: String?
        switch (fact.kind, fact.value) {
        case ("attention_reason", "lifecycle_error"): title = "Motivo: error de ciclo"
        case ("attention_reason", "activity_error"): title = "Motivo: error de actividad"
        case ("attention_reason", "permission_needed"): title = "Motivo: permiso necesario"
        case ("attention_reason", "verification_failed"): title = "Motivo: verificación fallida"
        case ("lifecycle", "idle"): title = "Ciclo: en espera"
        case ("lifecycle", "running"): title = "Ciclo: en ejecución"
        case ("lifecycle", "stopped"): title = "Ciclo: detenido"
        case ("lifecycle", "error"): title = "Ciclo: error"
        case ("activity", "idle"): title = "Actividad: en espera"
        case ("activity", "running"): title = "Actividad: trabajando"
        case ("activity", "permission"): title = "Actividad: espera permiso"
        case ("activity", "error"): title = "Actividad: error"
        case ("verification", "pending"): title = "Verificación: pendiente"
        case ("verification", "passed"): title = "Verificación: superada"
        case ("verification", "failed"): title = "Verificación: fallida"
        case ("milestone", "run_started"): title = "Hito: trabajo iniciado"
        case ("milestone", "run_ended"): title = "Hito: trabajo finalizado"
        case ("milestone", "error"): title = "Hito: error"
        case ("milestone", "permission"): title = "Hito: permiso"
        case ("milestone", "ask_user"): title = "Hito: respuesta solicitada"
        case ("milestone", "verification"): title = "Hito: verificación"
        default: title = nil
        }
        guard let title else { return nil }
        let provenance = fact.provenance == .observed ? "Observado" : "Derivado"
        return PulseFactDisplay(id: id, title: title, provenance: provenance, at: fact.at)
    }

    private static func pulseLifecycle(_ lifecycle: OpsLifecycle) -> String {
        switch lifecycle {
        case .idle: return "En espera"
        case .running: return "En ejecución"
        case .stopped: return "Detenido"
        case .error: return "Error"
        }
    }

    private static func pulseActivity(_ activity: OpsActivity) -> String {
        switch activity {
        case .idle: return "En espera"
        case .running: return "Trabajando"
        case .permission: return "Espera permiso"
        case .error: return "Error"
        }
    }

    private static func pulseFreshness(_ freshness: OpsPulseFreshness) -> String {
        switch freshness {
        case .fresh: return "Actual"
        case .stale: return "Puede estar desactualizado"
        case .unknown: return "Fecha no disponible"
        }
    }
}
