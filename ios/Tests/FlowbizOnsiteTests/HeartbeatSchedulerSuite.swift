// SPEC §8 heartbeat: repeating beats while started, stop halts, and the
// fire-and-forget contract — failures drop, nothing ever touches the queue.
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct HeartbeatSchedulerSuite {

    private final class PingCounter: @unchecked Sendable {
        var count = 0
        var provideNil = false
    }

    private let scheduler = FakeTaskScheduler()
    private let sender = FakeHttpSender()
    private let counter = PingCounter()
    private let heartbeat: HeartbeatScheduler

    init() {
        let counter = counter
        heartbeat = HeartbeatScheduler(scheduler: scheduler, sender: sender) {
            if counter.provideNil { return nil }
            counter.count += 1
            return "{\"event\":\"page.ping\",\"hash\":\"ping\(counter.count)\"}"
        }
    }

    @Test func firesAtEveryIntervalWhileStarted() {
        heartbeat.start(intervalMillis: 60_000)
        #expect(scheduler.activeRepeating()?.delayMillis == 60_000)
        scheduler.tickRepeating(3)
        #expect(sender.bodies == [
            "{\"data\":[{\"event\":\"page.ping\",\"hash\":\"ping1\"}]}",
            "{\"data\":[{\"event\":\"page.ping\",\"hash\":\"ping2\"}]}",
            "{\"data\":[{\"event\":\"page.ping\",\"hash\":\"ping3\"}]}",
        ])
    }

    @Test func stopCancelsTheTimer() {
        heartbeat.start(intervalMillis: 60_000)
        let handle = scheduler.activeRepeating()!
        heartbeat.stop()
        #expect(handle.cancelled)
        #expect(scheduler.activeRepeating() == nil)
    }

    @Test func restartReplacesTheTimer() {
        heartbeat.start(intervalMillis: 60_000)
        let first = scheduler.activeRepeating()!
        heartbeat.start(intervalMillis: 15_000)
        #expect(first.cancelled)
        #expect(scheduler.activeRepeating()?.delayMillis == 15_000)
    }

    @Test func stopWithoutStartIsHarmless() {
        heartbeat.stop()
        #expect(sender.bodies.isEmpty)
    }

    @Test func sendFailureIsDroppedAndNeverEnqueued() {
        // A durable queue co-exists; a failing heartbeat must never reach it
        // (SPEC §8: dropped on failure, never persisted, no retry).
        let queueFile = temporaryQueueFile()
        let queue = EventQueue(fileURL: queueFile)
        sender.defaultResult = .retriableError
        heartbeat.start(intervalMillis: 60_000)
        scheduler.tickRepeating(2)
        #expect(sender.bodies.count == 2)
        #expect(queue.size == 0)
        #expect(!FileManager.default.fileExists(atPath: queueFile.path))
        // No retry machinery engaged either.
        #expect(scheduler.allScheduleDelays.isEmpty)
    }

    @Test func nilEnvelopeSkipsTheBeat() {
        counter.provideNil = true
        heartbeat.start(intervalMillis: 60_000)
        scheduler.tickRepeating(2)
        #expect(sender.bodies.isEmpty)
    }

    // MARK: page.ping envelope shape (SPEC §8: not part of the Event catalog)

    @Test func buildPingProducesAPingEnvelopeWithEmptyPayload() throws {
        let entry = EnvelopeBuilder.buildPing(
            hash: "abc",
            createdAtMillis: 1_700_000_000_000,
            sentAtMillis: 1_700_000_000_123,
            timezone: "-03:00",
            userId: "u1",
            anonymousId: "anon",
            sessionId: "sess",
            visitCount: 3,
            language: "pt-BR",
            screen: "1170x2532",
            appId: "77777",
            platform: "ios",
            sdkVersion: "1.0.0"
        )
        #expect(entry["event"] as? String == "page.ping")
        #expect(entry["data"] as? String == "{}")
        #expect(entry["hash"] as? String == "abc")
        #expect(entry["app_id"] as? String == "77777")
        let context = entry["context"] as? [String: Any]
        #expect(context?["url"] == nil)
        #expect(context?["vendor"] as? String == "flowbiz-ios-sdk")
        let timings = entry["timings"] as? [String: Any]
        #expect(timings?["created_at"] as? String == "2023-11-14T22:13:20.000Z")
        #expect(timings?["sent_at"] as? String == "2023-11-14T22:13:20.123Z")
        let identity = entry["identity"] as? [String: Any]
        #expect(identity?["user_id"] as? String == "u1")
        #expect(identity?["visit_count"] as? Int == 3)
        // Round-trips through the canonical renderer like any queued entry.
        let rendered = try CanonicalJSON.render(entry)
        #expect(try JSONSerialization.jsonObject(with: Data(rendered.utf8)) is [String: Any])
    }
}
#endif
