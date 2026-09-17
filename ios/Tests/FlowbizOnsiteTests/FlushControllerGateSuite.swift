// SPEC §12 network gate on `FlushController` (plus the Slice 3 warm-ups:
// one real-serial-queue integration pass and the backup-exclusion resource
// check on the default queue directory).
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
        #expect(sender.bodies.count == 1) // attempt 1 failed, retry scheduled

        active.value = false
        let scheduledBefore = scheduler.scheduled.count
        scheduler.runLastScheduled() // pending backoff retry fires → gated
        #expect(sender.bodies.count == 1)
        #expect(scheduler.scheduled.count == scheduledBefore) // no follow-up retry

        controller.requestFlush(.explicit) // gated too
        #expect(sender.bodies.count == 1)
        #expect(queue.size == 1) // backlog preserved, not dropped

        active.value = true
        controller.requestFlush(.explicit)
        #expect(sender.bodies.count == 2)
        #expect(queue.size == 0)
    }

    /// Slice 3 warm-up: one integration pass over the real
    /// `DispatchTaskScheduler` (serial `DispatchQueue`) — real asynchrony,
    /// real ~1 s backoff delay, real serial-queue confinement.
    @Test func drainsRetriesAndSettlesOnARealSerialDispatchQueue() {
        let serialQueue = DispatchQueue(label: "br.com.flowbiz.onsite.tests")
        let scheduler = DispatchTaskScheduler(queue: serialQueue)
        let queue = EventQueue(fileURL: temporaryQueueFile())
        let sender = FakeHttpSender()
        let sendsSeen = DispatchSemaphore(value: 0)

        serialQueue.sync {
            queue.append(self.entry(1))
            queue.append(self.entry(2))
            sender.results = [.retriableError] // first attempt fails → real backoff
            sender.onSend = { _ in sendsSeen.signal() }
        }

        let controller = FlushController(queue: queue, sender: sender, scheduler: scheduler, clock: FakeClock())
        controller.requestFlush(.eventTracked)

        #expect(sendsSeen.wait(timeout: .now() + 5) == .success) // failed attempt
        #expect(sendsSeen.wait(timeout: .now() + 5) == .success) // ~1 s backoff retry

        // Serialize behind the in-flight drain to read settled state.
        let (size, bodies) = serialQueue.sync { (queue.size, sender.bodies) }
        #expect(size == 0)
        #expect(bodies.count == 2)
        #expect(bodies.allSatisfy { $0.contains("\"hash\":\"h1\"") && $0.contains("\"hash\":\"h2\"") })
    }
}
#endif
