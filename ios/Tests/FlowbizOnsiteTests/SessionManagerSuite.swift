// SPEC §6 session mechanics: 30-min sliding window on the monotonic clock,
// wall clock only as the cross-restart fallback.
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct SessionManagerSuite {

    private let timeout = SessionManager.sessionTimeoutMillis
    private let store = FakeKeyValueStore()
    private let clock = FakeClock()
    private let manager: SessionManager

    init() {
        manager = SessionManager(store: store, clock: clock)
    }

    // MARK: First launch

    @Test func firstLaunchCreatesSessionWithVisitCount1() {
        let session = manager.currentSession()
        #expect(session.visitCount == 1)
        #expect(UUID(uuidString: session.sessionId) != nil)
        #expect(session.sessionId == session.sessionId.lowercased())
        // Persisted immediately so a crash before the first event keeps the visit.
        #expect(store[StorageKeys.sessionId] as? String == session.sessionId)
        #expect(store[StorageKeys.visitCount] as? Int == 1)
        #expect(store.int64(forKey: StorageKeys.lastActivityWallMs) == clock.wall)
    }

    // MARK: Sliding window (in-process, monotonic)

    @Test func touchInsideWindowSlidesWithoutRotating() {
        let original = manager.currentSession()
        // Four touches 29 min apart: 116 min of wall time total, but the
        // window slides on every touch — no rotation.
        for _ in 0..<4 {
            clock.advance(29 * minuteMs)
            manager.touch()
        }
        #expect(manager.currentSession() == original)
    }

    @Test func touchJustUnderThirtyMinutesSlides() {
        let original = manager.currentSession()
        clock.advance(timeout - 1)
        manager.touch()
        #expect(manager.currentSession() == original)
    }

    @Test func touchAtExactlyThirtyMinutesRotates() {
        // Boundary is inclusive: elapsed >= 30:00.000 rotates ("after >= 30
        // min of inactivity", SPEC §6).
        let original = manager.currentSession()
        clock.advance(timeout)
        manager.touch()
        let rotated = manager.currentSession()
        #expect(rotated.sessionId != original.sessionId)
        #expect(rotated.visitCount == original.visitCount + 1)
    }

    @Test func touchAfterExpiryRotatesAndPersists() {
        clock.advance(timeout + 5 * minuteMs)
        manager.touch()
        let rotated = manager.currentSession()
        #expect(rotated.visitCount == 2)
        #expect(store[StorageKeys.sessionId] as? String == rotated.sessionId)
        #expect(store[StorageKeys.visitCount] as? Int == 2)
    }

    @Test func multipleTouchesAfterExpiryRotateExactlyOnce() {
        clock.advance(timeout + minuteMs)
        manager.touch()
        let afterFirst = manager.currentSession()
        manager.touch()
        clock.advance(minuteMs)
        manager.touch()
        #expect(manager.currentSession() == afterFirst)
        #expect(afterFirst.visitCount == 2)
    }

    @Test func currentSessionIsAPureSnapshotWithoutExpirySideEffects() {
        clock.advance(timeout + minuteMs)
        // Reading identity must not rotate — only activity (touch/foreground) does.
        let read = manager.currentSession()
        #expect(read.visitCount == 1)
        #expect(manager.currentSession() == read)
    }

    // MARK: Foreground

    @Test func foregroundAfterExpiryRotates() {
        let original = manager.currentSession()
        clock.advance(timeout + minuteMs)
        manager.onForeground()
        let rotated = manager.currentSession()
        #expect(rotated.sessionId != original.sessionId)
        #expect(rotated.visitCount == 2)
    }

    @Test func foregroundInsideWindowKeepsSession() {
        let original = manager.currentSession()
        clock.advance(10 * minuteMs)
        manager.onForeground()
        #expect(manager.currentSession() == original)
    }

    // MARK: Monotonic correctness — wall clock changes mid-process are inert

    @Test func wallClockJumpingForwardDoesNotRotate() {
        let original = manager.currentSession()
        clock.monotonic += 10 * minuteMs
        clock.wall += 5 * 60 * minuteMs // user sets clock 5 h ahead
        manager.touch()
        #expect(manager.currentSession() == original)
    }

    @Test func wallClockJumpingBackwardDoesNotRotate() {
        let original = manager.currentSession()
        clock.monotonic += 10 * minuteMs
        clock.wall -= 5 * 60 * minuteMs // NTP correction / timezone travel
        manager.touch()
        #expect(manager.currentSession() == original)
    }

    @Test func wallClockJumpingBackwardDoesNotImmortalizeEither() {
        // Wall says "only 1 min passed"; monotonic says 31 min — monotonic wins.
        clock.monotonic += timeout + minuteMs
        clock.wall -= 29 * minuteMs
        manager.touch()
        #expect(manager.currentSession().visitCount == 2)
    }

    // MARK: Restart fallback (fresh monotonic epoch, persisted wall clock)

    @Test func restartWithFreshWallClockKeepsSession() {
        manager.touch()
        let original = manager.currentSession()
        // Process restart 10 min later: monotonic resets to a tiny value.
        let rebooted = FakeClock(monotonic: 1_000, wall: clock.wall + 10 * minuteMs)
        let next = SessionManager(store: store, clock: rebooted)
        #expect(next.currentSession() == original)
    }

    @Test func restartWithStaleWallClockRotates() {
        manager.touch()
        let original = manager.currentSession()
        let rebooted = FakeClock(monotonic: 1_000, wall: clock.wall + timeout + minuteMs)
        let next = SessionManager(store: store, clock: rebooted)
        let rotated = next.currentSession()
        #expect(rotated.sessionId != original.sessionId)
        #expect(rotated.visitCount == original.visitCount + 1)
    }

    @Test func restartCarriesIdleTimeIntoTheMonotonicWindow() {
        manager.touch()
        let original = manager.currentSession()
        // 20 idle minutes before the restart leave 10, not a fresh 30.
        let rebooted = FakeClock(monotonic: 1_000, wall: clock.wall + 20 * minuteMs)
        let next = SessionManager(store: store, clock: rebooted)
        #expect(next.currentSession() == original)
        rebooted.advance(11 * minuteMs)
        next.touch()
        #expect(next.currentSession().visitCount == original.visitCount + 1)
    }

    @Test func restartWithMissingLastActivityRotates() {
        manager.touch()
        store[StorageKeys.lastActivityWallMs] = nil
        let next = SessionManager(store: store, clock: FakeClock(monotonic: 1_000, wall: clock.wall))
        #expect(next.currentSession().visitCount == 2)
    }

    @Test func restartWithFarFutureLastActivityRotates() {
        // Persisted timestamp 2 h in the future: the clock was rolled back
        // since the last run — untrusted, rotate.
        manager.touch()
        let rebooted = FakeClock(monotonic: 1_000, wall: clock.wall - 2 * 60 * minuteMs)
        let next = SessionManager(store: store, clock: rebooted)
        #expect(next.currentSession().visitCount == 2)
    }

    @Test func restartWithSlightlyFutureLastActivityWithinToleranceKeepsSession() {
        manager.touch()
        let original = manager.currentSession()
        let rebooted = FakeClock(monotonic: 1_000, wall: clock.wall - 30_000)
        let next = SessionManager(store: store, clock: rebooted)
        #expect(next.currentSession() == original)
    }

    // MARK: Corrupt persisted state (SPEC §3: silent defaults, no throw)

    @Test func corruptPersistedValuesStartAFreshSessionSilently() {
        store[StorageKeys.sessionId] = 42 // wrong type
        store[StorageKeys.visitCount] = "three" // garbage string
        store[StorageKeys.lastActivityWallMs] = "yesterday"
        let recovered = SessionManager(store: store, clock: clock)
        let session = recovered.currentSession()
        #expect(session.visitCount == 1)
        #expect((store[StorageKeys.sessionId] as? String)?.isEmpty == false)
    }

    @Test func corruptVisitCountWithLiveSessionDefaultsToOne() {
        manager.touch()
        store[StorageKeys.visitCount] = "three"
        let next = SessionManager(store: store, clock: FakeClock(monotonic: 1_000, wall: clock.wall))
        #expect(next.currentSession().visitCount == 1)
    }

    @Test func nonUuidShapedStoredSessionIdRotatesAtInit() {
        manager.touch()
        store[StorageKeys.sessionId] = "definitely-not-a-uuid"
        let next = SessionManager(store: store, clock: FakeClock(monotonic: 1_000, wall: clock.wall))
        let session = next.currentSession()
        #expect(session.sessionId != "definitely-not-a-uuid")
        #expect(UUID(uuidString: session.sessionId) != nil)
        #expect(session.visitCount == 2)
    }

    @Test func negativeStoredVisitCountClampsToOneOnRotation() {
        let fresh = FakeKeyValueStore()
        fresh[StorageKeys.visitCount] = -7
        let next = SessionManager(store: fresh, clock: FakeClock())
        // max(0, stored) + 1 — never 0 or negative on the wire.
        #expect(next.currentSession().visitCount == 1)
        #expect(fresh[StorageKeys.visitCount] as? Int == 1)
    }

    // MARK: Forced rotation (logout support, Slice 4)

    @Test func rotateForcesANewSessionAndIncrementsVisitCount() {
        let original = manager.currentSession()
        manager.rotate()
        let rotated = manager.currentSession()
        #expect(rotated.sessionId != original.sessionId)
        #expect(rotated.visitCount == original.visitCount + 1)
        // Persisted immediately.
        #expect(store[StorageKeys.sessionId] as? String == rotated.sessionId)
        #expect(store[StorageKeys.visitCount] as? Int == rotated.visitCount)
    }

    @Test func rotateReanchorsTheInactivityWindow() {
        clock.advance(29 * minuteMs)
        manager.rotate()
        let rotated = manager.currentSession()
        // 29 more minutes: within the freshly-anchored window — no rotation.
        clock.advance(29 * minuteMs)
        manager.touch()
        #expect(manager.currentSession() == rotated)
    }

    @Test func rotateInsideAnExpiredWindowIncrementsExactlyOnce() {
        let original = manager.currentSession()
        clock.advance(timeout + minuteMs)
        manager.rotate()
        #expect(manager.currentSession().visitCount == original.visitCount + 1)
    }
}
#endif
