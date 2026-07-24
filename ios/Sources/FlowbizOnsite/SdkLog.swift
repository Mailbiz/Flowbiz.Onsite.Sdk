import Foundation

/// Minimal internal log seam. The transport components (queue, sender,
/// flusher) log through this; Slice 4 wires `sink` to `os_log`-style output
/// when `debug` is enabled — until then logging is a no-op.
///
/// Never throws/crashes: a misbehaving sink cannot break the SDK (SPEC §3).
/// Callers must never log PII (SPEC §12) — messages carry counts, codes and
/// reasons only.
enum SdkLog {

    /// Lock-guarded holder so the mutable sink is concurrency-safe shared
    /// state (warning-clean under strict concurrency).
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
