import Foundation

enum SendResult: Equatable, Sendable {
    case success
    case retriableError
    case permanentError
    case payloadTooLarge
}

// Blocking by design: only ever called on the SDK's serial queue, never the caller's thread.
protocol HttpSender {
    func send(body: String) -> SendResult
}

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

    init(collectorUrl: String, platform: String, configuration: URLSessionConfiguration = .ephemeral) {
        var base = collectorUrl
        while base.hasSuffix("/") { base.removeLast() }
        if let url = URL(string: base + "/collect"), url.scheme != nil, url.host != nil {
            self.endpoint = url
        } else {
            SdkLog.debug("invalid collector URL")
            self.endpoint = nil
        }
        self.platform = platform
        super.init()
        configuration.timeoutIntervalForRequest = Self.requestTimeoutSeconds
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func send(body: String) -> SendResult {
        // Permanent, so a malformed collectorUrl cannot grow the queue forever.
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
        // The hard cap: URLSession has no connect timeout and its request timeout resets on every byte.
        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            task.cancel()
            SdkLog.debug("collect POST wedged; cancelled")
            return .retriableError
        }
        return box.value
    }

    // Refuses redirects so the 3xx reaches classify.
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
        default: return .retriableError
        }
    }
}
