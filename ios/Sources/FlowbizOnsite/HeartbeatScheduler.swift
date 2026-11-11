import Foundation

// Ticks on the SDK scheduler, where the envelope is built; the blocking POST goes to the transport's.
final class HeartbeatScheduler: @unchecked Sendable {

    private let scheduler: any TaskScheduler
    private let sender: any HttpSender
    private let transport: any TaskScheduler
    private let envelopeProvider: @Sendable () -> String?
    private let lock = NSLock()
    private var handle: (any ScheduledHandle)?
    private var sending = false

    init(
        scheduler: any TaskScheduler,
        sender: any HttpSender,
        transport: (any TaskScheduler)? = nil,
        envelopeProvider: @escaping @Sendable () -> String?
    ) {
        self.scheduler = scheduler
        self.sender = sender
        self.transport = transport ?? scheduler
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
        // A ping still waiting behind a slow send is not joined by another.
        guard setSending(true) else { return }
        guard let entry = envelopeProvider() else {
            setSending(false)
            return
        }
        transport.execute { [self] in
            // Bypasses the queue: a failed ping is dropped, so pings can never evict real events.
            _ = sender.send(body: "{\"data\":[\(entry)]}")
            setSending(false)
        }
    }

    /// False when `value` is already the state.
    @discardableResult
    private func setSending(_ value: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if sending == value { return false }
        sending = value
        return true
    }
}
