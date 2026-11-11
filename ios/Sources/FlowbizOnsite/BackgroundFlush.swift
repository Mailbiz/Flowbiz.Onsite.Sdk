import Foundation

// Holds an OS background task for one flush: iOS suspends the app seconds after it leaves the foreground.
enum BackgroundFlush {

    /// Runs `flush` inside an OS background task; `flush` reports when it is over.
    typealias Runner = @Sendable (_ flush: @escaping @Sendable (_ finished: @escaping @Sendable () -> Void) -> Void) -> Void

    /// `begin` starts the task and returns how to end it, or nil when iOS grants none (the flush still runs).
    /// The task is ended once: when the flush reports, or when iOS calls time through `onExpire`.
    static func run(
        begin: (_ onExpire: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)?,
        flush: (_ finished: @escaping @Sendable () -> Void) -> Void
    ) {
        let task = EndOnce()
        task.set(end: begin { task.finish() })
        flush { task.finish() }
    }

    private final class EndOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var end: (@Sendable () -> Void)?
        private var finished = false

        func set(end: (@Sendable () -> Void)?) {
            lock.lock()
            let alreadyFinished = finished
            if !alreadyFinished { self.end = end }
            lock.unlock()
            if alreadyFinished { end?() }
        }

        func finish() {
            lock.lock()
            let end = self.end
            self.end = nil
            finished = true
            lock.unlock()
            end?()
        }
    }
}
