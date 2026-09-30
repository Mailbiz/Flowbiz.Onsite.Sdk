import Foundation

// Never log PII: counts, codes and reasons only.
enum SdkLog {

    private final class SinkBox: @unchecked Sendable {
        private let lock = NSLock()
        private var sink: (@Sendable (String) -> Void)?

        var value: (@Sendable (String) -> Void)? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return sink
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                sink = newValue
            }
        }
    }

    private static let box = SinkBox()

    static var sink: (@Sendable (String) -> Void)? {
        get { box.value }
        set { box.value = newValue }
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard let sink else { return }
        sink(message())
    }
}
