// SPEC §10.1 token relay through the normal pipeline: `push.token.sync` /
// `push.token.remove` are queued, deduped and session-touched like any
// event, and `logout()` emits the removal *before* clearing identity so the
// event carries the outgoing `user_id`.
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct PushTokenPipelineSuite {

    private func entries(_ harness: CoreHarness, event: String) throws -> [[String: Any]] {
        try harness.sentEntries().filter { $0["event"] as? String == event }
    }

    @Test func setPushTokenEmitsSyncEventWithTokenAndPlatform() throws {
        let harness = CoreHarness()
        harness.core.setPushToken("apns-token-1")
        let entry = try harness.lastEntry()
        #expect(entry["event"] as? String == "push.token.sync")
        #expect(entry["data"] as? String == #"{"platform":"ios","token":"apns-token-1"}"#)
        // Normal envelope machinery: identity/session/context all present.
        #expect(object(entry, "identity")["session_id"] != nil)
        #expect(object(entry, "context")["platform"] as? String == "ios")
        // And the token is persisted for a later logout/remove.
        #expect(harness.store[StorageKeys.pushToken] as? String == "apns-token-1")
    }

    @Test func identicalTokenWithinDedupWindowIsSuppressed() throws {
        let harness = CoreHarness()
        harness.core.setPushToken("apns-token-1")
        harness.core.setPushToken("apns-token-1")
        #expect(try entries(harness, event: "push.token.sync").count == 1)
        // A different token is a different payload -> sent.
        harness.core.setPushToken("apns-token-2")
        #expect(try entries(harness, event: "push.token.sync").count == 2)
    }

    @Test func removePushTokenEmitsRemoveWithStoredTokenAndClearsIt() throws {
        let harness = CoreHarness()
        harness.core.setPushToken("apns-token-1")
        harness.core.removePushToken()
        let entry = try harness.lastEntry()
        #expect(entry["event"] as? String == "push.token.remove")
        #expect(entry["data"] as? String == #"{"platform":"ios","token":"apns-token-1"}"#)
        #expect(harness.store[StorageKeys.pushToken] == nil)
        // Second remove: nothing stored -> no event.
        let sentBefore = try harness.sentEntries().count
        harness.core.removePushToken()
        #expect(try harness.sentEntries().count == sentBefore)
    }

    @Test func removeWithoutStoredTokenIsNoOp() throws {
        let harness = CoreHarness()
        harness.core.removePushToken()
        #expect(try harness.sentEntries().isEmpty)
    }

    /// Decision under review: removal is emitted BEFORE the identity clear so it carries user_id.
    @Test func logoutEmitsRemovalCarryingTheOutgoingUserIdBeforeClearingIdentity() throws {
        let harness = CoreHarness()
        harness.core.track(.accountLogin(user: User(userId: "u-42", email: "a@b.c")))
        harness.core.setPushToken("apns-token-1")
        harness.core.logout()
        let removal = try #require(try entries(harness, event: "push.token.remove").last)
        #expect(object(removal, "identity")["user_id"] as? String == "u-42")
        #expect(removal["data"] as? String == #"{"platform":"ios","token":"apns-token-1"}"#)
        // After logout: token gone, identity gone.
        #expect(harness.store[StorageKeys.pushToken] == nil)
        #expect(harness.store[StorageKeys.userId] == nil)
    }

    @Test func logoutWithoutTokenEmitsNoRemoval() throws {
        let harness = CoreHarness()
        harness.core.track(.accountLogin(user: User(userId: "u-42", email: "a@b.c")))
        harness.core.logout()
        #expect(try entries(harness, event: "push.token.remove").isEmpty)
    }

    /// Decision under review (SPEC §12): while disabled, token events are
    /// dropped like any event, but the token cell is still persisted/cleared
    /// so a later enable acts on the true registration state.
    @Test func disabledDropsEventsButStillPersistsAndClearsTheToken() throws {
        let harness = CoreHarness()
        harness.core.setEnabled(false)
        harness.core.setPushToken("apns-token-1")
        #expect(try harness.sentEntries().isEmpty)
        #expect(harness.store[StorageKeys.pushToken] as? String == "apns-token-1")
        // Re-enabled: the persisted token backs a coherent removal.
        harness.core.setEnabled(true)
        harness.core.removePushToken()
        let entry = try harness.lastEntry()
        #expect(entry["event"] as? String == "push.token.remove")
        #expect(entry["data"] as? String == #"{"platform":"ios","token":"apns-token-1"}"#)
        #expect(harness.store[StorageKeys.pushToken] == nil)
    }

    @Test func disabledRemoveStillClearsTheStoredToken() throws {
        let harness = CoreHarness()
        harness.core.setPushToken("apns-token-1")
        harness.core.setEnabled(false)
        let sentBefore = try harness.sentEntries().count
        harness.core.removePushToken()
        #expect(try harness.sentEntries().count == sentBefore)
        #expect(harness.store[StorageKeys.pushToken] == nil)
    }

    /// SPEC §3 facade behavior: pre-initialize calls are silent no-ops
    /// (pinned here for the two new pipeline entry points; the pure
    /// handlers are covered by their own suites).
    @Test func facadeBlankTokenIsANoOp() {
        // Blank token short-circuits before the core lookup — nothing to observe
        // beyond "does not crash" without initialize; the guard is also what
        // keeps a blank token from ever reaching the pipeline.
        Flowbiz.setPushToken("   ")
        Flowbiz.removePushToken()
    }
}
#endif
