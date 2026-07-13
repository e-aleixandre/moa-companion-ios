@preconcurrency import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Security)
import Security
#endif

public enum PulseCallError: Error, Equatable, Sendable {
    case invalidServerURL
    case insecureTransport
    case invalidPairingPayload
    case invalidCredential
    case invalidResponse
    case decoding
    case transport
    case authentication
    case httpStatus(code: Int, retryAfter: TimeInterval?)
    case secureStorageUnavailable
    case operationUnavailable
}

/// Pulse accepts plaintext only for a direct loopback Serve connection. This
/// mirrors Serve's device-transport boundary instead of treating a hostname as
/// proof that a remote connection is safe.
public struct PulseServerConfiguration: Codable, Equatable, Sendable {
    public let baseURL: URL

    public init(urlText: String) throws {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let url = components.url,
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw PulseCallError.invalidServerURL
        }
        guard scheme == "https" || Self.isLoopback(host) else {
            throw PulseCallError.insecureTransport
        }
        baseURL = url
    }

    public init(baseURL: URL) throws {
        try self.init(urlText: baseURL.absoluteString)
    }

    public static func isLoopback(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "localhost" || normalized == "::1" || normalized == "[::1]" { return true }

        // `inet_pton` accepts only a complete dotted-quad here. In particular,
        // hostnames such as `127.evil.example` or `127.0.0.1.evil` cannot
        // enter the HTTP loopback exception merely by sharing a prefix.
        var address = in_addr()
        guard normalized.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return false }
        let hostOrder = UInt32(bigEndian: address.s_addr)
        return (hostOrder & 0xFF00_0000) == 0x7F00_0000
    }
}

public struct PulsePairingPayload: Equatable, Sendable {
    public let pairingID: String
    public let secret: String

    public init(parsing value: String) throws {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "moa-pair-v1",
              !parts[1].isEmpty,
              !parts[2].isEmpty,
              parts[1].count <= 128,
              parts[2].count <= 128,
              !parts[1].contains(where: { $0.isWhitespace }),
              !parts[2].contains(where: { $0.isWhitespace }),
              !parts[1].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !parts[2].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PulseCallError.invalidPairingPayload
        }
        pairingID = String(parts[1])
        secret = String(parts[2])
    }
}

public struct PulseDeviceRegistration: Codable, Equatable, Sendable {
    public let baseURL: URL
    public let deviceID: String
    public let credential: String
    public let expiresAt: Date

    public init(baseURL: URL, deviceID: String, credential: String, expiresAt: Date) throws {
        _ = try PulseServerConfiguration(baseURL: baseURL)
        guard !deviceID.isEmpty,
              credential.hasPrefix(deviceID + "."),
              credential.count > deviceID.count + 1 else {
            throw PulseCallError.invalidCredential
        }
        self.baseURL = baseURL
        self.deviceID = deviceID
        self.credential = credential
        self.expiresAt = expiresAt
    }
}

public protocol PulseSecureStore: Sendable {
    func loadDeviceRegistration() throws -> PulseDeviceRegistration?
    func saveDeviceRegistration(_ registration: PulseDeviceRegistration) throws
    func clearDeviceRegistration() throws
}

enum PulseDeviceRegistrationCodec {
    static func encode(_ registration: PulseDeviceRegistration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(registration)
    }

    static func decode(_ data: Data) throws -> PulseDeviceRegistration {
        try JSONDecoder.moaOps.decode(PulseDeviceRegistration.self, from: data)
    }
}

/// The only durable local storage used by Call Moa. Pairing payloads are never
/// accepted here, so a one-use pairing secret cannot accidentally be retained.
public final class KeychainPulseSecureStore: PulseSecureStore, @unchecked Sendable {
    private let service: String
    private let deviceAccount = "pulse.device.registration.v1"
    static let obsoleteOpenAIAPIKeyAccount = "pulse.openai.api-key.v1"

    /// Deletes the legacy standard-key entry without ever reading it. The
    /// injected deleter is solely a test seam; failure is intentionally best
    /// effort so a stale entry cannot block paired-device startup.
    public convenience init(service: String = "com.ealeixandre.moa-companion.pulse") {
        self.init(service: service, legacyKeyDeletion: Self.deleteLegacyAPIKey)
    }

    init(service: String, legacyKeyDeletion: (String, String) -> Void) {
        self.service = service
        legacyKeyDeletion(service, Self.obsoleteOpenAIAPIKeyAccount)
    }

    public func loadDeviceRegistration() throws -> PulseDeviceRegistration? {
        guard let data = try load(account: deviceAccount) else { return nil }
        do {
            return try PulseDeviceRegistrationCodec.decode(data)
        } catch {
            throw PulseCallError.secureStorageUnavailable
        }
    }

    public func saveDeviceRegistration(_ registration: PulseDeviceRegistration) throws {
        try save(try PulseDeviceRegistrationCodec.encode(registration), account: deviceAccount)
    }

    public func clearDeviceRegistration() throws { try clear(account: deviceAccount) }

    private func load(account: String) throws -> Data? {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PulseCallError.secureStorageUnavailable }
        return data
#else
        throw PulseCallError.secureStorageUnavailable
#endif
    }

    private func save(_ data: Data, account: String) throws {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        var attributes: [CFString: Any] = [kSecValueData: data]
#if os(iOS)
        attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
#endif
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var add = query
            for (key, value) in attributes { add[key] = value }
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw PulseCallError.secureStorageUnavailable }
        } else if update != errSecSuccess {
            throw PulseCallError.secureStorageUnavailable
        }
#else
        throw PulseCallError.secureStorageUnavailable
#endif
    }

    private func clear(account: String) throws {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PulseCallError.secureStorageUnavailable }
#else
        throw PulseCallError.secureStorageUnavailable
#endif
    }

    private static func deleteLegacyAPIKey(service: String, account: String) {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        _ = SecItemDelete(query as CFDictionary)
#endif
    }
}

public struct PulseDeviceClaimRequest: Encodable, Equatable, Sendable {
    public let pairingID: String
    public let pairingSecret: String
    public let deviceLabel: String

    enum CodingKeys: String, CodingKey {
        case pairingID = "pairing_id"
        case pairingSecret = "pairing_secret"
        case deviceLabel = "device_label"
    }
}

private struct PulseDeviceClaimResponse: Decodable {
    let deviceID: String
    let credential: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case credential
        case expiresAt = "expires_at"
    }
}

/// Claim transport is deliberately separate from device transport: it is the
/// sole unauthenticated Pulse request and it only sees the one-use payload.
public struct PulsePairingClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = PulseTransportFactory.ephemeralSession()) {
        self.session = session
    }

    public func claim(configuration: PulseServerConfiguration, payload: PulsePairingPayload, deviceLabel: String) async throws -> PulseDeviceRegistration {
        let label = deviceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 80, !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PulseCallError.invalidPairingPayload
        }
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("api/pulse/pairings/claim"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Moa-Request")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        request.httpBody = try JSONEncoder.moaOps.encode(PulseDeviceClaimRequest(pairingID: payload.pairingID, pairingSecret: payload.secret, deviceLabel: label))
        let (data, response) = try await perform(request, session: session)
        guard let http = response as? HTTPURLResponse else { throw PulseCallError.invalidResponse }
        try validate(http)
        do {
            let claimed = try JSONDecoder.moaOps.decode(PulseDeviceClaimResponse.self, from: data)
            return try PulseDeviceRegistration(baseURL: configuration.baseURL, deviceID: claimed.deviceID, credential: claimed.credential, expiresAt: claimed.expiresAt)
        } catch let error as PulseCallError {
            throw error
        } catch {
            throw PulseCallError.decoding
        }
    }
}

public enum PulseTransportFactory {
    public static func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }
}

func perform(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
    do {
        return try await session.data(for: request)
    } catch {
        throw PulseCallError.transport
    }
}

func validate(_ response: HTTPURLResponse) throws {
    guard (200..<300).contains(response.statusCode) else {
        throw PulseCallError.httpStatus(code: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
    }
}
