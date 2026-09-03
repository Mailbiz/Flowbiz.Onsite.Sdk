// `FlowbizCore` lifecycle wiring: heartbeat start/stop on
// foreground/background (SPEC §8), ping contents and session keepalive
// (SPEC §6), and the SPEC §12 `setEnabled` behavior (drop, stop, gate,
// resume).
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct FlowbizCoreLifecycleSuite {

    private func pingEntries(_ h: CoreHarness) throws -> [[String: Any]] {
        try h.sentEntries().filter { $0["event"] as? String == "page.ping" }
    }

    // MARK: Heartbeat lifecycle (SPEC §8)

    @Test func foregroundStartsHeartbeatWithConfiguredInterval() {
        let h = CoreHarness()
        #expect(h.scheduler.activeRepeating() == nil)
        h.core.onForeground()
        #expect(h.scheduler.activeRepeating()?.delayMillis == 60_000)
    }

    @Test func heartbeatIntervalComesFromConfig() {
        let h = CoreHarness(config: FlowbizConfig(appId: "77777", baseUri: "https://store.com", heartbeatInterval: 15))
        h.core.onForeground()
        #expect(h.scheduler.activeRepeating()?.delayMillis == 15_000)
    }

    @Test func backgroundStopsHeartbeat() {
        let h = CoreHarness()
        h.core.onForeground()
        h.core.onBackground()
        #expect(h.scheduler.activeRepeating() == nil)
    }

    @Test func redundantForegroundDoesNotRestartHeartbeat() {
        let h = CoreHarness()
        h.core.onForeground()
        h.core.onForeground() // e.g. didBecomeActive after the initial probe
        #expect(h.scheduler.scheduled.filter { $0.repeating && !$0.cancelled }.count == 1)
    }

    @Test func pingBypassesQueueAndDedupAndCarriesSessionIdentity() throws {
        let h = CoreHarness()
        h.core.onForeground()
        h.scheduler.tickRepeating(2) // identical beats: dedup-exempt by design

        let pings = try pingEntries(h)
        #expect(pings.count == 2)
        #expect(h.queue.size == 0) // never persisted (SPEC §8)

        let ping = try #require(pings.first)
        #expect(ping["data"] as? String == "{}") // no named pageView yet
        let identity = object(ping, "identity")
        #expect(isUUIDShaped(identity["anonymous_id"]))
        #expect(isUUIDShaped(identity["session_id"]))
        #expect(object(ping, "timings")["timezone"] as? String == "-03:00")
        #expect(object(ping, "context")["url"] == nil)
    }

    @Test func pingCarriesLastTrackedScreenAsPageData() throws {
        let h = CoreHarness()
        h.core.onForeground()
        h.core.track(.pageView(path: "checkout"))
        h.scheduler.tickRepeating()
        #expect(
            try pingEntries(h).last?["data"] as? String
                == #"{"page":{"title":"checkout","url":"app://checkout"}}"#
        )

        // An anonymous pageView does not clear the last named screen.
        h.core.track(.pageView(path: nil))
        h.scheduler.tickRepeating()
        #expect(
            try pingEntries(h).last?["data"] as? String
                == #"{"page":{"title":"checkout","url":"app://checkout"}}"#
        )
    }

    @Test func pingFailureIsDroppedNeverQueued() throws {
        let h = CoreHarness()
        h.core.onForeground()
        h.sender.defaultResult = .retriableError
        h.scheduler.tickRepeating(3)
        #expect(h.queue.size == 0)
        #expect(try pingEntries(h).count == 3) // attempted, dropped, no retry state
    }

    @Test func pingKeepsSessionAliveAsActivity() throws {
        // SPEC §6: page.ping counts as activity — a foregrounded idle app
        // keeps its session.
        let h = CoreHarness()
        h.core.track(.pageView(path: "home"))
        let sessionBefore = object(try h.lastEntry(), "identity")["session_id"] as? String
        h.core.onForeground()
        for _ in 0..<3 {
            h.clock.advance(25 * minuteMs)
            h.scheduler.tickRepeating()
        }
        h.clock.advance(25 * minuteMs) // 25 < 30 since last ping
        h.core.track(.pageView(path: "later"))
        #expect(object(try h.lastEntry(), "identity")["session_id"] as? String == sessionBefore)
    }

    @Test func foregroundRequestsFlushOfBacklog() {
        let h = CoreHarness()
        h.sender.results = [.retriableError]
        h.core.track(.pageView(path: "home"))
        #expect(h.queue.size == 1)
        h.core.onForeground()
        #expect(h.queue.size == 0)
    }

    // MARK: setEnabled (SPEC §12)

    @Test func setEnabledFalseStopsHeartbeatDropsEventsAndGatesNetwork() {
        let h = CoreHarness()
        h.core.onForeground()
        // Build a retriable backlog first (a retry is now scheduled).
        h.sender.defaultResult = .retriableError
        h.core.track(.pageView(path: "home"))
        #expect(h.queue.size == 1)
        let sendsBefore = h.sender.bodies.count

        h.core.setEnabled(false)
        #expect(h.store[StorageKeys.enabled] as? Bool == false) // persisted
        #expect(h.scheduler.activeRepeating() == nil) // heartbeat stopped

        h.core.track(.pageView(path: "dropped")) // dropped, not queued
        #expect(h.queue.size == 1)

        h.core.flush() // ignored while disabled
        h.scheduler.runLastScheduled() // pending backoff retry fires → gated
        #expect(h.sender.bodies.count == sendsBefore) // zero network while disabled
    }

    @Test func reachabilityWhileDisabledDoesNotTouchNetwork() {
        let h = CoreHarness()
        h.sender.results = [.retriableError]
        h.core.track(.pageView(path: "home"))
        let sendsBefore = h.sender.bodies.count
        h.core.setEnabled(false)
        h.reachability.callback?()
        #expect(h.sender.bodies.count == sendsBefore)
    }

    @Test func reEnableResumesHeartbeatAndFlushesBacklog() {
        let h = CoreHarness()
        h.core.onForeground()
        h.sender.defaultResult = .retriableError
        h.core.track(.pageView(path: "home"))
        h.core.setEnabled(false)
        #expect(h.queue.size == 1)

        h.sender.defaultResult = .success
        h.core.setEnabled(true)
        #expect(h.queue.size == 0) // backlog flushed
        #expect(h.scheduler.activeRepeating() != nil) // heartbeat resumed (foregrounded)
        #expect(h.store[StorageKeys.enabled] as? Bool == true)
    }

    @Test func reEnableWhileBackgroundedDoesNotStartHeartbeat() {
        let h = CoreHarness()
        h.core.setEnabled(false)
        h.core.setEnabled(true)
        #expect(h.scheduler.activeRepeating() == nil)
    }

    @Test func foregroundWhileDisabledStartsNothing() {
        let h = CoreHarness()
        h.core.setEnabled(false)
        h.core.onForeground()
        #expect(h.scheduler.activeRepeating() == nil)
        #expect(h.sender.bodies.isEmpty)
    }

    @Test func disabledStatePersistsAcrossCoreRecreation() {
        let store = FakeKeyValueStore()
        let first = CoreHarness(store: store)
        first.core.setEnabled(false)

        let second = CoreHarness(store: store)
        second.core.track(.pageView(path: "home"))
        #expect(second.sender.bodies.isEmpty)
    }
}
#endif
