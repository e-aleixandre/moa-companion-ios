import Foundation
import XCTest
@testable import MoaOpsCore

final class PulseDeviceClientGenericTests: XCTestCase {
    func testSubagentListRouteReturnsTasks() async throws {
        let recorder = RequestRecorder()
        DeviceURLProtocol.handler = { request in
            recorder.record(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"session_id":"s1","subagents":[{"job_id":"job1","task":"restore task","status":"running","async":false,"source":"active"}]}"#.utf8))
        }
        defer { DeviceURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let registration = try PulseDeviceRegistration(baseURL: URL(string: "https://moa.example")!, deviceID: "device", credential: "device.secret", expiresAt: .distantFuture)
        let response = try await MoaPulseDeviceClient(registration: registration, session: session).listSubagents(sessionID: "s1")
        XCTAssertEqual(response.subagents.first?.task, "restore task")
        XCTAssertEqual(recorder.last?.url?.path, "/api/sessions/s1/subagents")
    }

    func testSubagentRouteUsesGenericSessionEndpointAndBoundedQuery() async throws {
        let recorder = RequestRecorder()
        DeviceURLProtocol.handler = { request in
            recorder.record(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"session_id":"s1","job_id":"job1","order":"newest_first","messages":[],"has_more":false}"#.utf8))
        }
        defer { DeviceURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let registration = try PulseDeviceRegistration(baseURL: URL(string: "https://moa.example")!, deviceID: "device", credential: "device.secret", expiresAt: .distantFuture)
        let page = try await MoaPulseDeviceClient(registration: registration, session: session).subagentMessages(sessionID: "s1", jobID: "job1", limit: 20, cursor: "opaque cursor")
        XCTAssertEqual(page.jobID, "job1")
        XCTAssertEqual(page.order, "newest_first")
        let request = try XCTUnwrap(recorder.last)
        XCTAssertEqual(request.url?.path, "/api/sessions/s1/subagents/job1")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "limit" }?.value, "20")
        XCTAssertEqual(query?.first { $0.name == "cursor" }?.value, "opaque cursor")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Moa-Device device.secret")
        do {
            _ = try await MoaPulseDeviceClient(registration: registration, session: session).subagentMessages(sessionID: "s1", jobID: "../job")
            XCTFail("unsafe job ID must not reach transport")
        } catch let error as PulseCallError {
            XCTAssertEqual(error, .operationUnavailable)
        }
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    func record(_ request: URLRequest) { lock.lock(); self.request = request; lock.unlock() }
    var last: URLRequest? { lock.lock(); defer { lock.unlock() }; return request }
}

private final class DeviceURLProtocol: URLProtocol {
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
