import InferPeerCore
import InferPeerProtocol
import InferPeerStorage
import Testing

@Suite("SQLite peer store")
struct SQLitePeerStoreTests {
    @Test("Persists approved roles across reopening")
    func persistsApproval() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let identity = try makePeerIdentity()
        let store = try testDatabase.makePeerStore()
        let approved = try await store.approve(identity, roles: [.caller, .worker])
        try store.close()
        let reopenedStore = try testDatabase.makePeerStore()
        defer { try? reopenedStore.close() }

        let restored = try await reopenedStore.membership(peerID: identity.peerID)
        let active = try await reopenedStore.activeMemberships()

        #expect(approved.roles == [.caller, .worker])
        #expect(restored == approved)
        #expect(active == [approved])
    }

    @Test("Rejects empty roles and active certificate replacement")
    func rejectsUnsafeApproval() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let store = try testDatabase.makePeerStore()
        defer { try? store.close() }
        let identity = try makePeerIdentity()

        await #expect(throws: SQLiteStorageError.emptyPeerRoles) {
            try await store.approve(identity, roles: [])
        }
        _ = try await store.approve(identity, roles: [.worker])
        await #expect(throws: SQLiteStorageError.peerIdentityConflict) {
            try await store.approve(makePeerIdentity(fingerprintByte: 0x6B), roles: [.worker])
        }
    }

    @Test("Revokes, explicitly reapproves, and forgets a peer")
    func managesMembershipLifecycle() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let store = try testDatabase.makePeerStore()
        defer { try? store.close() }
        let identity = try makePeerIdentity()
        _ = try await store.approve(identity, roles: [.worker])

        try await store.revoke(peerID: identity.peerID)
        #expect(try await store.activeMemberships().isEmpty)
        #expect(try await store.membership(peerID: identity.peerID)?.revokedAt != nil)

        let replacement = try makePeerIdentity(fingerprintByte: 0x7C)
        let reapproved = try await store.approve(replacement, roles: [.coordinator])
        #expect(reapproved.revokedAt == nil)
        #expect(reapproved.identity == replacement)

        try await store.forget(peerID: identity.peerID)
        #expect(try await store.membership(peerID: identity.peerID) == nil)
    }

    @Test("Implements Core's durable trust contract")
    func implementsTrustRepository() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let store = try testDatabase.makePeerStore()
        defer { try? store.close() }
        let repository: any PeerTrustRepository = store
        let identity = try makePeerIdentity()

        try await repository.recordApproval(identity, roles: [.worker])
        #expect(try await repository.trustRecord(peerID: identity.peerID)?.identity == identity)
        #expect(try await repository.trustRecord(peerID: identity.peerID)?.roles == [.worker])

        try await repository.recordRevocation(peerID: identity.peerID)
        #expect(try await repository.trustRecord(peerID: identity.peerID)?.revokedAt != nil)
    }
}
