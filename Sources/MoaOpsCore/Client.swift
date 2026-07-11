@preconcurrency import Foundation

public enum MoaOpsClientError: Error, Equatable, Sendable {
    case invalidBaseURL
    case invalidResponse
    case httpStatus(code: Int, retryAfter: TimeInterval?)
    case instructionConflict(candidates: [OpsInstructionTarget])
    case decoding
    case transport
    case authentication
}

public protocol MoaOpsAuthenticationBootstrap: Sendable {
    func bootstrap(using session: URLSession, baseURL: URL) async throws
}

/// Establishes the server's normal cookie session from a host-supplied token.
/// The token is retained only by this value; this package does not persist it.
public struct CookieTokenBootstrap: MoaOpsAuthenticationBootstrap {
    public let token: String
    public let path: String

    public init(token: String, path: String = "/") {
        self.token = token
        self.path = path
    }

    public func bootstrap(using session: URLSession, baseURL: URL) async throws {
        let endpoint = path == "/" ? baseURL : baseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw MoaOpsClientError.invalidBaseURL
        }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { throw MoaOpsClientError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MoaOpsClientError.invalidResponse }
        guard (200..<400).contains(response.statusCode) else { throw MoaOpsClientError.authentication }
    }
}

public actor MoaOpsClient {
    public let baseURL: URL
    private let session: URLSession
    private let authentication: (any MoaOpsAuthenticationBootstrap)?
    private var hasBootstrapped = false

    public init(baseURL: URL, session: URLSession = .shared, authentication: (any MoaOpsAuthenticationBootstrap)? = nil) throws {
        guard baseURL.scheme == "http" || baseURL.scheme == "https", baseURL.host != nil else {
            throw MoaOpsClientError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.session = session
        self.authentication = authentication
    }

    public func overview() async throws -> OpsSnapshot {
        try await get(path: "api/ops/overview", as: OpsSnapshot.self)
    }

    public func sitrep() async throws -> OpsBriefing {
        try await query(view: "sitrep", target: nil, as: OpsBriefing.self)
    }

    public func blockers() async throws -> OpsBriefing {
        try await query(view: "blockers", target: nil, as: OpsBriefing.self)
    }

    public func status(target: String) async throws -> OpsStatusResult {
        try await query(view: "status", target: target, as: OpsStatusResult.self)
    }

    public func submitInstruction(_ instruction: OpsInstructionRequest) async throws -> OpsInstructionResponse {
        try await ensureAuthenticated()
        var request = try makeRequest(path: "api/ops/instruction")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(instruction.requestID, forHTTPHeaderField: "X-Request-ID")
        request.httpBody = try JSONEncoder.moaOps.encode(instruction)
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MoaOpsClientError.invalidResponse }
        if http.statusCode == 409, let conflict = try? JSONDecoder.moaOps.decode(OpsInstructionConflict.self, from: data) {
            throw MoaOpsClientError.instructionConflict(candidates: conflict.candidates)
        }
        try validate(http)
        return try decode(OpsInstructionResponse.self, from: data)
    }

    private func query<T: Decodable>(view: String, target: String?, as type: T.Type) async throws -> T {
        var components = URLComponents(url: try endpoint(path: "api/ops"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "view", value: view)]
        if let target { items.append(URLQueryItem(name: "target", value: target)) }
        components?.queryItems = items
        guard let url = components?.url else { throw MoaOpsClientError.invalidBaseURL }
        return try await get(url: url, as: type)
    }

    private func get<T: Decodable>(path: String, as type: T.Type) async throws -> T {
        try await get(url: endpoint(path: path), as: type)
    }

    private func get<T: Decodable>(url: URL, as type: T.Type) async throws -> T {
        try await ensureAuthenticated()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MoaOpsClientError.invalidResponse }
        try validate(http)
        return try decode(type, from: data)
    }

    private func ensureAuthenticated() async throws {
        guard !hasBootstrapped else { return }
        guard let authentication else {
            hasBootstrapped = true
            return
        }
        do {
            try await authentication.bootstrap(using: session, baseURL: baseURL)
            hasBootstrapped = true
        } catch let error as MoaOpsClientError {
            throw error
        } catch {
            throw MoaOpsClientError.authentication
        }
    }

    private func makeRequest(path: String) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(path: path))
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        return request
    }

    private func endpoint(path: String) throws -> URL {
        guard !path.hasPrefix("/"), let url = URL(string: path, relativeTo: baseURL.appendingPathComponent("/"))?.absoluteURL else {
            throw MoaOpsClientError.invalidBaseURL
        }
        return url
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw MoaOpsClientError.transport
        }
    }

    private func validate(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw MoaOpsClientError.httpStatus(code: response.statusCode, retryAfter: retryAfter)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder.moaOps.decode(type, from: data)
        } catch {
            throw MoaOpsClientError.decoding
        }
    }
}

extension JSONDecoder {
    static let moaOps: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.moaOpsFractional.date(from: value) ?? ISO8601DateFormatter.moaOps.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: decoder, debugDescription: "Expected an RFC 3339 timestamp")
        }
        return decoder
    }()
}

extension JSONEncoder {
    static let moaOps: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension ISO8601DateFormatter {
    static let moaOpsFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let moaOps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
