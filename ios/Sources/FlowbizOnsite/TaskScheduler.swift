import Foundation

/// Cancellable handle for a scheduled task. Cancelling twice is harmless.
protocol ScheduledHandle {
    func cancel()
}

/// The SDK's serial execution seam (SPEC §1: GCD). Everything the transport
/// layer does — queue I/O, HTTP, backoff retries, heartbeat ticks — runs
/// through one implementation backed by a **serial** `DispatchQueue`, so
/// queue and flush state are thread-confined without locking. Injected so
/// tests drive time and execution manually.
protocol TaskScheduler {
    /// Runs `task` on the serial queue as soon as possible.
    func execute(_ task: @escaping @Sendable () -> Void)

    /// Runs `task` on the serial queue after `afterMillis`.
    func schedule(afterMillis: Int64, _ task: @escaping @Sendable () -> Void) -> any ScheduledHandle

    /// Runs `task` on the serial queue every `intervalMillis`, first fire
    /// one full interval after scheduling.
    func scheduleRepeating(intervalMillis: Int64, _ task: @escaping @Sendable () -> Void) -> any ScheduledHandle
}

/// Production `TaskScheduler` over a serial `DispatchQueue` (Slice 4 owns
/// its creation/lifecycle). One-shot delays use `DispatchWorkItem` +
/// `asyncAfter`; the repeating heartbeat uses a `DispatchSourceTimer` on the
/// same queue (SPEC §8 timer choice).
final class DispatchTaskScheduler: TaskScheduler, @unchecked Sendable {

    private final class WorkItemHandle: ScheduledHandle, @unchecked Sendable {
        private let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    private final class TimerHandle: ScheduledHandle, @unchecked Sendable {
        private let timer: DispatchSourceTimer
        init(_ timer: DispatchSourceTimer) { self.timer = timer }
        func cancel() { timer.cancel() }
    }

    private let queue: DispatchQueue

    /// - Parameter queue: the SDK's **serial** queue.
    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func execute(_ task: @escaping @Sendable () -> Void) {
        queue.async(execute: task)
    }

    func schedule(afterMillis: Int64, _ task: @escaping @Sendable () -> Void) -> any ScheduledHandle {
        let item = DispatchWorkItem(block: task)
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(afterMillis)), execute: item)
        return WorkItemHandle(item)
    }

    func scheduleRepeating(intervalMillis: Int64, _ task: @escaping @Sendable () -> Void) -> any ScheduledHandle {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(Int(intervalMillis))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: task)
        timer.resume()
        return TimerHandle(timer)
    }
}
