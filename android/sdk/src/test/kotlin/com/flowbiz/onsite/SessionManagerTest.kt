package com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * SPEC §6 session mechanics: 30-min sliding window on the monotonic clock,
 * wall clock only as the cross-restart fallback.
 */
class SessionManagerTest {

    private val timeout = SessionManager.SESSION_TIMEOUT_MS
    private val store = FakeKeyValueStore()
    private val clock = FakeClock()
    private val manager = SessionManager(store, clock)

    // --- First launch ---

    @Test
    fun firstLaunchCreatesSessionWithVisitCount1() {
        val session = manager.currentSession()
        assertEquals(1, session.visitCount)
        val uuidV4 = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
        assertTrue(uuidV4.matches(session.sessionId))
        // Persisted immediately so a crash before the first event keeps the visit.
        assertEquals(session.sessionId, store.values[StorageKeys.SESSION_ID])
        assertEquals(1, store.values[StorageKeys.VISIT_COUNT])
        assertEquals(clock.wall, store.values[StorageKeys.LAST_ACTIVITY_WALL_MS])
    }

    // --- Sliding window (in-process, monotonic) ---

    @Test
    fun touchInsideWindowSlidesWithoutRotating() {
        val original = manager.currentSession()
        // Four touches 29 min apart: 116 min of wall time total, but the
        // window slides on every touch — no rotation.
        repeat(4) {
            clock.advance(29 * MINUTE_MS)
            manager.touch()
        }
        assertEquals(original, manager.currentSession())
    }

    @Test
    fun touchJustUnderThirtyMinutesSlides() {
        val original = manager.currentSession()
        clock.advance(timeout - 1)
        manager.touch()
        assertEquals(original, manager.currentSession())
    }

    @Test
    fun touchAtExactlyThirtyMinutesRotates() {
        // Boundary is inclusive: elapsed >= 30:00.000 rotates ("after >= 30
        // min of inactivity", SPEC §6).
        val original = manager.currentSession()
        clock.advance(timeout)
        manager.touch()
        val rotated = manager.currentSession()
        assertNotEquals(original.sessionId, rotated.sessionId)
        assertEquals(original.visitCount + 1, rotated.visitCount)
    }

    @Test
    fun touchAfterExpiryRotatesAndPersists() {
        clock.advance(timeout + 5 * MINUTE_MS)
        manager.touch()
        val rotated = manager.currentSession()
        assertEquals(2, rotated.visitCount)
        assertEquals(rotated.sessionId, store.values[StorageKeys.SESSION_ID])
        assertEquals(2, store.values[StorageKeys.VISIT_COUNT])
    }

    @Test
    fun multipleTouchesAfterExpiryRotateExactlyOnce() {
        clock.advance(timeout + MINUTE_MS)
        manager.touch()
        val afterFirst = manager.currentSession()
        manager.touch()
        clock.advance(MINUTE_MS)
        manager.touch()
        assertEquals(afterFirst, manager.currentSession())
        assertEquals(2, afterFirst.visitCount)
    }

    @Test
    fun currentSessionIsAPureSnapshotWithoutExpirySideEffects() {
        clock.advance(timeout + MINUTE_MS)
        // Reading identity must not rotate — only activity (touch/foreground) does.
        val read = manager.currentSession()
        assertEquals(1, read.visitCount)
        assertEquals(read, manager.currentSession())
    }

    // --- Foreground ---

    @Test
    fun foregroundAfterExpiryRotates() {
        val original = manager.currentSession()
        clock.advance(timeout + MINUTE_MS)
        manager.onForeground()
        val rotated = manager.currentSession()
        assertNotEquals(original.sessionId, rotated.sessionId)
        assertEquals(2, rotated.visitCount)
    }

    @Test
    fun foregroundInsideWindowKeepsSession() {
        val original = manager.currentSession()
        clock.advance(10 * MINUTE_MS)
        manager.onForeground()
        assertEquals(original, manager.currentSession())
    }

    // --- Monotonic correctness: wall clock changes mid-process are inert ---

    @Test
    fun wallClockJumpingForwardDoesNotRotate() {
        val original = manager.currentSession()
        clock.monotonic += 10 * MINUTE_MS
        clock.wall += 5 * 60 * MINUTE_MS // user sets clock 5 h ahead
        manager.touch()
        assertEquals(original, manager.currentSession())
    }

    @Test
    fun wallClockJumpingBackwardDoesNotRotate() {
        val original = manager.currentSession()
        clock.monotonic += 10 * MINUTE_MS
        clock.wall -= 5 * 60 * MINUTE_MS // NTP correction / timezone travel
        manager.touch()
        assertEquals(original, manager.currentSession())
    }

    @Test
    fun wallClockJumpingBackwardDoesNotImmortalizeEither() {
        // Wall says "only 1 min passed"; monotonic says 31 min — monotonic wins.
        clock.monotonic += timeout + MINUTE_MS
        clock.wall -= 29 * MINUTE_MS
        manager.touch()
        assertEquals(2, manager.currentSession().visitCount)
    }

    // --- Restart fallback (fresh monotonic epoch, persisted wall clock) ---

    @Test
    fun restartWithFreshWallClockKeepsSession() {
        manager.touch()
        val original = manager.currentSession()
        // Process restart 10 min later: monotonic resets to a tiny value.
        val rebooted = FakeClock(monotonic = 1_000L, wall = clock.wall + 10 * MINUTE_MS)
        val next = SessionManager(store, rebooted)
        assertEquals(original, next.currentSession())
    }

    @Test
    fun restartWithStaleWallClockRotates() {
        manager.touch()
        val original = manager.currentSession()
        val rebooted = FakeClock(monotonic = 1_000L, wall = clock.wall + timeout + MINUTE_MS)
        val next = SessionManager(store, rebooted)
        val rotated = next.currentSession()
        assertNotEquals(original.sessionId, rotated.sessionId)
        assertEquals(original.visitCount + 1, rotated.visitCount)
    }

    @Test
    fun restartCarriesIdleTimeIntoTheMonotonicWindow() {
        manager.touch()
        val original = manager.currentSession()
        // 20 idle minutes before the restart leave 10, not a fresh 30.
        val rebooted = FakeClock(monotonic = 1_000L, wall = clock.wall + 20 * MINUTE_MS)
        val next = SessionManager(store, rebooted)
        assertEquals(original, next.currentSession())
        rebooted.advance(11 * MINUTE_MS)
        next.touch()
        assertEquals(original.visitCount + 1, next.currentSession().visitCount)
    }

    @Test
    fun restartWithMissingLastActivityRotates() {
        manager.touch()
        store.values.remove(StorageKeys.LAST_ACTIVITY_WALL_MS)
        val next = SessionManager(store, FakeClock(monotonic = 1_000L, wall = clock.wall))
        assertEquals(2, next.currentSession().visitCount)
    }

    @Test
    fun restartWithFarFutureLastActivityRotates() {
        // Persisted timestamp 2 h in the future: the clock was rolled back
        // since the last run — untrusted, rotate.
        manager.touch()
        val rebooted = FakeClock(monotonic = 1_000L, wall = clock.wall - 2 * 60 * MINUTE_MS)
        val next = SessionManager(store, rebooted)
        assertEquals(2, next.currentSession().visitCount)
    }

    @Test
    fun restartWithSlightlyFutureLastActivityWithinToleranceKeepsSession() {
        manager.touch()
        val original = manager.currentSession()
        val rebooted = FakeClock(monotonic = 1_000L, wall = clock.wall - 30_000L)
        val next = SessionManager(store, rebooted)
        assertEquals(original, next.currentSession())
    }

    // --- Corrupt persisted state (SPEC §3: silent defaults, no throw) ---

    @Test
    fun corruptPersistedValuesStartAFreshSessionSilently() {
        store.values[StorageKeys.SESSION_ID] = 42 // wrong type
        store.values[StorageKeys.VISIT_COUNT] = "three" // garbage string
        store.values[StorageKeys.LAST_ACTIVITY_WALL_MS] = "yesterday"
        val recovered = SessionManager(store, clock)
        val session = recovered.currentSession()
        assertEquals(1, session.visitCount)
        assertTrue((store.values[StorageKeys.SESSION_ID] as String).isNotEmpty())
    }

    @Test
    fun corruptVisitCountWithLiveSessionDefaultsToOne() {
        manager.touch()
        store.values[StorageKeys.VISIT_COUNT] = "three"
        val next = SessionManager(store, FakeClock(monotonic = 1_000L, wall = clock.wall))
        assertEquals(1, next.currentSession().visitCount)
    }
}
