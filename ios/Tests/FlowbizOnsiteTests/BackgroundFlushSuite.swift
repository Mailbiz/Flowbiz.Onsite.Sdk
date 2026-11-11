#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct BackgroundFlushSuite {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Callback: @unchecked Sendable {
        var run: (@Sendable () -> Void)?
    }

    private func queueOneOffline(_ h: CoreHarness) {
        h.sender.defaultResult = .retriableError
        h.core.track(.cartSetCoupon(cartId: "c-1", coupon: "last-before-leaving"))
        #expect(h.queue.size == 1)
    }

    // MARK: the OS background task around the flush

    @Test func theTaskEndsOnceWhenTheFlushFinishes() {
        let ended = Counter()
        let done = Callback()
        let expire = Callback()
        BackgroundFlush.run(
            begin: { onExpire in expire.run = onExpire; return { ended.increment() } },
            flush: { finished in done.run = finished }
        )
        #expect(ended.count == 0, "the task is held while the flush runs")
        done.run?()
        #expect(ended.count == 1)
        expire.run?()
        done.run?()
        #expect(ended.count == 1)
    }

    @Test func theTaskEndsOnceWhenIOSCallsTimeFirst() {
        let ended = Counter()
        let done = Callback()
        let expire = Callback()
        BackgroundFlush.run(
            begin: { onExpire in expire.run = onExpire; return { ended.increment() } },
            flush: { finished in done.run = finished }
        )
        expire.run?()
        #expect(ended.count == 1)
        done.run?()
        #expect(ended.count == 1)
    }

    @Test func aRefusedTaskStillFlushes() {
        let flushed = Counter()
        BackgroundFlush.run(begin: { _ in nil }, flush: { finished in flushed.increment(); finished() })
        #expect(flushed.count == 1)
    }

    // MARK: the core

    @Test func backgroundingFlushesWhatIsQueuedThenReports() {
        let h = CoreHarness()
        queueOneOffline(h)
        h.sender.defaultResult = .success
        let sends = h.sender.bodies.count
        let flushed = Counter()

        h.core.onBackground(flushed: { flushed.increment() })

        #expect(h.sender.bodies.count == sends + 1)
        #expect(h.queue.size == 0)
        #expect(flushed.count == 1)
    }

    @Test func aFlushThatCannotDeliverStillReportsSoTheTaskEnds() {
        let h = CoreHarness()
        queueOneOffline(h)
        let flushed = Counter()

        h.core.onBackground(flushed: { flushed.increment() })

        #expect(h.queue.size == 1)
        #expect(flushed.count == 1)
    }

    @Test func whileDisabledBackgroundingReportsWithoutTouchingTheNetwork() {
        let h = CoreHarness()
        queueOneOffline(h)
        h.core.setEnabled(false)
        let sends = h.sender.bodies.count
        let flushed = Counter()

        h.core.onBackground(flushed: { flushed.increment() })

        #expect(h.sender.bodies.count == sends)
        #expect(flushed.count == 1)
    }

    @Test func backgroundingStillStopsTheHeartbeat() {
        let h = CoreHarness()
        h.core.onForeground()
        h.core.onBackground(flushed: {})
        #expect(h.scheduler.activeRepeating() == nil)
    }

    @Test func aDrainReportsToEveryCallerThatWaitedOnIt() {
        let queue = EventQueue(fileURL: temporaryQueueFile())
        let controller = FlushController(queue: queue, sender: FakeHttpSender(), scheduler: FakeTaskScheduler(), clock: FakeClock())
        let drained = Counter()
        controller.requestFlush(.appBackground) { drained.increment() }
        controller.requestFlush(.appBackground) { drained.increment() }
        #expect(drained.count == 2)
    }
}
#endif
