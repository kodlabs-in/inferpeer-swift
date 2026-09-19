import Foundation
import GRDB
import InferPeerCore
import InferPeerInference
import InferPeerModelStore
import Testing

@Suite("Model store path recovery")
struct ModelStorePathRecoveryTests {
    @Test("Installed models survive an app-container path change")
    func rebasesInstalledModelsAfterContainerMove() async throws {
        let fixture = try ModelStoreFixture()
        let relocatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: relocatedRoot)
        }
        let downloader = MemoryModelDownloader(data: fixture.data)
        let adapter = TestRuntimeAdapter()
        let store = try await InferPeerModelStore.open(
            configuration: fixture.configuration(downloader: downloader, adapters: [adapter])
        )
        let installation = try await store.install(
            fixture.entry.metadata.key,
            task: .textGeneration,
            on: makeDevice(),
            authorization: ModelDownloadAuthorization(resourceID: .local)
        )
        let original = try #require(try await collect(installation).installed)
        try await markInstallationsCorrupt(in: fixture.root)
        try FileManager.default.moveItem(at: fixture.root, to: relocatedRoot)

        let reopened = try await InferPeerModelStore.open(
            configuration: try relocatedConfiguration(
                fixture: fixture,
                root: relocatedRoot,
                downloader: downloader,
                adapter: adapter
            )
        )
        let recovered = try #require(try await reopened.installedModels().first)

        #expect(recovered.key == original.key)
        #expect(recovered.directoryURL.path.hasPrefix(relocatedRoot.path))
        #expect(try await reopened.status(of: recovered.key)?.state == .installed)
        #expect(await downloader.calls == 1)
    }

    private func markInstallationsCorrupt(in root: URL) async throws {
        let database = try DatabaseQueue(path: root.appendingPathComponent("registry.sqlite").path)
        try await database.write { database in
            try database.execute(
                sql: "UPDATE installations SET state = ?",
                arguments: [ModelInstallationState.corrupt.rawValue]
            )
        }
    }

    private func relocatedConfiguration(
        fixture: ModelStoreFixture,
        root: URL,
        downloader: MemoryModelDownloader,
        adapter: TestRuntimeAdapter
    ) throws -> InferPeerModelStoreConfiguration {
        try InferPeerModelStoreConfiguration(
            rootDirectory: root,
            builtInCatalog: fixture.signedCatalog(),
            trustedCatalogKeys: [fixture.keyID: fixture.privateKey.publicKey.rawRepresentation],
            runtimeAdapters: [adapter],
            services: .init(downloader: downloader)
        )
    }
}
