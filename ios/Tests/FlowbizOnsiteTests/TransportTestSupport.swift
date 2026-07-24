// Test doubles for the Slice 3 transport components: a manually-driven
// TaskScheduler (the test *is* the serial queue) and a scripted HttpSender.
import Foundation
@testable import FlowbizOnsite

/// Manually-driven `TaskScheduler`: `execute` runs inline, delayed/repeating
/// tasks are recorded for the test to fire explicitly. `allScheduleDelays`
/// is the backoff-sequence probe.
final class FakeTaskScheduler: TaskScheduler, @unchecked Sendable {

    final class FakeHandle: ScheduledHandle, @unchecked Sendable {
        let delayMillis: Int64
        let task: @Sendable () -> Void
        let repeating: Bool
        var cancelled = false

        init(delayMillis: Int64, task: @escaping @Sendable () -> Void, repeating: Bool) {
            self.delayMillis = delayMillis
            self.task = task
            self.repeating = repeating
        }

        func cancel() { cancelled = true }
    }

    var scheduled: [FakeHandle] = []

    /// Every `schedule()` delay in call order, including later-cancelled ones.
    var allScheduleDelays: [Int64] {
        scheduled.filter { !$0.repeating }.map(\.delayMillis)
    }

    func execute(_ task: @escaping @Sendable () -> Void) {
        task()
    }

    func schedule(afterMillis: Int64, _ task: @escaping @Sendable () -> Void) -> any ScheduledHandle {
        let handle = FakeHandle(delayMillis: afterMillis, task: task, repeating: false)
        scheduled.append(handle)
        return handle
    }

    func scheduleRepeating(intervalMillis: Int64, _ task: @escaping @Sendable () -> Void) -> any ScheduledHandle {
        let handle = FakeHandle(delayMillis: intervalMillis, task: task, repeating: true)
        scheduled.append(handle)
        return handle
    }

    /// Fires the most recently scheduled, still-pending one-shot task.
    func runLastScheduled() {
        scheduled.last { !$0.repeating && !$0.cancelled }!.task()
    }

    /// The live repeating task (heartbeat), or nil.
    func activeRepeating() -> FakeHandle? {
        scheduled.last { $0.repeating && !$0.cancelled }
    }

    /// Fires the live repeating task `times` beats.
    func tickRepeating(_ times: Int = 1) {
        let handle = activeRepeating()!
        for _ in 0..<times { handle.task() }
    }
}

/// Scripted `HttpSender`: captures every body, answers from `results` (then
/// `defaultResult`), or via `resultFor` when set. `maxDepth` detects
/// nested/concurrent sends; `onSend` lets tests trigger re-entrancy.
final class FakeHttpSender: HttpSender, @unchecked Sendable {

    var bodies: [String] = []
    var results: [SendResult] = []
    var defaultResult: SendResult = .success
    var resultFor: ((String) -> SendResult)?
    var onSend: ((String) -> Void)?

    private var depth = 0
    private(set) var maxDepth = 0

    func send(body: String) -> SendResult {
        depth += 1
        maxDepth = max(maxDepth, depth)
        defer { depth -= 1 }
        bodies.append(body)
        onSend?(body)
        if let resultFor { return resultFor(body) }
        return results.isEmpty ? defaultResult : results.removeFirst()
    }
}

/// Fresh temp directory per test; caller never cleans up (the OS temp dir is
/// reaped by the system, and tests must not fail on cleanup races).
func temporaryQueueFile() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("flowbiz-tests-\(UUID().uuidString)", isDirectory: true)
    return directory.appendingPathComponent("queue.jsonl")
}
