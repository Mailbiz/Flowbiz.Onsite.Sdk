import Foundation

/// Batch-level: the collector accepts or rejects the whole request.
enum SendResult: Equatable, Sendable {
    case success
    case retriableError
    case permanentError
    case payloadTooLarge
}

/// Blocking by design: only ever called on the SDK's serial queue, never the
/// caller's thread.
protocol HttpSender {
    func send(body: String) -> SendResult
}

/// `URLSession` has no connect timeout (Android: 5 s connect, 10 s read), and
/// `timeoutIntervalForRequest` is an idle timeout that resets on every byte,
/// so the 30 s semaphore wait in `send` is the hard cap. A malformed
/// `collectorUrl` fails every send permanently, so the queue cannot grow
/// forever.
final class URLSessionHttpSender: NSObject, HttpSender, URLSessionTaskDelegate, @unchecked Sendable {

    static let requestTimeoutSeconds: TimeInterval = 10

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: SendResult = .retriableError

        var value: SendResult {
            get {
                lock.lock()
                defer { lock.unlock() }
                return result
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                result = newValue
            }
        }
    }

    private let endpoint: URL?
    private let platform: String
    private var session: URLSession!

    /// Ephemeral by default: no cookies or cache shared with the host app.
    init(collectorUrl: String, platform: String, configuration: URLSessionConfiguration = .ephemeral) {
        var base = collectorUrl
        while base.hasSuffix("/") { base.removeLast() }
        // URL(string:) is lenient; require a scheme + host so garbage cannot
        // masquerade as an endpoint.
        if let url = URL(string: base + "/collect"), url.scheme != nil, url.host != nil {
            self.endpoint = url
        } else {
            SdkLog.debug("invalid collector URL")
            self.endpoint = nil
        }
        self.platform = platform
        super.init()
        configuration.timeoutIntervalForRequest = Self.requestTimeoutSeconds
        // The session retains its delegate (self): fine, the sender lives as
        // long as the SDK.
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func send(body: String) -> SendResult {
        guard let endpoint else { return .permanentError }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(platform, forHTTPHeaderField: "platform")
        request.timeoutInterval = Self.requestTimeoutSeconds

        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { _, response, error in
            if error != nil {
                box.value = .retriableError
            } else if let http = response as? HTTPURLResponse {
                box.value = Self.classify(status: http.statusCode)
            } else {
                box.value = .retriableError
            }
            semaphore.signal()
        }
        task.resume()
        // Safety net well beyond the request timeout: the semaphore must
        // never wedge the SDK queue.
        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            task.cancel()
            SdkLog.debug("collect POST wedged; cancelled")
            return .retriableError
        }
        return box.value
    }

    /// Refuse redirects so the 3xx is delivered and classified honestly.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    static func classify(status: Int) -> SendResult {
        switch status {
        case 200...299: return .success
        case 300...399: return .permanentError // misconfigured collector; retries would loop
        case 413: return .payloadTooLarge
        case 408, 429: return .retriableError
        case 400...499: return .permanentError
        default: return .retriableError // 5xx and anything unexpected
        }
    }
}
