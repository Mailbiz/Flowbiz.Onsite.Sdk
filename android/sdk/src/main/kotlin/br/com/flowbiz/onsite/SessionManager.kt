package br.com.flowbiz.onsite

import java.util.UUID

/**
 * `session_id` + `visit_count` with a 30-minute sliding inactivity window;
 * expiry is inclusive (≥ 30:00.000 rotates). Thread-safe.
 *
 * In-process, expiry uses **only** [Clock.monotonicMillis], so wall-clock
 * jumps (user settings, NTP, timezone travel) can neither rotate nor
 * immortalize a session. Monotonic time resets across process restarts, so
 * a persisted wall timestamp decides after a restart, carrying idle time
 * over (idle 20 min before a restart leaves 10, not a fresh 30).
 */
internal class SessionManager(
    private val store: KeyValueStore,
    private val clock: Clock,
) {

    data class Session(val sessionId: String, val visitCount: Int)

    private val lock = Any()
    private var sessionId: String
    private var visitCount: Int
    private var lastActivityMonotonic: Long

    init {
        val monotonicNow = clock.monotonicMillis()
        val wallNow = clock.wallMillis()
        val storedId = store.getString(StorageKeys.SESSION_ID)
        val storedVisits = store.getInt(StorageKeys.VISIT_COUNT) ?: 0
        val storedWall = store.getLong(StorageKeys.LAST_ACTIVITY_WALL_MS)

        val wallElapsed = if (storedWall != null) wallNow - storedWall else null
        // A corrupt (non-UUID-shaped) stored id is untrusted → rotate.
        val sessionStillLive = storedId != null && IdentityStore.UUID_SHAPE.matches(storedId) &&
            wallElapsed != null &&
            wallElapsed < SESSION_TIMEOUT_MS && wallElapsed > -WALL_FUTURE_TOLERANCE_MS

        if (sessionStillLive) {
            sessionId = storedId!!
            visitCount = if (storedVisits > 0) storedVisits else 1
            // Carry cross-restart idle time into the monotonic window
            // (small future skew within tolerance clamps to "just active").
            lastActivityMonotonic = monotonicNow - maxOf(0L, wallElapsed!!)
        } else {
            sessionId = UUID.randomUUID().toString()
            // Corrupt negative counters clamp to 0 before the increment.
            visitCount = maxOf(0, storedVisits) + 1
            lastActivityMonotonic = monotonicNow
            persistSession(wallNow)
        }
    }

    /** Snapshot of the current session identifiers (no expiry check, no side effects). */
    fun currentSession(): Session = synchronized(lock) { Session(sessionId, visitCount) }

    fun touch() {
        synchronized(lock) {
            val now = clock.monotonicMillis()
            if (now - lastActivityMonotonic >= SESSION_TIMEOUT_MS) rotateLocked()
            lastActivityMonotonic = now
            store.putLong(StorageKeys.LAST_ACTIVITY_WALL_MS, clock.wallMillis())
        }
    }

    /** Foregrounding is user activity: the same expire-then-slide as [touch]. */
    fun onForeground() = touch()

    /** Forced rotation for `logout()`, regardless of the inactivity window. */
    fun rotate() {
        synchronized(lock) {
            rotateLocked()
            lastActivityMonotonic = clock.monotonicMillis()
        }
    }

    private fun rotateLocked() {
        sessionId = UUID.randomUUID().toString()
        visitCount += 1
        persistSession(clock.wallMillis())
    }

    private fun persistSession(wallMillis: Long) {
        store.putString(StorageKeys.SESSION_ID, sessionId)
        store.putInt(StorageKeys.VISIT_COUNT, visitCount)
        store.putLong(StorageKeys.LAST_ACTIVITY_WALL_MS, wallMillis)
    }

    companion object {
        const val SESSION_TIMEOUT_MS: Long = 30L * 60L * 1000L

        /**
         * Persisted wall timestamps further than this in the future are
         * treated as corrupt on init. Generous by design: only a genuine
         * backward clock change should trip it, not scheduler jitter.
         */
        const val WALL_FUTURE_TOLERANCE_MS: Long = 60_000L
    }
}
