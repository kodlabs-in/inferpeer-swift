import InferPeerInference
import InferPeerStorage
import Testing

@Suite("SQLite model store")
struct SQLiteModelStoreTests {
    @Test("Persists and deduplicates an exact local artifact")
    func persistsAndDeduplicates() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let artifact = try makeModelArtifact()
        let store = try testDatabase.makeModelStore()

        let first = try await store.register(artifact)
        let duplicate = try await store.register(artifact)
        try store.close()
        let reopenedStore = try testDatabase.makeModelStore()
        defer { try? reopenedStore.close() }
        let restored = try await reopenedStore.model(reference: artifact.descriptor.reference)

        guard case .registered(let registered) = first,
            case .duplicate(let repeated) = duplicate
        else {
            Issue.record("Expected a new registration followed by a duplicate")
            return
        }
        #expect(registered == repeated)
        #expect(restored == registered)
        #expect(try await reopenedStore.models() == [registered])
    }

    @Test("Rejects changes to an already registered exact revision")
    func rejectsRegistrationConflict() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let store = try testDatabase.makeModelStore()
        defer { try? store.close() }
        _ = try await store.register(makeModelArtifact())

        await #expect(throws: SQLiteStorageError.modelRegistrationConflict) {
            try await store.register(makeModelArtifact(directoryPath: "/models/other"))
        }
        await #expect(throws: SQLiteStorageError.modelRegistrationConflict) {
            try await store.register(makeModelArtifact(digestByte: 0xD4))
        }
    }

    @Test("Removes only the selected registry entry")
    func removesRegistration() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let store = try testDatabase.makeModelStore()
        defer { try? store.close() }
        let artifact = try makeModelArtifact()
        _ = try await store.register(artifact)

        try await store.remove(reference: artifact.descriptor.reference)

        #expect(try await store.model(reference: artifact.descriptor.reference) == nil)
        #expect(try await store.models().isEmpty)
    }
}
