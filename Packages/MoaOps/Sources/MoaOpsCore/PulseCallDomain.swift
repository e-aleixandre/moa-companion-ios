import Foundation

public enum PulseProvenance: String, Codable, Equatable, Sendable {
    case moaObserved = "moa_observed"
    case moaDerived = "moa_derived"
    case agentReported = "agent_reported"
    case pulseInference = "pulse_inference"
    case localFreshness = "local_freshness"

    public var spanishLabel: String {
        switch self {
        case .moaObserved: "Moa observó"
        case .moaDerived: "Moa derivó"
        case .agentReported: "El agente reporta"
        case .pulseInference: "Pulse infiere"
        case .localFreshness: "Estado local"
        }
    }
}

public struct PulseCitation: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let provenance: PulseProvenance
    public let at: Date?

    public init(id: String, label: String, provenance: PulseProvenance, at: Date? = nil) {
        self.id = id
        self.label = label
        self.provenance = provenance
        self.at = at
    }
}

public struct PulseDeterministicBrief: Equatable, Sendable {
    public let spoken: String
    public let citations: [PulseCitation]
    public let activeFronts: Int
    public let isFallback: Bool

    public init(spoken: String, citations: [PulseCitation], activeFronts: Int, isFallback: Bool) {
        self.spoken = spoken
        self.citations = citations
        self.activeFronts = activeFronts
        self.isFallback = isFallback
    }
}

/// This builder only maps the bounded Ops projection. It intentionally has no
/// input for display transcripts, tool output, or provider prose.
public enum PulseBriefBuilder {
    public static func make(pulse: OpsPulse, sitrep: OpsBriefing? = nil, isFallback: Bool = false) -> PulseDeterministicBrief {
        let active = orderedUnique(pulse.needsAttention + pulse.inProgress + pulse.staleWork + pulse.onTrack)
        let fronts = active.filter { $0.lifecycle == .running || $0.activity == .running || $0.activity == .permission }.count
        let attention = pulse.needsAttention.sorted { ($0.priority ?? Int.max) < ($1.priority ?? Int.max) }.first
        let continuing = pulse.inProgress.first ?? pulse.onTrack.first
        let stale = pulse.staleWork.first
        var clauses: [String] = []
        clauses.append(fronts == 0 ? "No veo frentes activos en la última proyección de Moa." : "Hay \(fronts) \(fronts == 1 ? "frente activo" : "frentes activos").")
        if let attention {
            clauses.append(exception(attention))
        } else if let stale {
            clauses.append("\(stale.session.title) no tiene una observación segura reciente; no afirmaré que esté al día.")
        } else {
            clauses.append("No hay una excepción que requiera tu decisión en esta proyección.")
        }
        if let continuing {
            clauses.append("\(continuing.session.title) sigue \(continuing.activity == .running ? "avanzando" : "en seguimiento") sin intervención indicada.")
        }
        clauses.append(attention == nil ? "¿Quieres el resumen completo?" : "¿Quieres que explique el bloqueo o el resumen completo?")

        var citations = active.prefix(4).flatMap { item -> [PulseCitation] in
            let provenance: PulseProvenance = item.facts.contains { $0.provenance == .observed } ? .moaObserved : .moaDerived
            return [PulseCitation(id: item.id, label: item.session.title, provenance: provenance, at: item.observedAt)]
        }
        if let sitrep, !sitrep.spoken.isEmpty {
            citations.append(.init(id: "ops:sitrep", label: "Panorama seguro de Moa", provenance: .moaDerived))
        }
        return .init(spoken: clauses.joined(separator: " "), citations: citations, activeFronts: fronts, isFallback: isFallback)
    }

    public static func offline(last: PulseDeterministicBrief, age: TimeInterval) -> PulseDeterministicBrief {
        let minutes = max(1, Int((age / 60.0).rounded(.down)))
        return .init(
            spoken: "Moa no está disponible. Esto es el último estado conocido de hace \(minutes) \(minutes == 1 ? "minuto" : "minutos"). \(last.spoken)",
            citations: last.citations + [.init(id: "local:freshness", label: "Último estado conocido · hace \(minutes) min", provenance: .localFreshness)],
            activeFronts: last.activeFronts,
            isFallback: true
        )
    }

    public static func statusText(_ result: OpsStatusResult) -> String {
        guard let briefing = result.briefing else {
            return "Moa no pudo resolver un estado único para esa referencia."
        }
        let names = briefing.sessions?.map(\.title).joined(separator: ", ")
        let prefix = names.map { "Moa observó \($0)." } ?? "Moa devolvió un estado seguro."
        return "\(prefix) \(briefing.spoken)"
    }

    private static func exception(_ item: OpsPulseItem) -> String {
        switch item.category {
        case "permission_needed":
            return "La excepción principal es \(item.session.title): Moa observó una solicitud de permiso pendiente; necesita tu decisión."
        case "verification_failed":
            return "La excepción principal es \(item.session.title): Moa observó una verificación fallida."
        case "lifecycle_error", "activity_error", "error":
            return "La excepción principal es \(item.session.title): Moa observó un error que requiere revisión."
        case "ask_user", "permission":
            return "La excepción principal es \(item.session.title): Moa espera una respuesta tuya."
        default:
            return "La excepción principal es \(item.session.title): Moa marcó \(safeCategory(item.category)) para tu atención."
        }
    }

    private static func safeCategory(_ category: String) -> String {
        switch category {
        case "run_started": "un inicio de trabajo"
        case "run_ended": "un cambio de ejecución"
        case "stale_work": "trabajo sin observación reciente"
        default: "un cambio operativo"
        }
    }

    private static func orderedUnique(_ items: [OpsPulseItem]) -> [OpsPulseItem] {
        var ids = Set<String>()
        return items.filter { ids.insert($0.id).inserted }
    }
}

public enum PulseToolName: String, CaseIterable, Sendable {
    case getPulse = "get_pulse"
    case getStatus = "get_status"
    case safeConversationEvidence = "get_safe_conversation_evidence"
    case prepareDirectedInstruction = "prepare_directed_instruction"
    case preparePermissionDecision = "prepare_permission_decision"
}

public struct PulseToolUse: Equatable, Sendable {
    public let id: String
    public let name: String
    public let input: Data

    public init(id: String, name: String, input: Data) {
        self.id = id
        self.name = name
        self.input = input
    }
}

public enum PulseToolRequest: Equatable, Sendable {
    case getPulse
    case getStatus(target: String)
    case safeConversationEvidence(sessionID: String)
    case prepareDirectedInstruction(target: String, text: String)
    case preparePermissionDecision(target: String, decision: PulsePermissionDecision)

    public init(toolUse: PulseToolUse) throws {
        guard let name = PulseToolName(rawValue: toolUse.name),
              let object = try JSONSerialization.jsonObject(with: toolUse.input) as? [String: Any] else {
            throw PulseCallError.operationUnavailable
        }
        func exact(_ expected: Set<String>) -> Bool { Set(object.keys) == expected }
        func safeString(_ key: String, maximum: Int) -> String? {
            guard let value = object[key] as? String,
                  validReference(value, limit: maximum) else { return nil }
            return value
        }
        switch name {
        case .getPulse:
            guard exact([]) else { throw PulseCallError.operationUnavailable }
            self = .getPulse
        case .getStatus:
            guard exact(["target"]), let target = safeString("target", maximum: 256) else { throw PulseCallError.operationUnavailable }
            self = .getStatus(target: target)
        case .safeConversationEvidence:
            guard exact(["session_id"]), let id = safeString("session_id", maximum: 256) else { throw PulseCallError.operationUnavailable }
            self = .safeConversationEvidence(sessionID: id)
        case .prepareDirectedInstruction:
            guard exact(["target", "text"]), let target = safeString("target", maximum: 256), let text = safeString("text", maximum: 1_024) else { throw PulseCallError.operationUnavailable }
            self = .prepareDirectedInstruction(target: target, text: text)
        case .preparePermissionDecision:
            guard exact(["target", "decision"]), let target = safeString("target", maximum: 256), let raw = object["decision"] as? String, let decision = PulsePermissionDecision(rawValue: raw) else { throw PulseCallError.operationUnavailable }
            self = .preparePermissionDecision(target: target, decision: decision)
        }
    }
}

public struct PulseToolExecution: Equatable, Sendable {
    public let toolUseID: String
    public let content: String
    public let isError: Bool
    public let preparedReview: PulsePendingReview?

    public init(toolUseID: String, content: String, isError: Bool = false, preparedReview: PulsePendingReview? = nil) {
        self.toolUseID = toolUseID
        self.content = content
        self.isError = isError
        self.preparedReview = preparedReview
    }
}

public protocol PulseToolExecuting: Sendable {
    func execute(_ toolUse: PulseToolUse) async -> PulseToolExecution
}

public actor PulseWriteGate {
    private var online = false
    public init() {}
    public func setOnline(_ value: Bool) { online = value }
    public func allowsWrites() -> Bool { online }
}

/// The model receives only the strings returned here. There is no generic URL,
/// method, auth header, or raw Moa response in this boundary.
public actor PulseMoaToolExecutor: PulseToolExecuting {
    private let service: any PulseCallService
    private let writeGate: PulseWriteGate
    private var latestPulse: OpsPulse?

    public init(service: any PulseCallService, writeGate: PulseWriteGate) {
        self.service = service
        self.writeGate = writeGate
    }

    public func execute(_ toolUse: PulseToolUse) async -> PulseToolExecution {
        do {
            let request = try PulseToolRequest(toolUse: toolUse)
            switch request {
            case .getPulse:
                let pulse = try await service.loadPulse()
                latestPulse = pulse
                let brief = PulseBriefBuilder.make(pulse: pulse)
                return .init(toolUseID: toolUse.id, content: toolResult("safe_ops", brief.spoken, provenance: "moa_observed"))
            case let .getStatus(target):
                let status = try await service.loadStatus(target: target)
                return .init(toolUseID: toolUse.id, content: toolResult("safe_status", PulseBriefBuilder.statusText(status), provenance: "moa_observed"))
            case let .safeConversationEvidence(sessionID):
                let page = try await service.loadSafeConversationEvidence(sessionID: sessionID)
                let excerpts = page.messages.reversed().prefix(6).map { message in
                    "\(message.role == "assistant" ? "agent_reported" : "owner_message"): \(message.text)"
                }.joined(separator: "\n")
                return .init(toolUseID: toolUse.id, content: toolResult("display_conversation_untrusted", excerpts.isEmpty ? "No hay extractos seguros disponibles." : excerpts, provenance: "agent_reported"))
            case let .prepareDirectedInstruction(target, text):
                guard await writeGate.allowsWrites() else { return unavailable(toolUse.id) }
                let response = try await service.prepareOperation(.directedInstruction(target: target, text: text))
                guard let review = response.pendingReview else { return rejected(toolUse.id) }
                return .init(toolUseID: toolUse.id, content: toolResult("immutable_review", PulseOperationNarrator.review(review), provenance: "moa_observed"), preparedReview: review)
            case let .preparePermissionDecision(target, decision):
                guard await writeGate.allowsWrites() else { return unavailable(toolUse.id) }
                let response = try await service.prepareOperation(.permissionDecision(target: target, decision: decision))
                guard let review = response.pendingReview else { return rejected(toolUse.id) }
                return .init(toolUseID: toolUse.id, content: toolResult("immutable_review", PulseOperationNarrator.review(review), provenance: "moa_observed"), preparedReview: review)
            }
        } catch {
            return .init(toolUseID: toolUse.id, content: "La consulta tipada de Moa no está disponible.", isError: true)
        }
    }

    private func toolResult(_ kind: String, _ text: String, provenance: String) -> String {
        "<\(kind) provenance=\"\(provenance)\">\n\(text)\n</\(kind)>"
    }

    private func unavailable(_ id: String) -> PulseToolExecution {
        .init(toolUseID: id, content: "Moa está sin conexión; Pulse no prepara ni encola acciones sin conexión.", isError: true)
    }

    private func rejected(_ id: String) -> PulseToolExecution {
        .init(toolUseID: id, content: "Moa no devolvió una revisión inmutable actual. Pide una aclaración; no hay operación confirmable.", isError: true)
    }
}

/// Voice approval is deliberately a tiny deterministic reducer. It refuses
/// to interpret assent unless exactly one current review is visibly bound.
public enum PulseReviewVoiceConfirmation: Equatable, Sendable {
    case confirm
    case cancel
    case none

    public static func resolve(transcript: String, visibleReviews: [PulsePendingReview], now: Date = Date()) -> PulseReviewVoiceConfirmation {
        guard visibleReviews.count == 1, visibleReviews[0].isCurrent(now: now) else { return .none }
        let normalized = transcript
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        switch normalized {
        case "si", "confirmo", "confirmar": return .confirm
        case "no", "cancela", "cancelar": return .cancel
        default: return .none
        }
    }
}
