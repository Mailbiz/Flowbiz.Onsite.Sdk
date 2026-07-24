// Test doubles and harness for the Slice 4 core (`FlowbizCore` with every
// seam faked): the tests drive the serial scheduler inline and observe the
// wire through `FakeHttpSender` bodies.
import Foundation
@testable import FlowbizOnsite

/// Recorded `ReachabilityMonitor`; tests fire `callback` to simulate
/// network restoration.
final class FakeReachability: ReachabilityMonitor, @unchecked Sendable {
    var started = false
    var callback: (@Sendable () -> Void)?

    func start(onNetworkAvailable: @escaping @Sendable () -> Void) {
        started = true
        callback = onNetworkAvailable
    }

    func stop() {
        started = false
        callback = nil
    }
}

/// Mutable box for the injected timezone offset (minutes).
final class OffsetBox: @unchecked Sendable {
    var value: Int
    init(_ value: Int) { self.value = value }
}

/// A `FlowbizCore` with every dependency faked. The `FakeTaskScheduler`
/// executes inline, so `core.track(...)` runs the whole pipeline (including
/// the flush drain) synchronously on the test thread.
final class CoreHarness: @unchecked Sendable {

    let config: FlowbizConfig
    let store: FakeKeyValueStore
    let clock: FakeClock
    let sender: FakeHttpSender
    let scheduler: FakeTaskScheduler
    let reachability: FakeReachability
    let offset: OffsetBox
    let queue: EventQueue
    let core: FlowbizCore

    init(
        config: FlowbizConfig = FlowbizConfig(appId: "77777"),
        store: FakeKeyValueStore = FakeKeyValueStore(),
        clock: FakeClock = FakeClock()
    ) {
        let sender = FakeHttpSender()
        let scheduler = FakeTaskScheduler()
        let reachability = FakeReachability()
        let offset = OffsetBox(-180)
        let queue = EventQueue(fileURL: temporaryQueueFile())
        self.config = config
        self.store = store
        self.clock = clock
        self.sender = sender
        self.scheduler = scheduler
        self.reachability = reachability
        self.offset = offset
        self.queue = queue
        self.core = FlowbizCore(
            config: config,
            store: store,
            queueFactory: { queue },
            sender: sender,
            scheduler: scheduler,
            clock: clock,
            deviceContext: DeviceContext(
                language: "pt-BR",
                screen: { "1170x2532" },
                timezoneOffsetMinutes: { _ in offset.value }
            ),
            reachability: reachability
        )
    }

    /// Entries of every sent body, in send order (flush batches flattened).
    func sentEntries() throws -> [[String: Any]] {
        try sender.bodies.flatMap { body -> [[String: Any]] in
            guard let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  let data = object["data"] as? [[String: Any]] else {
                throw FixtureSupport.FixtureError("unparseable body: \(body)")
            }
            return data
        }
    }

    func lastEntry() throws -> [String: Any] {
        guard let last = try sentEntries().last else {
            throw FixtureSupport.FixtureError("no entries were sent")
        }
        return last
    }
}

/// UUID-shape check (8-4-4-4-12 hex, any case) matching the Android tests.
func isUUIDShaped(_ value: Any?) -> Bool {
    guard let string = value as? String else { return false }
    return UUID(uuidString: string) != nil
}

/// Convenience accessors mirroring the Android JSONObject helpers.
func object(_ entry: [String: Any], _ key: String) -> [String: Any] {
    entry[key] as? [String: Any] ?? [:]
}
