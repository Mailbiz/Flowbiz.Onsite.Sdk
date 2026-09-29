import Foundation

/// Drains the queue in order. A 413 or a permanent rejection bisects the
/// batch until the poison entries are isolated and dropped alone: a 4xx
/// rejects the whole POST, and dropping all of it would lose innocent events.
/// A retriable error stops the drain and backs off; any `requestFlush` resets
/// the backoff, scheduled retries do not.
final class FlushController: @unchecked Sendable {

    /// For debug logging only.
    enum FlushReason: String, Sendable {
        case eventTracked, appForeground, networkRestored, explicit
    }

    private enum Outcome {
        case proceed, stopAndRetry
    }

    static let maxBatchSize = 50
    static let initialBackoffMillis: Int64 = 1_000
    static let maxBackoffMillis: Int64 = 60_000

    private let queue: EventQueue
    private let sender: any HttpSender
    private let scheduler: any TaskScheduler
    private let clock: any Clock
    private let batchSize: Int
    private let isActive: @Sendable () -> Bool

    private let lock = NSLock()
    private var draining = false
    private var drainAgain = false
    private var backoffMillis: Int64 = FlushController.initialBackoffMillis
    private var retryHandle: (any ScheduledHandle)?

    init(
        queue: EventQueue,
        sender: any HttpSender,
        scheduler: any TaskScheduler,
        clock: any Clock,
        batchSize: Int = FlushController.maxBatchSize,
        isActive: @escaping @Sendable () -> Bool = { true }
    ) {
        self.queue = queue
        self.sender = sender
        self.scheduler = scheduler
        self.clock = clock
        self.batchSize = batchSize
        self.isActive = isActive
    }

    func requestFlush(_ reason: FlushReason) {
        lock.lock()
        backoffMillis = Self.initialBackoffMillis
        retryHandle?.cancel()
        retryHandle = nil
        lock.unlock()
        SdkLog.debug("flush requested: \(reason.rawValue)")
        scheduler.execute { [weak self] in self?.drain() }
    }

    /// Runs on the serial scheduler queue only.
    private func drain() {
        // Also ends a backoff retry scheduled before a disable.
        guard isActive() else {
            SdkLog.debug("drain skipped: SDK disabled")
            return
        }
        lock.lock()
        if draining {
            // Re-entrant request (e.g. a trigger firing mid-drain with an
            // inline executor): coalesce into one follow-up pass.
            drainAgain = true
            lock.unlock()
            return
        }
        draining = true
        lock.unlock()

        while queue.size > 0 {
            if drainPrefix(min(batchSize, queue.size)) == .stopAndRetry {
                scheduleRetry()
                break
            }
        }

        lock.lock()
        draining = false
        let again = drainAgain
        drainAgain = false
        lock.unlock()
        if again {
            scheduler.execute { [weak self] in self?.drain() }
        }
    }

    /// Recursion depth ≤ log2(batch) ≈ 6.
    private func drainPrefix(_ count: Int) -> Outcome {
        let entries = queue.peek(count)
        if entries.isEmpty { return .proceed }
        switch sender.send(body: buildBody(entries)) {
        case .success:
            queue.removeOldest(entries.count)
            return .proceed

        case .retriableError:
            return .stopAndRetry

        case .payloadTooLarge, .permanentError:
            if entries.count == 1 {
                SdkLog.debug("dropping poison event (rejected by collector)")
                queue.removeOldest(1)
                return .proceed
            }
            let half = entries.count / 2
            if drainPrefix(half) == .stopAndRetry {
                return .stopAndRetry
            }
            // The surviving second half is now the queue head.
            return drainPrefix(entries.count - half)
        }
    }

    private func scheduleRetry() {
        lock.lock()
        let delay = backoffMillis
        backoffMillis = min(backoffMillis * 2, Self.maxBackoffMillis)
        retryHandle?.cancel()
        retryHandle = scheduler.schedule(afterMillis: delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.retryHandle = nil
            self.lock.unlock()
            SdkLog.debug("flush retry after \(delay)ms backoff")
            self.drain()
        }
        lock.unlock()
    }

    /// `sent_at` is restamped at every attempt; `created_at` never changes. An
    /// unparseable entry is sent verbatim rather than dropped.
    private func buildBody(_ entries: [String]) -> String {
        let sentAt = EnvelopeBuilder.isoMillis(clock.wallMillis())
        let rendered = entries.map { line -> String in
            do {
                guard var entry = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    return line
                }
                var timings = entry["timings"] as? [String: Any] ?? [:]
                timings["sent_at"] = sentAt
                entry["timings"] = timings
                return try CanonicalJSON.render(entry)
            } catch {
                SdkLog.debug("sent_at restamp failed, sending entry verbatim")
                return line
            }
        }
        return "{\"data\":[" + rendered.joined(separator: ",") + "]}"
    }
}
