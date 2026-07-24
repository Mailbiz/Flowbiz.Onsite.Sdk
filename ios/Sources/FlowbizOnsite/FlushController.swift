import Foundation

/// The SPEC §9 drain loop: batches the `EventQueue` through the `HttpSender`
/// in order, with 413 bisection, poison isolation, and exponential backoff.
///
/// ## Drain semantics
/// - Batches of up to `maxBatchSize` (50) entries per request, queue order.
/// - `sent_at` is restamped on every entry at **each transmission attempt**
///   (SPEC §4); `created_at` is never touched.
/// - `.success` → dequeue exactly the batch, continue draining.
/// - `.payloadTooLarge` → split the batch in half, retry the halves
///   recursively; a single entry still oversized is poison → dropped.
/// - `.permanentError` → same bisection. SPEC §9's "drop it" is per-event,
///   but a 4xx verdict applies to the whole POST — dropping the full batch
///   would lose innocent events, so the batch is bisected exactly like a
///   413 until the poison entries are isolated and only those are dropped
///   (a deliberate interpretation, flagged for review).
/// - `.retriableError` → stop draining (order preserved), schedule a retry
///   with backoff.
///
/// ## Backoff
/// Exponential 1 s → 60 s cap. **Any** `requestFlush` trigger (next track,
/// foreground, network restored, explicit flush — wired by the facade in
/// Slice 4) resets the backoff to 1 s, cancels a pending retry and attempts
/// immediately (SPEC §9). Scheduled retries themselves do not reset it.
///
/// ## Concurrency
/// All drain work runs on the injected serial `TaskScheduler`; a guard flag
/// makes overlapping/re-entrant drain requests coalesce into one follow-up
/// pass, so flushes never run concurrently. `requestFlush` is callable from
/// any thread and never throws (SPEC §3).
final class FlushController: @unchecked Sendable {

    /// SPEC §9 retry triggers; carried for debug logging only.
    enum FlushReason: String, Sendable {
        case eventTracked, appForeground, networkRestored, explicit
    }

    private enum Outcome {
        case proceed, stopAndRetry
    }

    /// SPEC §9: ≤ 50 events per request.
    static let maxBatchSize = 50

    /// SPEC §9: exponential backoff, 1 s doubling to a 60 s cap.
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

    /// Requests an immediate flush. Resets the backoff and cancels any
    /// pending scheduled retry (SPEC §9: reset by any retry trigger).
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
        // SPEC §12 gate: while the SDK is disabled no network happens — this
        // also covers a backoff retry scheduled *before* the disable (it
        // fires, hits the gate, and schedules nothing further).
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

    /// Sends the `count` oldest queued entries as one request, bisecting on
    /// 413/permanent rejection. Recursion depth ≤ log2(batch) ≈ 6.
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

    /// Builds the `{"data":[...]}` body, restamping `timings.sent_at` with
    /// the current wall clock on every entry (SPEC §4: per attempt).
    /// A defensively-unparseable entry is sent verbatim rather than dropped.
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
