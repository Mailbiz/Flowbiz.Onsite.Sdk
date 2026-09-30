package br.com.flowbiz.onsite

import java.util.UUID

internal class SessionManager(
    private val store: KeyValueStore,
    private val clock: Clock,
) {

    data class Session(val sessionId: String, val visitCount: Int)

    private val lock = Any()
    private var sessionId: String
    private var visitCount: Int
    // Monotonic, so wall-clock jumps can't rotate or immortalize a session; wall time only across restarts.
    private var lastActivityMonotonic: Long

    init {
        val monotonicNow = clock.monotonicMillis()
        val wallNow = clock.wallMillis()
        val storedId = store.getString(StorageKeys.SESSION_ID)
        val storedVisits = store.getInt(StorageKeys.VISIT_COUNT) ?: 0
        val storedWall = store.getLong(StorageKeys.LAST_ACTIVITY_WALL_MS)

        val wallElapsed = if (storedWall != null) wallNow - storedWall else null
        val sessionStillLive = storedId != null && IdentityStore.UUID_SHAPE.matches(storedId) &&
            wallElapsed != null &&
            wallElapsed < SESSION_TIMEOUT_MS && wallElapsed > -WALL_FUTURE_TOLERANCE_MS

        if (sessionStillLive) {
            sessionId = storedId!!
            visitCount = if (storedVisits > 0) storedVisits else 1
            // Carries the idle time across the restart; future skew within tolerance counts as just active.
            lastActivityMonotonic = monotonicNow - maxOf(0L, wallElapsed!!)
        } else {
            sessionId = UUID.randomUUID().toString()
            visitCount = maxOf(0, storedVisits) + 1
            lastActivityMonotonic = monotonicNow
            persistSession(wallNow)
        }
    }

    fun currentSession(): Session = synchronized(lock) { Session(sessionId, visitCount) }

    fun touch() {
        synchronized(lock) {
            val now = clock.monotonicMillis()
            if (now - lastActivityMonotonic >= SESSION_TIMEOUT_MS) rotateLocked()
            lastActivityMonotonic = now
            store.putLong(StorageKeys.LAST_ACTIVITY_WALL_MS, clock.wallMillis())
        }
    }

    fun onForeground() = touch()

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

        // Generous on purpose: only a real backward clock change should discard the session, not jitter.
        const val WALL_FUTURE_TOLERANCE_MS: Long = 60_000L
    }
}
