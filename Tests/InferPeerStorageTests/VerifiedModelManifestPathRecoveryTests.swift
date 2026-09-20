import Foundation
import InferPeerStorage
import Testing

@Suite("Verified model manifest path recovery")
struct VerifiedModelManifestPathRecoveryTests {
    @Test("Legacy absolute registrations rebase after their model root moves")
    func rebasesLegacyAbsoluteRegistration() async throws {
        let fixture = try ModelManifestFixture()
        let relocatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: relocatedRoot)
        }
        let databaseURL = fixture.installRoot.appendingPathComponent("registry.sqlite")
        let legacyStore = try SQLiteVerifiedModelManifestStore(databaseURL: databaseURL)
        let result = try await legacyStore.register(
            fixture.manifest,
            stagingDirectory: fixture.stagingDirectory,
            installRoot: fixture.installRoot
        )
        let registered = try registeredValue(result)
        try await legacyStore.close()
        try FileManager.default.moveItem(at: fixture.installRoot, to: relocatedRoot)

        let reopened = try SQLiteVerifiedModelManifestStore(
            databaseURL: relocatedRoot.appendingPathComponent("registry.sqlite"),
            modelRootDirectory: relocatedRoot
        )
        let recovered = try #require(try await reopened.model(key: registered.verified.key))

        #expect(recovered.verified.directoryURL.path.hasPrefix(relocatedRoot.path))
        #expect(FileManager.default.fileExists(atPath: recovered.verified.directoryURL.path))
        try await reopened.close()
    }

    private func registeredValue(
        _ result: VerifiedModelRegistrationResult
    ) throws -> StoredVerifiedModelManifest {
        guard case .registered(let registration) = result else {
            Issue.record("Expected a new manifest registration")
            throw PathRecoveryTestError.unexpectedResult
        }
        return registration
    }
}

private enum PathRecoveryTestError: Error {
    case unexpectedResult
}
