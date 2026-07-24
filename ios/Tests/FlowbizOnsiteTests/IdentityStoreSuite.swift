// SPEC §6 identity persistence over the injected KeyValueStore.
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct IdentityStoreSuite {

    private let store = FakeKeyValueStore()
    private var identity: IdentityStore { IdentityStore(store: store) }

    private func isLowercaseUuidV4(_ value: String) -> Bool {
        value.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
            options: .regularExpression
        ) != nil
    }

    @Test func anonymousIdIsLowercaseUuidV4() {
        #expect(isLowercaseUuidV4(identity.anonymousId))
    }

    @Test func anonymousIdGeneratedOnceThenStable() {
        let identity = self.identity
        let first = identity.anonymousId
        #expect(identity.anonymousId == first)
        // ... and it is the persisted value, not per-instance state.
        #expect(store[StorageKeys.anonymousId] as? String == first)
    }

    @Test func anonymousIdStableAcrossInstancesSharingAStore() {
        let first = identity.anonymousId
        #expect(IdentityStore(store: store).anonymousId == first)
    }

    @Test func distinctStoresGetDistinctAnonymousIds() {
        #expect(identity.anonymousId != IdentityStore(store: FakeKeyValueStore()).anonymousId)
    }

    @Test func corruptAnonymousIdSilentlyRegenerated() {
        store[StorageKeys.anonymousId] = "definitely-not-a-uuid"
        let regenerated = identity.anonymousId
        #expect(isLowercaseUuidV4(regenerated))
        #expect(store[StorageKeys.anonymousId] as? String == regenerated)
    }

    @Test func wrongTypeAnonymousIdSilentlyRegenerated() {
        store[StorageKeys.anonymousId] = 12345
        #expect(isLowercaseUuidV4(identity.anonymousId))
    }

    @Test func uppercaseAnonymousIdNormalizedInPlace() {
        store[StorageKeys.anonymousId] = "A3B1C5D7-1111-4222-8333-444455556666"
        #expect(identity.anonymousId == "a3b1c5d7-1111-4222-8333-444455556666")
        #expect(store[StorageKeys.anonymousId] as? String == "a3b1c5d7-1111-4222-8333-444455556666")
    }

    @Test func userDefaultsToSignedOut() {
        #expect(identity.userId == nil)
        #expect(identity.email == nil)
    }

    @Test func setUserPersistsAcrossInstances() {
        identity.setUser(userId: "98412", email: "ana@example.com")
        let reloaded = IdentityStore(store: store)
        #expect(reloaded.userId == "98412")
        #expect(reloaded.email == "ana@example.com")
    }

    @Test func clearUserRemovesUserButKeepsAnonymousId() {
        let identity = self.identity
        let anonymous = identity.anonymousId
        identity.setUser(userId: "98412", email: "ana@example.com")
        identity.clearUser()
        #expect(identity.userId == nil)
        #expect(identity.email == nil)
        #expect(identity.anonymousId == anonymous)
    }
}
#endif
