package com.flowbiz.onsite

import java.util.UUID

/**
 * Session state (SPEC §6): `session_id` + `visit_count` with a 30-minute
 * sliding inactivity window.
 *
 * ## Clocking
 * In-process, expiry is decided **only** by [Clock.monotonicMillis]: wall
 * clock jumps (user settings, NTP corrections, timezone travel) can neither
 * rotate nor immortalize a session. A wall-clock timestamp of the last
 * activity is persisted purely as the **restart fallback** — monotonic time
 * resets across process restarts, so on construction the persisted wall
 * timestamp decides whether the previous session is still live:
 *
 * - missing, ≥ 30 min in the past, or further than
 *   [WALL_FUTURE_TOLERANCE_MS] in the future (clock rolled back since the
 *   last run — untrusted) → rotate;
 * - otherwise the session is adopted and the wall-clock idle time is carried
 *   into the monotonic anchor, so a session idle 20 min before a restart has
 *   10 min left, not a fresh 30.
 *
 * ## Boundary
 * Expiry is **inclusive**: elapsed ≥ 30:00.000 rotates (SPEC §6 reads "after
 * ≥ 30 min of inactivity"); 29:59.999 slides.
 *
 * Thread-safe. Rotation increments `visit_count` exactly once per expiry —
 * after an expired window, the first touch rotates and re-anchors, so
 * further touches slide the fresh window instead of rotating again.
 */
internal class SessionManager(
    private val store: KeyValueStore,
    private val clock: Clock,
) {

    /** Immutable snapshot for envelope building. */
    data class Session(val sessionId: String, val visitCount: Int)

    private val lock = Any()
    private var sessionId: String
    private var visitCount: Int

    /** Monotonic instant of the last activity — the sole in-process expiry input. */
    private var lastActivityMonotonic: Long

    init {
        val monotonicNow = clock.monotonicMillis()
        val wallNow = clock.wallMillis()
        val storedId = store.getString(StorageKeys.SESSION_ID)
        val storedVisits = store.getInt(StorageKeys.VISIT_COUNT) ?: 0
        val storedWall = store.getLong(StorageKeys.LAST_ACTIVITY_WALL_MS)

        val wallElapsed = if (storedWall != null) wallNow - storedWall else null
        val sessionStillLive = storedId != null && wallElapsed != null &&
            wallElapsed < SESSION_TIMEOUT_MS && wallElapsed > -WALL_FUTURE_TOLERANCE_MS

        if (sessionStillLive) {
            sessionId = storedId!!
            visitCount = if (storedVisits > 0) storedVisits else 1
            // Carry cross-restart idle time into the monotonic window
            // (small future skew within tolerance clamps to "just active").
            lastActivityMonotonic = monotonicNow - maxOf(0L, wallElapsed!!)
        } else {
            sessionId = UUID.randomUUID().toString()
            visitCount = storedVisits + 1
            lastActivityMonotonic = monotonicNow
            persistSession(wallNow)
        }
    }

    /** Snapshot of the current session identifiers (no expiry check, no side effects). */
    fun currentSession(): Session = synchronized(lock) { Session(sessionId, visitCount) }

    /**
     * Records activity — every tracked event and heartbeat (Slice 4 wires
     * the callers): rotates first if the window already expired, then slides
     * it and persists the wall-clock fallback timestamp.
     */
    fun touch() {
        synchronized(lock) {
            val now = clock.monotonicMillis()
            if (now - lastActivityMonotonic >= SESSION_TIMEOUT_MS) rotateLocked()
            lastActivityMonotonic = now
            store.putLong(StorageKeys.LAST_ACTIVITY_WALL_MS, clock.wallMillis())
        }
    }

    /**
     * Foreground transition — SPEC §6: new session when the app foregrounds
     * after ≥ 30 min of inactivity. Foregrounding is user activity, so it
     * performs the same expire-then-slide as [touch].
     */
    fun onForeground() = touch()

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
        /** 30 min — internal constant, not a config knob (SPEC §2). */
        const val SESSION_TIMEOUT_MS: Long = 30L * 60L * 1000L

        /**
         * Persisted wall timestamps further than this in the future are
         * treated as corrupt on init. Generous by design: only a genuine
         * backward clock change should trip it, not scheduler jitter.
         */
        const val WALL_FUTURE_TOLERANCE_MS: Long = 60_000L
    }
}
