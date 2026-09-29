import Foundation

/// Sends `page.ping` every interval while started, the first one interval
/// after `start` (the web `pagePingDelay` cadence). Pings bypass the queue: a
/// failed one is dropped, so a flaky network cannot fill the durable queue
/// and evict real events. `envelopeProvider` returns nil to skip a beat.
final class HeartbeatScheduler: @unchecked Sendable {

    private let scheduler: any TaskScheduler
    private let sender: any HttpSender
    private let envelopeProvider: @Sendable () -> String?
    private let lock = NSLock()
    private var handle: (any ScheduledHandle)?

    init(
        scheduler: any TaskScheduler,
        sender: any HttpSender,
        envelopeProvider: @escaping @Sendable () -> String?
    ) {
        self.scheduler = scheduler
        self.sender = sender
        self.envelopeProvider = envelopeProvider
    }

    func start(intervalMillis: Int64) {
        lock.lock()
        defer { lock.unlock() }
        handle?.cancel()
        handle = scheduler.scheduleRepeating(intervalMillis: intervalMillis) { [weak self] in
            self?.tick()
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        handle?.cancel()
        handle = nil
    }

    private func tick() {
        guard let entry = envelopeProvider() else { return }
        _ = sender.send(body: "{\"data\":[\(entry)]}")
    }
}
