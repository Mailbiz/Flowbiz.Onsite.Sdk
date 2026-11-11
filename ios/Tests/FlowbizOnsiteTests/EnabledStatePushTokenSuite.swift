#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct EnabledStatePushTokenSuite {

    private let store = FakeKeyValueStore()
    private let tokenFile = temporaryQueueFile().deletingLastPathComponent().appendingPathComponent("push_token")

    @Test func enabledDefaultsToTrue() {
        #expect(EnabledState(store: store).isEnabled)
    }

    @Test func setEnabledFalsePersistsAcrossInstances() {
        EnabledState(store: store).setEnabled(false)
        #expect(!EnabledState(store: store).isEnabled)
    }

    @Test func reEnablingPersists() {
        let state = EnabledState(store: store)
        state.setEnabled(false)
        state.setEnabled(true)
        #expect(EnabledState(store: store).isEnabled)
    }

    @Test func corruptEnabledValueReadsAsEnabled() {
        store[StorageKeys.enabled] = "yes"
        #expect(EnabledState(store: store).isEnabled)
    }

    private func tokens() -> PushTokenStore {
        PushTokenStore(fileURL: { [tokenFile] in tokenFile }, legacy: store)
    }

    private var fileToken: String? {
        try? String(contentsOf: tokenFile, encoding: .utf8)
    }

    @Test func pushTokenDefaultsToNil() {
        #expect(tokens().token == nil)
    }

    @Test func pushTokenSetPersistsAcrossInstancesInTheFileNeverInTheBackedUpStore() {
        tokens().set("apns-token-abc123")
        #expect(tokens().token == "apns-token-abc123")
        #expect(fileToken == "apns-token-abc123")
        #expect(store.values.isEmpty)
    }

    @Test func pushTokenClearRemovesIt() {
        let tokens = tokens()
        tokens.set("apns-token-abc123")
        tokens.clear()
        #expect(tokens.token == nil)
        #expect(self.tokens().token == nil)
        #expect(!FileManager.default.fileExists(atPath: tokenFile.path))
    }

    @Test func theTokenOfTheDefaultsMovesToTheFileOnce() {
        store[StorageKeys.pushToken] = "apns-token-0.1"
        #expect(tokens().token == "apns-token-0.1")
        #expect(fileToken == "apns-token-0.1")
        #expect(store[StorageKeys.pushToken] == nil)
    }

    @Test func aTokenInTheDefaultsNeverReplacesTheOneInTheFile() {
        tokens().set("apns-token-this-phone")
        store[StorageKeys.pushToken] = "apns-token-restored"
        #expect(tokens().token == "apns-token-this-phone")
        #expect(store[StorageKeys.pushToken] == nil)
    }

    @Test func clearingAlsoDropsATokenStillInTheDefaults() {
        store[StorageKeys.pushToken] = "apns-token-0.1"
        tokens().clear()
        #expect(tokens().token == nil)
        #expect(store[StorageKeys.pushToken] == nil)
    }

    @Test func anUnusableFileReadsAsNoToken() {
        let directory = FileManager.default.temporaryDirectory
        let tokens = PushTokenStore(fileURL: { directory }, legacy: store)
        tokens.set("apns-token-abc123")
        #expect(tokens.token == nil)
        tokens.clear()
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }
}
#endif
