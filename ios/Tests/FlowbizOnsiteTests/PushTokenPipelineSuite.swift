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
        #expect(object(entry, "identity")["session_id"] != nil)
        #expect(object(entry, "context")["platform"] as? String == "ios")
        #expect(harness.store[StorageKeys.pushToken] as? String == "apns-token-1")
    }

    @Test func identicalTokenWithinDedupWindowIsSuppressed() throws {
        let harness = CoreHarness()
        harness.core.setPushToken("apns-token-1")
        harness.core.setPushToken("apns-token-1")
        #expect(try entries(harness, event: "push.token.sync").count == 1)
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
        let sentBefore = try harness.sentEntries().count
        harness.core.removePushToken()
        #expect(try harness.sentEntries().count == sentBefore)
    }

    @Test func removeWithoutStoredTokenIsNoOp() throws {
        let harness = CoreHarness()
        harness.core.removePushToken()
        #expect(try harness.sentEntries().isEmpty)
    }

    @Test func logoutEmitsRemovalCarryingTheOutgoingUserIdBeforeClearingIdentity() throws {
        let harness = CoreHarness()
        harness.core.track(.accountLogin(user: User(userId: "u-42", email: "a@b.c")))
        harness.core.setPushToken("apns-token-1")
        harness.core.logout()
        let removal = try #require(try entries(harness, event: "push.token.remove").last)
        #expect(object(removal, "identity")["user_id"] as? String == "u-42")
        #expect(removal["data"] as? String == #"{"platform":"ios","token":"apns-token-1"}"#)
        #expect(harness.store[StorageKeys.pushToken] == nil)
        #expect(harness.store[StorageKeys.userId] == nil)
    }

    @Test func logoutWithoutTokenEmitsNoRemoval() throws {
        let harness = CoreHarness()
        harness.core.track(.accountLogin(user: User(userId: "u-42", email: "a@b.c")))
        harness.core.logout()
        #expect(try entries(harness, event: "push.token.remove").isEmpty)
    }

    @Test func disabledDropsEventsButStillPersistsAndClearsTheToken() throws {
        let harness = CoreHarness()
        harness.core.setEnabled(false)
        harness.core.setPushToken("apns-token-1")
        #expect(try harness.sentEntries().isEmpty)
        #expect(harness.store[StorageKeys.pushToken] as? String == "apns-token-1")
        harness.core.setEnabled(true)
        harness.core.removePushToken()
        let entry = try harness.lastEntry()
        #expect(entry["event"] as? String == "push.token.remove")
        #expect(entry["data"] as? String == #"{"platform":"ios","token":"apns-token-1"}"#)
        #expect(harness.store[StorageKeys.pushToken] == nil)
    }

    @Test func removeClearsTheSyncDedupAnchorSoTheSameTokenResyncs() throws {
        let harness = CoreHarness()
        harness.core.setPushToken("apns-token-1")
        harness.core.removePushToken()
        harness.core.setPushToken("apns-token-1")
        #expect(try entries(harness, event: "push.token.sync").count == 2)
    }

    @Test func logoutRemovalAlsoClearsTheSyncDedupAnchor() throws {
        let harness = CoreHarness()
        harness.core.setPushToken("apns-token-1")
        harness.core.logout()
        harness.core.setPushToken("apns-token-1")
        #expect(try entries(harness, event: "push.token.sync").count == 2)
    }

    @Test func reEnableReEmitsSyncForTheStoredToken() throws {
        let harness = CoreHarness()
        harness.core.setEnabled(false)
        harness.core.setPushToken("apns-token-1")
        #expect(try harness.sentEntries().isEmpty)
        harness.core.setEnabled(true)
        let syncs = try entries(harness, event: "push.token.sync")
        #expect(syncs.count == 1)
        #expect(syncs.first?["data"] as? String == #"{"platform":"ios","token":"apns-token-1"}"#)
    }

    @Test func reEnableWithoutAStoredTokenEmitsNoSync() throws {
        let harness = CoreHarness()
        harness.core.setEnabled(false)
        harness.core.setEnabled(true)
        #expect(try entries(harness, event: "push.token.sync").isEmpty)
    }

    @Test func reEnableReEmitIsSuppressedWhenTheTokenWasAlreadySyncedWithinTheWindow() throws {
        let harness = CoreHarness()
        harness.core.setPushToken("apns-token-1")
        harness.core.setEnabled(false)
        harness.core.setEnabled(true)
        #expect(try entries(harness, event: "push.token.sync").count == 1)
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

    @Test func facadeBlankTokenIsANoOp() {
        Flowbiz.setPushToken("   ")
        Flowbiz.removePushToken()
    }
}
#endif
