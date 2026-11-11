#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

// Real queues: what these pin is which queue a blocking send holds.
@Suite struct DurableDeliverySuite {

    private final class BlockingSender: HttpSender, @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let blocksOn: String
        private let lock = NSLock()
        private var returnedFlag = false

        init(blocksOn: String) { self.blocksOn = blocksOn }

        var returned: Bool {
            lock.lock()
            defer { lock.unlock() }
            return returnedFlag
        }

        func send(body: String) -> SendResult {
            guard body.contains(blocksOn) else { return .retriableError }
            started.signal()
            _ = release.wait(timeout: .now() + 10)
            lock.lock()
            returnedFlag = true
            lock.unlock()
            return .success
        }
    }

    // The config floor is 15 s: fire the heartbeat at once instead.
    private struct FastHeartbeatScheduler: TaskScheduler {
        let real: DispatchTaskScheduler

        func execute(_ task: @escaping @Sendable () -> Void) { real.execute(task) }
        func schedule(afterMillis: Int64, _ task: @escaping @Sendable () -> Void) -> any ScheduledHandle {
            real.schedule(afterMillis: afterMillis, task)
        }
        func scheduleRepeating(intervalMillis: Int64, _ task: @escaping @Sendable () -> Void) -> any ScheduledHandle {
            real.scheduleRepeating(intervalMillis: 20, task)
        }
    }

    private func core(queueFile: URL, sender: any HttpSender) -> FlowbizCore {
        FlowbizCore(
            config: FlowbizConfig(appId: "77777", baseUri: "https://store.com"),
            store: FakeKeyValueStore(),
            queueFactory: { EventQueue(fileURL: queueFile) },
            pushTokenFileURL: { queueFile.deletingLastPathComponent().appendingPathComponent("push_token") },
            sender: sender,
            scheduler: FastHeartbeatScheduler(real: DispatchTaskScheduler(queue: DispatchQueue(label: "tests.sdk"))),
            clock: FakeClock(),
            deviceContext: DeviceContext(language: "pt-BR", screen: { "1170x2532" }, timezoneOffsetMinutes: { _ in -180 }),
            reachability: FakeReachability(),
            transportScheduler: DispatchTaskScheduler(queue: DispatchQueue(label: "tests.transport"))
        )
    }

    private func awaitLines(_ file: URL, _ count: Int) -> [String] {
        func lines() -> [String] {
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if lines().count >= count { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return lines()
    }

    @Test func anEventTrackedWhileASendIsBlockedIsOnDiskBeforeThatSendReturns() {
        let queueFile = temporaryQueueFile()
        let sender = BlockingSender(blocksOn: "page.view")
        let core = core(queueFile: queueFile, sender: sender)
        defer { sender.release.signal() }

        core.track(.pageView(path: "/first"))
        #expect(sender.started.wait(timeout: .now() + 5) == .success)
        core.track(.cartSetCoupon(cartId: "c-1", coupon: "tracked-mid-send"))

        let lines = awaitLines(queueFile, 2)
        #expect(!sender.returned, "the send is still blocked")
        #expect(lines.count == 2)
        #expect(lines.last?.contains("tracked-mid-send") == true)
    }

    @Test func anEventTrackedWhileAPingIsBlockedIsOnDiskBeforeThatPingReturns() {
        let queueFile = temporaryQueueFile()
        let sender = BlockingSender(blocksOn: "page.ping")
        let core = core(queueFile: queueFile, sender: sender)
        defer { sender.release.signal() }

        core.onForeground()
        #expect(sender.started.wait(timeout: .now() + 5) == .success)
        core.track(.pageView(path: "/tracked-mid-ping"))

        let lines = awaitLines(queueFile, 1)
        #expect(!sender.returned, "the ping is still blocked")
        #expect(lines.count == 1)
    }
}
#endif
