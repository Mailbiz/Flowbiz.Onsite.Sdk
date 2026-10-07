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

    @Test func firstLaunchCreatesSessionWithVisitCount1() {
        let session = manager.currentSession()
        #expect(session.visitCount == 1)
        #expect(UUID(uuidString: session.sessionId) != nil)
        #expect(session.sessionId == session.sessionId.lowercased())
        #expect(store[StorageKeys.sessionId] as? String == session.sessionId)
        #expect(store[StorageKeys.visitCount] as? Int == 1)
        #expect(store.int64(forKey: StorageKeys.lastActivityWallMs) == clock.wall)
    }

    @Test func touchInsideWindowSlidesWithoutRotating() {
        let original = manager.currentSession()
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
        let read = manager.currentSession()
        #expect(read.visitCount == 1)
        #expect(manager.currentSession() == read)
    }

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

    @Test func wallClockJumpingForwardDoesNotRotate() {
        let original = manager.currentSession()
        clock.monotonic += 10 * minuteMs
        clock.wall += 5 * 60 * minuteMs
        manager.touch()
        #expect(manager.currentSession() == original)
    }

    @Test func wallClockJumpingBackwardDoesNotRotate() {
        let original = manager.currentSession()
        clock.monotonic += 10 * minuteMs
        clock.wall -= 5 * 60 * minuteMs
        manager.touch()
        #expect(manager.currentSession() == original)
    }

    @Test func wallClockJumpingBackwardDoesNotImmortalizeEither() {
        clock.monotonic += timeout + minuteMs
        clock.wall -= 29 * minuteMs
        manager.touch()
        #expect(manager.currentSession().visitCount == 2)
    }

    @Test func restartWithFreshWallClockKeepsSession() {
        manager.touch()
        let original = manager.currentSession()
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

    @Test func corruptPersistedValuesStartAFreshSessionSilently() {
        store[StorageKeys.sessionId] = 42
        store[StorageKeys.visitCount] = "three"
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
        #expect(next.currentSession().visitCount == 1)
        #expect(fresh[StorageKeys.visitCount] as? Int == 1)
    }

    @Test func rotateForcesANewSessionAndIncrementsVisitCount() {
        let original = manager.currentSession()
        manager.rotate()
        let rotated = manager.currentSession()
        #expect(rotated.sessionId != original.sessionId)
        #expect(rotated.visitCount == original.visitCount + 1)
        #expect(store[StorageKeys.sessionId] as? String == rotated.sessionId)
        #expect(store[StorageKeys.visitCount] as? Int == rotated.visitCount)
    }

    @Test func rotateReanchorsTheInactivityWindow() {
        clock.advance(29 * minuteMs)
        manager.rotate()
        let rotated = manager.currentSession()
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
