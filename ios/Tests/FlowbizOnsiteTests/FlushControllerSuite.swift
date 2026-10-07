#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct FlushControllerSuite {

    private let scheduler = FakeTaskScheduler()
    private let sender = FakeHttpSender()
    private let clock = FakeClock()
    private let queue = EventQueue(fileURL: temporaryQueueFile())

    private func controller(batchSize: Int = FlushController.maxBatchSize) -> FlushController {
        FlushController(queue: queue, sender: sender, scheduler: scheduler, clock: clock, batchSize: batchSize)
    }

    private func entry(_ n: Int) -> String {
        let iso = EnvelopeBuilder.isoMillis(clock.wall)
        return "{\"event\":\"e\(n)\",\"hash\":\"h\(n)\",\"timings\":"
            + "{\"created_at\":\"\(iso)\",\"sent_at\":\"\(iso)\",\"timezone\":\"-03:00\"}}"
    }

    private func eventsIn(_ body: String) -> [String] {
        let root = try! JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        let data = root["data"] as! [[String: Any]]
        return data.map { $0["event"] as! String }
    }

    private func timings(of body: String, at index: Int) -> [String: Any] {
        let root = try! JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        let data = root["data"] as! [[String: Any]]
        return data[index]["timings"] as! [String: Any]
    }

    @Test func drainBatchesAtMostFiftyPerRequestInOrder() {
        let c = controller()
        (1...120).forEach { queue.append(entry($0)) }
        c.requestFlush(.explicit)
        #expect(sender.bodies.count == 3)
        #expect(sender.bodies.map { eventsIn($0).count } == [50, 50, 20])
        #expect(eventsIn(sender.bodies[0]) == (1...50).map { "e\($0)" })
        #expect(eventsIn(sender.bodies[1]) == (51...100).map { "e\($0)" })
        #expect(eventsIn(sender.bodies[2]) == (101...120).map { "e\($0)" })
        #expect(queue.size == 0)
    }

    @Test func successDequeuesExactlyTheBatch() {
        let c = controller(batchSize: 3)
        (1...5).forEach { queue.append(entry($0)) }
        sender.results = [.success, .retriableError]
        c.requestFlush(.explicit)
        #expect(queue.peek(10) == [entry(4), entry(5)])
    }

    @Test func emptyQueueDrainSendsNothing() {
        let c = controller()
        c.requestFlush(.explicit)
        #expect(sender.bodies.isEmpty)
        #expect(scheduler.allScheduleDelays.isEmpty)
    }

    @Test func payloadTooLargeSplitsInHalfUntilDeliverable() {
        let c = controller()
        (1...4).forEach { queue.append(entry($0)) }
        sender.resultFor = { [self] body in
            eventsIn(body).count > 1 ? .payloadTooLarge : .success
        }
        c.requestFlush(.explicit)
        #expect(sender.bodies.map { eventsIn($0) } == [
            ["e1", "e2", "e3", "e4"], ["e1", "e2"], ["e1"], ["e2"], ["e3", "e4"], ["e3"], ["e4"],
        ])
        #expect(queue.size == 0)
    }

    @Test func singleEventStill413IsDroppedAsPoison() {
        let c = controller()
        queue.append(entry(1))
        queue.append(entry(2))
        sender.resultFor = { [self] body in
            let events = eventsIn(body)
            if events.count > 1 { return .payloadTooLarge }
            return events == ["e1"] ? .payloadTooLarge : .success
        }
        c.requestFlush(.explicit)
        #expect(queue.size == 0)
        #expect(scheduler.allScheduleDelays.isEmpty)
        #expect(eventsIn(sender.bodies.last!) == ["e2"])
    }

    @Test func permanentErrorBisectsToDropOnlyThePoisonEvent() {
        let c = controller()
        (1...5).forEach { queue.append(entry($0)) }
        sender.resultFor = { [self] body in
            eventsIn(body).contains("e3") ? .permanentError : .success
        }
        c.requestFlush(.explicit)
        #expect(queue.size == 0)
        let delivered = sender.bodies
            .filter { !eventsIn($0).contains("e3") }
            .flatMap { eventsIn($0) }
        #expect(delivered == ["e1", "e2", "e4", "e5"])
        #expect(scheduler.allScheduleDelays.isEmpty)
    }

    @Test func wholeBatchPermanentlyRejectedIsDroppedEventByEvent() {
        let c = controller()
        (1...3).forEach { queue.append(entry($0)) }
        sender.defaultResult = .permanentError
        c.requestFlush(.explicit)
        #expect(queue.size == 0)
        #expect(scheduler.allScheduleDelays.isEmpty)
    }

    @Test func retriableErrorStopsDrainPreservingOrderAndSchedulesRetry() {
        let c = controller(batchSize: 2)
        (1...5).forEach { queue.append(entry($0)) }
        sender.results = [.success]
        sender.defaultResult = .retriableError
        c.requestFlush(.explicit)
        #expect(queue.peek(10) == [entry(3), entry(4), entry(5)])
        #expect(sender.bodies.count == 2)
        #expect(scheduler.allScheduleDelays == [FlushController.initialBackoffMillis])
    }

    @Test func retryDuringBisectionStopsWithoutDroppingInnocents() {
        let c = controller()
        (1...4).forEach { queue.append(entry($0)) }
        sender.results = [.permanentError]
        sender.defaultResult = .retriableError
        c.requestFlush(.explicit)
        #expect(queue.size == 4)
        #expect(scheduler.allScheduleDelays.count == 1)
    }

    @Test func sentAtIsRewrittenOnEachAttemptCreatedAtUntouched() {
        let c = controller()
        let createdIso = EnvelopeBuilder.isoMillis(clock.wall)
        queue.append(entry(1))

        clock.advance(2_000)
        let firstAttemptIso = EnvelopeBuilder.isoMillis(clock.wall)
        sender.results = [.retriableError]
        c.requestFlush(.explicit)

        clock.advance(5_000)
        let secondAttemptIso = EnvelopeBuilder.isoMillis(clock.wall)
        sender.defaultResult = .success
        c.requestFlush(.explicit)

        #expect(sender.bodies.count == 2)
        let first = timings(of: sender.bodies[0], at: 0)
        let second = timings(of: sender.bodies[1], at: 0)
        #expect(first["created_at"] as? String == createdIso)
        #expect(second["created_at"] as? String == createdIso)
        #expect(first["sent_at"] as? String == firstAttemptIso)
        #expect(second["sent_at"] as? String == secondAttemptIso)
        #expect(second["timezone"] as? String == "-03:00")
        #expect(queue.size == 0)
    }

    @Test func backoffDoublesToSixtySecondCap() {
        let c = controller()
        queue.append(entry(1))
        sender.defaultResult = .retriableError
        c.requestFlush(.explicit)
        for _ in 0..<7 { scheduler.runLastScheduled() }
        #expect(scheduler.allScheduleDelays == [1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000])
    }

    @Test func anyRetryTriggerResetsBackoffAndCancelsPendingRetry() {
        let c = controller()
        queue.append(entry(1))
        sender.defaultResult = .retriableError
        c.requestFlush(.explicit)
        scheduler.runLastScheduled()
        scheduler.runLastScheduled()
        #expect(scheduler.allScheduleDelays == [1_000, 2_000, 4_000])

        c.requestFlush(.networkRestored)
        #expect(scheduler.scheduled[2].cancelled)
        #expect(scheduler.allScheduleDelays == [1_000, 2_000, 4_000, 1_000])
    }

    @Test func scheduledRetryAttemptsTheDrainAgain() {
        let c = controller()
        queue.append(entry(1))
        sender.results = [.retriableError]
        sender.defaultResult = .success
        c.requestFlush(.explicit)
        #expect(queue.size == 1)
        scheduler.runLastScheduled()
        #expect(queue.size == 0)
        #expect(sender.bodies.count == 2)
    }

    @Test func reentrantFlushRequestCoalescesInsteadOfNesting() {
        let c = controller()
        queue.append(entry(1))
        var triggered = false
        sender.onSend = { _ in
            if !triggered {
                triggered = true
                c.requestFlush(.eventTracked)
            }
        }
        c.requestFlush(.explicit)
        #expect(sender.maxDepth == 1)
        #expect(sender.bodies.count == 1)
        #expect(queue.size == 0)
    }
}
#endif
