#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct FlushControllerGateSuite {

    private final class ActiveBox: @unchecked Sendable {
        var value = true
    }

    private func entry(_ n: Int) -> String {
        "{\"event\":\"e\(n)\",\"hash\":\"h\(n)\"}"
    }

    @Test func gateBlocksDirectRequestsScheduledRetriesAndSchedulesNothingFurther() {
        let sender = FakeHttpSender()
        let scheduler = FakeTaskScheduler()
        let queue = EventQueue(fileURL: temporaryQueueFile())
        let active = ActiveBox()
        let controller = FlushController(
            queue: queue,
            sender: sender,
            scheduler: scheduler,
            clock: FakeClock(),
            isActive: { active.value }
        )
        queue.append(entry(1))
        sender.results = [.retriableError]
        controller.requestFlush(.eventTracked)
        #expect(sender.bodies.count == 1)

        active.value = false
        let scheduledBefore = scheduler.scheduled.count
        scheduler.runLastScheduled()
        #expect(sender.bodies.count == 1)
        #expect(scheduler.scheduled.count == scheduledBefore)

        controller.requestFlush(.explicit)
        #expect(sender.bodies.count == 1)
        #expect(queue.size == 1)

        active.value = true
        controller.requestFlush(.explicit)
        #expect(sender.bodies.count == 2)
        #expect(queue.size == 0)
    }

    @Test func disablingMidDrainStopsBeforeTheNextBatch() {
        let sender = FakeHttpSender()
        let scheduler = FakeTaskScheduler()
        let queue = EventQueue(fileURL: temporaryQueueFile())
        let active = ActiveBox()
        let controller = FlushController(
            queue: queue, sender: sender, scheduler: scheduler, clock: FakeClock(), batchSize: 2,
            isActive: { active.value }
        )
        (1...5).forEach { queue.append(entry($0)) }
        sender.onSend = { _ in active.value = false } // setEnabled(false) lands while the first POST is out
        controller.requestFlush(.eventTracked)

        #expect(sender.bodies.count == 1)
        #expect(queue.size == 3)
        #expect(scheduler.allScheduleDelays.isEmpty)
    }

    private final class DeferringScheduler: TaskScheduler, @unchecked Sendable {
        var waiting: [@Sendable () -> Void] = []
        let fake = FakeTaskScheduler()

        func execute(_ task: @escaping @Sendable () -> Void) { waiting.append(task) }
        func schedule(afterMillis: Int64, _ task: @escaping @Sendable () -> Void) -> any ScheduledHandle {
            fake.schedule(afterMillis: afterMillis, task)
        }
        func scheduleRepeating(intervalMillis: Int64, _ task: @escaping @Sendable () -> Void) -> any ScheduledHandle {
            fake.scheduleRepeating(intervalMillis: intervalMillis, task)
        }
    }

    @Test func triggersThatArriveWhileADrainWaitsShareIt() {
        let sender = FakeHttpSender()
        let deferring = DeferringScheduler()
        let queue = EventQueue(fileURL: temporaryQueueFile())
        let controller = FlushController(queue: queue, sender: sender, scheduler: deferring, clock: FakeClock())
        queue.append(entry(1))
        for _ in 0..<3 { controller.requestFlush(.eventTracked) }
        #expect(deferring.waiting.count == 1)

        deferring.waiting.removeFirst()()
        #expect(sender.bodies.count == 1)
        queue.append(entry(2))
        controller.requestFlush(.eventTracked)
        #expect(deferring.waiting.count == 1)
        deferring.waiting.removeFirst()()
        #expect(queue.size == 0)
    }

    @Test func drainsRetriesAndSettlesOnARealSerialDispatchQueue() {
        let serialQueue = DispatchQueue(label: "br.com.flowbiz.onsite.tests")
        let scheduler = DispatchTaskScheduler(queue: serialQueue)
        let queue = EventQueue(fileURL: temporaryQueueFile())
        let sender = FakeHttpSender()
        let sendsSeen = DispatchSemaphore(value: 0)

        serialQueue.sync {
            queue.append(self.entry(1))
            queue.append(self.entry(2))
            sender.results = [.retriableError]
            sender.onSend = { _ in sendsSeen.signal() }
        }

        let controller = FlushController(queue: queue, sender: sender, scheduler: scheduler, clock: FakeClock())
        controller.requestFlush(.eventTracked)

        #expect(sendsSeen.wait(timeout: .now() + 5) == .success)
        #expect(sendsSeen.wait(timeout: .now() + 5) == .success)

        // Serialize behind the in-flight drain to read settled state.
        let (size, bodies) = serialQueue.sync { (queue.size, sender.bodies) }
        #expect(size == 0)
        #expect(bodies.count == 2)
        #expect(bodies.allSatisfy { $0.contains("\"hash\":\"h1\"") && $0.contains("\"hash\":\"h2\"") })
    }
}
#endif
