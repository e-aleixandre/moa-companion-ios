@preconcurrency import Foundation

public enum PulseOperationKind: String, Codable, Equatable, Sendable {
    case directedInstruction = "directed_instruction"
    case permissionDecision = "permission_decision"
}

public enum PulsePermissionDecision: String, Codable, Equatable, Sendable {
    case approveOnce = "approve_once"
    case deny
}

/// The two prepare bodies are constructed by code, never by passing through a
/// model-generated dictionary. Their encoders expose only the server contract.
public enum PulseOperationPrepare: Equatable, Sendable {
    case directedInstruction(target: String, text: String)
    case permissionDecision(target: String, decision: PulsePermissionDecision)

    var kind: PulseOperationKind {
        switch self {
        case .directedInstruction: .directedInstruction
        case .permissionDecision: .permissionDecision
        }
    }
}

extension PulseOperationPrepare: Encodable {
    enum CodingKeys: String, CodingKey { case kind, target, text, decision }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case let .directedInstruction(target, text):
            try container.encode(target, forKey: .target)
            try container.encode(text, forKey: .text)
        case let .permissionDecision(target, decision):
            try container.encode(target, forKey: .target)
            try container.encode(decision, forKey: .decision)
        }
    }
}

public struct PulseOperationTarget: Codable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let project: String?

    public init(id: String, title: String? = nil, project: String? = nil) {
        self.id = id
        self.title = title
        self.project = project
    }
}

public struct PulseOperationReview: Codable, Equatable, Sendable {
    public let target: PulseOperationTarget
    public let text: String?
    public let action: String
    public let risk: String
    public let consequence: String
    public let tool: String?
    public let decision: String?
    public let scope: String?
}

public struct PulseOperationReceipt: Codable, Equatable, Sendable {
    public let operationID: String
    public let kind: PulseOperationKind
    public let status: String
    public let action: String?
    public let delivery: String?
    public let observation: String
    public let completion: String?
    public let reason: String?
    public let at: Date

    enum CodingKeys: String, CodingKey {
        case kind, status, action, delivery, observation, completion, reason, at
        case operationID = "operation_id"
    }
}

public struct PulseOperationResponse: Codable, Equatable, Sendable {
    public let operationID: String
    public let kind: PulseOperationKind
    public let status: String
    public let expiresAt: Date?
    public let review: PulseOperationReview?
    public let receipt: PulseOperationReceipt?

    enum CodingKeys: String, CodingKey {
        case kind, status, review, receipt
        case operationID = "operation_id"
        case expiresAt = "expires_at"
    }

    public var pendingReview: PulsePendingReview? {
        guard status == "pending_confirmation", let expiresAt, let review else { return nil }
        return PulsePendingReview(operationID: operationID, kind: kind, expiresAt: expiresAt, review: review)
    }
}

public struct PulsePendingReview: Equatable, Sendable, Identifiable {
    public let operationID: String
    public let kind: PulseOperationKind
    public let expiresAt: Date
    public let review: PulseOperationReview
    public var id: String { operationID }

    public init(operationID: String, kind: PulseOperationKind, expiresAt: Date, review: PulseOperationReview) {
        self.operationID = operationID
        self.kind = kind
        self.expiresAt = expiresAt
        self.review = review
    }

    public func isCurrent(now: Date = Date()) -> Bool { expiresAt > now }
}

public enum PulseOperationNarrator {
    public static func review(_ pending: PulsePendingReview) -> String {
        let target = pending.review.target.title ?? "el destino seleccionado"
        switch pending.kind {
        case .directedInstruction:
            let text = pending.review.text ?? ""
            return "Revisión de Moa. Destino: \(target). Texto: \(text). \(pending.review.consequence) Confirma o cancela."
        case .permissionDecision:
            let decision = pending.review.decision == PulsePermissionDecision.approveOnce.rawValue ? "aprobar una vez" : "denegar"
            let tool = pending.review.tool.map { " para \($0)" } ?? ""
            return "Revisión de Moa. \(decision.capitalized)\(tool) en \(target), alcance: \(pending.review.scope ?? "solo esta solicitud"). \(pending.review.consequence) Confirma o cancela."
        }
    }

    /// This speaks the canonical receipt, not an inferred work outcome.
    public static func receipt(_ receipt: PulseOperationReceipt) -> String {
        // A deny is canonically represented as a rejected permission action:
        // that means the owner-confirmed denial was applied, not that Moa
        // rejected the owner's request. Its observation disambiguates it from
        // an expired/stale review, which remains an ordinary rejection below.
        if receipt.kind == .permissionDecision,
           receipt.action == PulsePermissionDecision.deny.rawValue,
           receipt.status == "rejected",
           receipt.observation == "permission_resolved" {
            return "Moa aplicó tu denegación confirmada para esta única solicitud de permiso. No afirma nada sobre el trabajo posterior."
        }

        if receipt.kind == .permissionDecision,
           receipt.action == PulsePermissionDecision.approveOnce.rawValue,
           receipt.status == "accepted",
           receipt.observation == "permission_resolved" {
            return "Moa aplicó tu aprobación única confirmada para la solicitud revisada. No afirma nada sobre el trabajo posterior."
        }

        switch receipt.status {
        case "accepted":
            if receipt.delivery == "delivered_to_agent" {
                return "Moa aceptó la operación y entregó la instrucción al agente. No confirma que el trabajo esté terminado."
            }
            return "Moa aceptó la decisión revisada. La consecuencia posterior todavía no está confirmada."
        case "indeterminate":
            return "Moa no pudo determinar si la operación llegó a ejecutarse. No afirmaré que se haya completado ni la reintentaré automáticamente."
        case "rejected":
            return "Moa rechazó o dejó caducar la revisión. No se realizó una acción confirmada."
        default:
            return "Moa devolvió un recibo de estado no reconocido. Revisa la operación antes de continuar."
        }
    }
}

public actor MoaPulseDeviceClient {
    public let registration: PulseDeviceRegistration
    private let session: URLSession

    public init(registration: PulseDeviceRegistration, session: URLSession = PulseTransportFactory.ephemeralSession()) throws {
        _ = try PulseServerConfiguration(baseURL: registration.baseURL)
        self.registration = registration
        self.session = session
    }

    public func pulse() async throws -> OpsPulse {
        try await get(path: "api/ops/pulse", as: OpsPulse.self)
    }

    public func sitrep() async throws -> OpsBriefing {
        try await ops(view: "sitrep", target: nil, as: OpsBriefing.self)
    }

    public func blockers() async throws -> OpsBriefing {
        try await ops(view: "blockers", target: nil, as: OpsBriefing.self)
    }

    public func status(target: String) async throws -> OpsStatusResult {
        guard validReference(target, limit: 256) else { throw PulseCallError.operationUnavailable }
        return try await ops(view: "status", target: target, as: OpsStatusResult.self)
    }

    public func prepare(_ operation: PulseOperationPrepare) async throws -> PulseOperationResponse {
        switch operation {
        case let .directedInstruction(target, text):
            guard validReference(target, limit: 256), validReference(text, limit: 1_024) else { throw PulseCallError.operationUnavailable }
        case let .permissionDecision(target, _):
            guard validReference(target, limit: 256) else { throw PulseCallError.operationUnavailable }
        }
        return try await post(path: "api/pulse/operations/prepare", body: operation, as: PulseOperationResponse.self)
    }

    /// Confirm has an intentionally immutable empty body. There is no API here
    /// that accepts model text, a boolean, a URL, or a generic action.
    public func confirm(operationID: String) async throws -> PulseOperationResponse {
        guard validOperationID(operationID) else { throw PulseCallError.operationUnavailable }
        return try await post(path: "api/pulse/operations/\(operationID)/confirm", body: PulseEmptyObject(), as: PulseOperationResponse.self)
    }

    public func operation(operationID: String) async throws -> PulseOperationResponse {
        guard validOperationID(operationID) else { throw PulseCallError.operationUnavailable }
        return try await get(path: "api/pulse/operations/\(operationID)", as: PulseOperationResponse.self)
    }

    public func listSessions() async throws -> [MoaServeSessionInfo] {
        try await get(path: "api/sessions", as: [MoaServeSessionInfo].self)
    }

    public func attention() async throws -> MoaServeAttentionResponse {
        try await get(path: "api/attention", as: MoaServeAttentionResponse.self)
    }

    public func displayMessages(sessionID: String, limit: Int = 20, cursor: String? = nil) async throws -> MoaServeConversationPage {
        guard validRouteComponent(sessionID), (1...100).contains(limit) else {
            throw PulseCallError.operationUnavailable
        }
        if let cursor, !validOpaqueCursor(cursor) {
            throw PulseCallError.operationUnavailable
        }
        var components = URLComponents(url: sessionMessagesEndpoint(sessionID: sessionID), resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw PulseCallError.invalidServerURL }
        return try await get(url: url, as: MoaServeConversationPage.self)
    }

    public func toolDetail(sessionID: String, itemID: String) async throws -> MoaServeToolDetail {
        guard validRouteComponent(sessionID), validRouteComponent(itemID) else {
            throw PulseCallError.operationUnavailable
        }
        var components = URLComponents(url: sessionMessagesEndpoint(sessionID: sessionID), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "detail", value: "full"),
            URLQueryItem(name: "item_id", value: itemID),
        ]
        guard let url = components?.url else { throw PulseCallError.invalidServerURL }
        return try await get(url: url, as: MoaServeToolDetail.self)
    }

    /// This credential is intentionally returned only to the immediate caller.
    /// It is not a Moa credential and must never be used on another Moa route.
    public func mintRealtimeClientSecret(now: Date = Date(), expirySkew: TimeInterval = 30) async throws -> PulseRealtimeClientCredential {
        var request = authenticatedRequest(url: endpoint("api/pulse/realtime/client-secret"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Moa-Request")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await perform(request, session: session)
        guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
            if let http = response as? HTTPURLResponse { try validate(http) }
            throw PulseCallError.invalidResponse
        }
        guard http.value(forHTTPHeaderField: "Cache-Control")?.lowercased().contains("no-store") == true else { throw PulseCallError.invalidResponse }
        do { return try JSONDecoder.moaOps.decode(PulseRealtimeClientCredential.self, from: data).validated(now: now, expirySkew: expirySkew) }
        catch let error as PulseCallError { throw error }
        catch { throw PulseCallError.decoding }
    }

    private func ops<T: Decodable>(view: String, target: String?, as type: T.Type) async throws -> T {
        var components = URLComponents(url: endpoint("api/ops"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "view", value: view)]
        if let target { items.append(URLQueryItem(name: "target", value: target)) }
        components?.queryItems = items
        guard let url = components?.url else { throw PulseCallError.invalidServerURL }
        return try await get(url: url, as: type)
    }

    private func get<T: Decodable>(path: String, as type: T.Type) async throws -> T {
        try await get(url: endpoint(path), as: type)
    }

    private func get<T: Decodable>(url: URL, as type: T.Type) async throws -> T {
        var request = authenticatedRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await perform(request, session: session)
        guard let http = response as? HTTPURLResponse else { throw PulseCallError.invalidResponse }
        try validate(http)
        do {
            return try JSONDecoder.moaOps.decode(type, from: data)
        } catch {
            throw PulseCallError.decoding
        }
    }

    private func post<Body: Encodable, Response: Decodable>(path: String, body: Body, as type: Response.Type) async throws -> Response {
        var request = authenticatedRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Moa-Request")
        request.httpBody = try JSONEncoder.moaOps.encode(body)
        let (data, response) = try await perform(request, session: session)
        guard let http = response as? HTTPURLResponse else { throw PulseCallError.invalidResponse }
        try validate(http)
        do {
            return try JSONDecoder.moaOps.decode(type, from: data)
        } catch {
            throw PulseCallError.decoding
        }
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Moa-Device \(registration.credential)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        return request
    }

    private func endpoint(_ path: String) -> URL {
        registration.baseURL.appendingPathComponent(path)
    }

    private func sessionMessagesEndpoint(sessionID: String) -> URL {
        registration.baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("messages")
    }
}

private struct PulseEmptyObject: Encodable {}

func validReference(_ value: String, limit: Int) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.unicodeScalars.count <= limit && !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
}

private func validOperationID(_ value: String) -> Bool {
    value.count == 24 && value.unicodeScalars.allSatisfy {
        ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0 == "-" || $0 == "_"
    }
}

private func validRouteComponent(_ value: String) -> Bool {
    guard validReference(value, limit: 512), value != ".", value != ".." else { return false }
    return !value.contains("/") && !value.contains("\\")
}

private func validOpaqueCursor(_ value: String) -> Bool {
    validReference(value, limit: 4_096)
}
