import Foundation
import XCTest
@testable import MoaOpsCore

final class PulseTransportLifecycleTests: XCTestCase {
    func testDevicePulseRequestNeverUsesCookieBootstrapOrLegacyTokenQuery() async throws {
        let recorder = PulseRequestRecorder()
        PulseURLProtocol.handler = { request in
            recorder.record(request)
            let body = #"{"generated_at":"2026-07-12T12:00:00Z","summary":{"needs_attention":0,"in_progress":0,"stale_work":0,"on_track":0,"changes":0},"needs_attention":[],"in_progress":[],"stale_work":[],"on_track":[],"changes":{"requested":false,"until":"2026-07-12T12:00:00Z","items":[],"next_cursor":"cursor","has_more":false}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { PulseURLProtocol.handler = nil }
        let registration = try PulseDeviceRegistration(baseURL: URL(string: "https://moa.example")!, deviceID: "device", credential: "device.secret", expiresAt: .distantFuture)
        let session = pulseSession()
        defer { session.invalidateAndCancel() }
        let client = try MoaPulseDeviceClient(registration: registration, session: session)
        _ = try await client.pulse()
        let request = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(request.url?.path, "/api/ops/pulse")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Moa-Device device.secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }
}

private final class PulseRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func record(_ request: URLRequest) { lock.lock(); values.append(request); lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class PulseURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func pulseSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PulseURLProtocol.self]
    return URLSession(configuration: configuration)
}
