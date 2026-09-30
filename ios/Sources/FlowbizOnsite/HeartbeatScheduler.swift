import Foundation

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
        // Bypasses the queue: a failed ping is dropped, so pings can never evict real events.
        _ = sender.send(body: "{\"data\":[\(entry)]}")
    }
}
