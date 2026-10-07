import Foundation
@testable import FlowbizOnsite

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

    func runLastScheduled() {
        scheduled.last { !$0.repeating && !$0.cancelled }!.task()
    }

    func activeRepeating() -> FakeHandle? {
        scheduled.last { $0.repeating && !$0.cancelled }
    }

    func tickRepeating(_ times: Int = 1) {
        let handle = activeRepeating()!
        for _ in 0..<times { handle.task() }
    }
}

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

func temporaryQueueFile() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("flowbiz-tests-\(UUID().uuidString)", isDirectory: true)
    return directory.appendingPathComponent("queue.jsonl")
}
