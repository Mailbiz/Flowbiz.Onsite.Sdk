import Foundation

/// Session state (SPEC §6): `session_id` + `visit_count` with a 30-minute
/// sliding inactivity window.
///
/// ## Clocking
/// In-process, expiry is decided **only** by `Clock.monotonicMillis()`: wall
/// clock jumps (user settings, NTP corrections, timezone travel) can neither
/// rotate nor immortalize a session. A wall-clock timestamp of the last
/// activity is persisted purely as the **restart fallback** — monotonic time
/// resets across process restarts, so on construction the persisted wall
/// timestamp decides whether the previous session is still live:
///
/// - missing, ≥ 30 min in the past, or further than
///   `wallFutureToleranceMillis` in the future (clock rolled back since the
///   last run — untrusted) → rotate;
/// - otherwise the session is adopted and the wall-clock idle time is
///   carried into the monotonic anchor, so a session idle 20 min before a
///   restart has 10 min left, not a fresh 30.
///
/// ## Boundary
/// Expiry is **inclusive**: elapsed ≥ 30:00.000 rotates (SPEC §6 reads
/// "after ≥ 30 min of inactivity"); 29:59.999 slides.
///
/// Thread-safe. Rotation increments `visit_count` exactly once per expiry —
/// after an expired window, the first touch rotates and re-anchors, so
/// further touches slide the fresh window instead of rotating again.
final class SessionManager: @unchecked Sendable {

    /// Immutable snapshot for envelope building.
    struct Session: Equatable, Sendable {
        let sessionId: String
        let visitCount: Int
    }

    /// 30 min — internal constant, not a config knob (SPEC §2).
    static let sessionTimeoutMillis: Int64 = 30 * 60 * 1000

    /// Persisted wall timestamps further than this in the future are treated
    /// as corrupt on init. Generous by design: only a genuine backward clock
    /// change should trip it, not scheduler jitter.
    static let wallFutureToleranceMillis: Int64 = 60_000

    private let store: any KeyValueStore
    private let clock: any Clock
    private let lock = NSLock()
    private var sessionId: String
    private var visitCount: Int

    /// Monotonic instant of the last activity — the sole in-process expiry input.
    private var lastActivityMonotonic: Int64

    init(store: any KeyValueStore, clock: any Clock) {
        self.store = store
        self.clock = clock

        let monotonicNow = clock.monotonicMillis()
        let wallNow = clock.wallMillis()
        let storedId = store.string(forKey: StorageKeys.sessionId)
        let storedVisits = store.int(forKey: StorageKeys.visitCount) ?? 0
        let storedWall = store.int64(forKey: StorageKeys.lastActivityWallMs)

        let wallElapsed = storedWall.map { wallNow - $0 }
        let sessionStillLive: Bool
        if let storedId, let wallElapsed,
           wallElapsed < Self.sessionTimeoutMillis, wallElapsed > -Self.wallFutureToleranceMillis {
            sessionStillLive = true
            sessionId = storedId
            visitCount = storedVisits > 0 ? storedVisits : 1
            // Carry cross-restart idle time into the monotonic window
            // (small future skew within tolerance clamps to "just active").
            lastActivityMonotonic = monotonicNow - max(0, wallElapsed)
        } else {
            sessionStillLive = false
            sessionId = UUID().uuidString.lowercased()
            visitCount = storedVisits + 1
            lastActivityMonotonic = monotonicNow
        }
        if !sessionStillLive {
            persistSession(wallMillis: wallNow)
        }
    }

    /// Snapshot of the current session identifiers (no expiry check, no side effects).
    func currentSession() -> Session {
        lock.lock()
        defer { lock.unlock() }
        return Session(sessionId: sessionId, visitCount: visitCount)
    }

    /// Records activity — every tracked event and heartbeat (Slice 4 wires
    /// the callers): rotates first if the window already expired, then
    /// slides it and persists the wall-clock fallback timestamp.
    func touch() {
        lock.lock()
        defer { lock.unlock() }
        let now = clock.monotonicMillis()
        if now - lastActivityMonotonic >= Self.sessionTimeoutMillis {
            rotateLocked()
        }
        lastActivityMonotonic = now
        store.set(clock.wallMillis(), forKey: StorageKeys.lastActivityWallMs)
    }

    /// Foreground transition — SPEC §6: new session when the app foregrounds
    /// after ≥ 30 min of inactivity. Foregrounding is user activity, so it
    /// performs the same expire-then-slide as `touch()`.
    func onForeground() {
        touch()
    }

    private func rotateLocked() {
        sessionId = UUID().uuidString.lowercased()
        visitCount += 1
        persistSession(wallMillis: clock.wallMillis())
    }

    private func persistSession(wallMillis: Int64) {
        store.set(sessionId, forKey: StorageKeys.sessionId)
        store.set(visitCount, forKey: StorageKeys.visitCount)
        store.set(wallMillis, forKey: StorageKeys.lastActivityWallMs)
    }
}
