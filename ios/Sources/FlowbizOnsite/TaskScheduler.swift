import Foundation

protocol ScheduledHandle {
    func cancel()
}

// Must be serial: EventQueue and DedupStore rely on it instead of locks.
protocol TaskScheduler {
    func execute(_ task: @escaping @Sendable () -> Void)

    func schedule(afterMillis: Int64, _ task: @escaping @Sendable () -> Void) -> any ScheduledHandle

    // First fires one full interval after scheduling, like the web pagePingDelay.
    func scheduleRepeating(intervalMillis: Int64, _ task: @escaping @Sendable () -> Void) -> any ScheduledHandle
}

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
