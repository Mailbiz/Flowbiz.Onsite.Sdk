import Foundation

/// SPEC §8 heartbeat: while started (facade calls `start` on foreground,
/// `stop` on background — Slice 4), emits a `page.ping` envelope every
/// interval on the SDK's serial `TaskScheduler` (a `DispatchSourceTimer`
/// under the production scheduler).
///
/// Fire-and-forget by design: the ping goes **directly through the
/// `HttpSender`, bypassing the queue** — any failure is dropped, never
/// retried, never persisted, so a flaky network cannot fill the durable
/// queue with heartbeats and evict real events (SPEC §8).
///
/// `envelopeProvider` returns the serialized `page.ping` envelope entry
/// (see `EnvelopeBuilder.buildPing`) with fresh identity/timing values, or
/// nil to skip a beat (e.g. SDK disabled). The first beat fires one full
/// interval after `start` (matching web `pagePingDelay` cadence). Interval
/// clamping (≥ 15 s) is config-side, Slice 4.
///
/// Thread-safe; never throws (SPEC §3).
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

    /// Starts (or restarts with a new interval) the repeating heartbeat.
    func start(intervalMillis: Int64) {
        lock.lock()
        defer { lock.unlock() }
        handle?.cancel()
        handle = scheduler.scheduleRepeating(intervalMillis: intervalMillis) { [weak self] in
            self?.tick()
        }
    }

    /// Stops the heartbeat (app backgrounded). Safe when not started.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        handle?.cancel()
        handle = nil
    }

    private func tick() {
        guard let entry = envelopeProvider() else { return }
        // Result deliberately ignored: success and failure are equal —
        // no retry, no queue write (SPEC §8).
        _ = sender.send(body: "{\"data\":[\(entry)]}")
    }
}
