import Foundation

// Expiry runs on the monotonic clock; the persisted wall time only decides survival across a restart.
final class SessionManager: @unchecked Sendable {

    struct Session: Equatable, Sendable {
        let sessionId: String
        let visitCount: Int
    }

    static let sessionTimeoutMillis: Int64 = 30 * 60 * 1000

    // Generous on purpose: only a real backward clock change should discard the session, not jitter.
    static let wallFutureToleranceMillis: Int64 = 60_000

    private let store: any KeyValueStore
    private let clock: any Clock
    private let lock = NSLock()
    private var sessionId: String
    private var visitCount: Int
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
        if let storedId, UUID(uuidString: storedId) != nil, let wallElapsed,
           wallElapsed < Self.sessionTimeoutMillis, wallElapsed > -Self.wallFutureToleranceMillis {
            sessionStillLive = true
            sessionId = storedId
            visitCount = storedVisits > 0 ? storedVisits : 1
            // Carries the idle time across the restart; future skew within tolerance counts as just active.
            lastActivityMonotonic = monotonicNow - max(0, wallElapsed)
        } else {
            sessionStillLive = false
            sessionId = UUID().uuidString.lowercased()
            visitCount = max(0, storedVisits) + 1
            lastActivityMonotonic = monotonicNow
        }
        if !sessionStillLive {
            persistSession(wallMillis: wallNow)
        }
    }

    // No expiry check: touch() first.
    func currentSession() -> Session {
        lock.lock()
        defer { lock.unlock() }
        return Session(sessionId: sessionId, visitCount: visitCount)
    }

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

    func onForeground() {
        touch()
    }

    func rotate() {
        lock.lock()
        defer { lock.unlock() }
        rotateLocked()
        lastActivityMonotonic = clock.monotonicMillis()
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
