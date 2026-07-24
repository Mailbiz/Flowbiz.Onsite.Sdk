import Foundation

/// Outcome of one `POST /collect` attempt, per the SPEC §9 response table.
/// Batch-level: the collector accepts or rejects the whole request.
enum SendResult: Equatable, Sendable {
    /// 2xx — the batch was ingested; dequeue it.
    case success

    /// 5xx / 408 / 429 / timeout / network error — keep queued, back off.
    case retriableError

    /// 4xx (except 408/429/413) and 3xx — retrying cannot help; drop (after bisection).
    case permanentError

    /// 413 — the batch is too large; split and retry the halves.
    case payloadTooLarge
}

/// Transport seam: posts one already-serialized `{"data":[...]}` body.
/// Implementations never throw; every failure maps to a `SendResult`
/// (SPEC §3). Blocking by design — always called on the SDK's serial
/// scheduler queue, never the caller's thread (SPEC §3), so the
/// synchronous-style wait is off-main by construction.
protocol HttpSender {
    func send(body: String) -> SendResult
}

/// Production `HttpSender` over `URLSession` (SPEC §1): POST
/// `{collectorUrl}/collect`, `Content-Type: application/json`, `platform`
/// header.
///
/// Timeouts: `URLSession` has no separate connect timeout, so SPEC §9's 5 s
/// connect timeout is subsumed by a 10 s request timeout (documented
/// deviation; Android sets 5 s connect / 10 s read explicitly).
///
/// Redirects are **refused** via the task delegate so a 3xx response is
/// observed as-is. Classification (SPEC §9), see `classify(status:)`:
/// - 2xx → `.success`
/// - **3xx → `.permanentError`** — SPEC only says 3xx is "not success". A
///   redirecting collector URL is a misconfiguration that retrying can never
///   fix; retriable would loop the batch forever. Deliberate, flagged for
///   review.
/// - 413 → `.payloadTooLarge`
/// - 408/429 → `.retriableError`
/// - other 4xx → `.permanentError`
/// - 5xx, unrecognized codes, timeouts, transport errors → `.retriableError`
///
/// A malformed `collectorUrl` makes every send `.permanentError` (nothing
/// can ever be delivered; the queue must not grow forever). Config
/// validation proper happens in Slice 4.
final class URLSessionHttpSender: NSObject, HttpSender, URLSessionTaskDelegate, @unchecked Sendable {

    /// Whole-request timeout (subsumes SPEC §9's 5 s connect timeout).
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

    /// - Parameter configuration: injectable for tests (`URLProtocol` stubs);
    ///   defaults to an ephemeral session (no shared cookie/cache state).
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
        // Session retains its delegate (self) — intentional: the sender
        // lives for the SDK's lifetime (singleton facade, Slice 4).
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
        // never wedge the SDK queue (SPEC §3).
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

    /// Status-code → `SendResult` mapping (SPEC §9 table); pure, test-pinned.
    static func classify(status: Int) -> SendResult {
        switch status {
        case 200...299: return .success
        case 300...399: return .permanentError // misconfig; see class doc
        case 413: return .payloadTooLarge
        case 408, 429: return .retriableError
        case 400...499: return .permanentError
        default: return .retriableError // 5xx and anything unexpected
        }
    }
}
