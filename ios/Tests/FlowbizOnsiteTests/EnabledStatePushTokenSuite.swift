// SPEC §12 enabled switch + SPEC §10.1 push token cell persistence.
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct EnabledStatePushTokenSuite {

    private let store = FakeKeyValueStore()

    // MARK: EnabledState

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
        store[StorageKeys.enabled] = "yes" // wrong type -> silent default
        #expect(EnabledState(store: store).isEnabled)
    }

    // MARK: PushTokenStore

    @Test func pushTokenDefaultsToNil() {
        #expect(PushTokenStore(store: store).token == nil)
    }

    @Test func pushTokenSetPersistsAcrossInstances() {
        PushTokenStore(store: store).set("apns-token-abc123")
        #expect(PushTokenStore(store: store).token == "apns-token-abc123")
    }

    @Test func pushTokenClearRemovesIt() {
        let tokens = PushTokenStore(store: store)
        tokens.set("apns-token-abc123")
        tokens.clear()
        #expect(tokens.token == nil)
        #expect(store[StorageKeys.pushToken] == nil)
    }

    @Test func corruptPushTokenReadsAsNil() {
        store[StorageKeys.pushToken] = 42
        #expect(PushTokenStore(store: store).token == nil)
    }
}
#endif
