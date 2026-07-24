// SPEC §9 response classification through URLProtocol-stubbed URLSession
// plus the pure classify(status:) table. Also pins the wire mechanics:
// POST to /collect, JSON content type, platform header, body passthrough,
// redirects refused.
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

/// Global script/recording state for `StubURLProtocol` (URLProtocol offers
/// no injection point). Lock-guarded; the suite is `.serialized` because
/// this state is shared.
final class HttpStubScript: @unchecked Sendable {

    static let shared = HttpStubScript()

    private let lock = NSLock()
    private var status = 200
    private var headers: [String: String] = [:]
    private var error: Error?

    private var method: String?
    private var path: String?
    private var contentType: String?
    private var platform: String?
    private var body: String?

    func configure(status: Int, headers: [String: String] = [:], error: Error? = nil) {
        lock.lock()
        defer { lock.unlock() }
        self.status = status
        self.headers = headers
        self.error = error
        method = nil
        path = nil
        contentType = nil
        platform = nil
        body = nil
    }

    func script() -> (status: Int, headers: [String: String], error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (status, headers, error)
    }

    func record(request: URLRequest, body bodyData: Data) {
        lock.lock()
        defer { lock.unlock() }
        method = request.httpMethod
        path = request.url?.path
        contentType = request.value(forHTTPHeaderField: "Content-Type")
        platform = request.value(forHTTPHeaderField: "platform")
        body = String(decoding: bodyData, as: UTF8.self)
    }

    func recorded() -> (method: String?, path: String?, contentType: String?, platform: String?, body: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (method, path, contentType, platform, body)
    }
}

final class StubURLProtocol: URLProtocol {

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let shared = HttpStubScript.shared
        shared.record(request: request, body: bodyData())
        let script = shared.script()
        if let error = script.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: script.status,
            httpVersion: "HTTP/1.1",
            headerFields: script.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func bodyData() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }
}

@Suite(.serialized) struct HttpSenderSuite {

    private func sender(collectorUrl: String = "https://collector.example") -> URLSessionHttpSender {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSessionHttpSender(collectorUrl: collectorUrl, platform: "ios", configuration: configuration)
    }

    // MARK: Wire mechanics

    @Test func postsJsonBodyWithPlatformHeaderToCollectPath() {
        HttpStubScript.shared.configure(status: 200)
        // Trailing slash on the configured URL must not double up.
        let result = sender(collectorUrl: "https://collector.example/").send(body: "{\"data\":[{\"event\":\"e1\"}]}")
        #expect(result == .success)
        let recorded = HttpStubScript.shared.recorded()
        #expect(recorded.method == "POST")
        #expect(recorded.path == "/collect")
        #expect(recorded.contentType == "application/json")
        #expect(recorded.platform == "ios")
        #expect(recorded.body == "{\"data\":[{\"event\":\"e1\"}]}")
    }

    // MARK: Stubbed-session classification

    @Test func http200IsSuccess() {
        HttpStubScript.shared.configure(status: 200)
        #expect(sender().send(body: "{\"data\":[]}") == .success)
    }

    @Test func http204IsSuccess() {
        HttpStubScript.shared.configure(status: 204)
        #expect(sender().send(body: "{\"data\":[]}") == .success)
    }

    @Test func http302IsPermanentAndNotFollowed() {
        // A Location header engages URLSession's redirect path; the sender's
        // delegate must refuse it so the 302 itself is classified.
        HttpStubScript.shared.configure(status: 302, headers: ["Location": "https://elsewhere.example/x"])
        #expect(sender().send(body: "{\"data\":[]}") == .permanentError)
        #expect(HttpStubScript.shared.recorded().path == "/collect")
    }

    @Test func http400IsPermanent() {
        HttpStubScript.shared.configure(status: 400)
        #expect(sender().send(body: "{\"data\":[]}") == .permanentError)
    }

    @Test func http408IsRetriable() {
        HttpStubScript.shared.configure(status: 408)
        #expect(sender().send(body: "{\"data\":[]}") == .retriableError)
    }

    @Test func http413IsPayloadTooLarge() {
        HttpStubScript.shared.configure(status: 413)
        #expect(sender().send(body: "{\"data\":[]}") == .payloadTooLarge)
    }

    @Test func http429IsRetriable() {
        HttpStubScript.shared.configure(status: 429)
        #expect(sender().send(body: "{\"data\":[]}") == .retriableError)
    }

    @Test func http500IsRetriable() {
        HttpStubScript.shared.configure(status: 500)
        #expect(sender().send(body: "{\"data\":[]}") == .retriableError)
    }

    @Test func transportErrorIsRetriable() {
        HttpStubScript.shared.configure(status: 200, error: URLError(.notConnectedToInternet))
        #expect(sender().send(body: "{\"data\":[]}") == .retriableError)
    }

    @Test func malformedCollectorUrlIsPermanent() {
        HttpStubScript.shared.configure(status: 200)
        #expect(sender(collectorUrl: "not a url").send(body: "{}") == .permanentError)
        #expect(sender(collectorUrl: "nonsense://::bad::").send(body: "{}") == .permanentError)
    }

    // MARK: Pure classification table (SPEC §9)

    @Test func classificationTable() {
        let cases: [(Int, SendResult)] = [
            (200, .success),
            (201, .success),
            (204, .success),
            (299, .success),
            (301, .permanentError),
            (302, .permanentError),
            (308, .permanentError),
            (400, .permanentError),
            (401, .permanentError),
            (403, .permanentError),
            (404, .permanentError),
            (408, .retriableError),
            (410, .permanentError),
            (413, .payloadTooLarge),
            (422, .permanentError),
            (429, .retriableError),
            (500, .retriableError),
            (502, .retriableError),
            (503, .retriableError),
            (599, .retriableError),
            (100, .retriableError), // unexpected → keep and retry
            (-1, .retriableError),
        ]
        for (status, expected) in cases {
            #expect(URLSessionHttpSender.classify(status: status) == expected, "status \(status)")
        }
    }
}
#endif
