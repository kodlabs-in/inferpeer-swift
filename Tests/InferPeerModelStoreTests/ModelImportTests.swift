import Foundation
import InferPeerModelStore
import InferPeerStorage
import Testing

@Suite("Model package import")
struct ModelImportTests {
    @Test("A local manifest URL drives the same verified import path")
    func importsWithManifestURL() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let store = try await makeStore(fixture)
        let source = try writeSource(fixture)
        let manifestURL = fixture.root.appendingPathComponent("import-manifest.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(fixture.entry).write(to: manifestURL)

        let installed = try await store.importModel(
            from: source,
            manifest: manifestURL,
            on: makeDevice()
        )

        #expect(installed.manifest == fixture.entry.manifest)
        #expect(try await store.installedModels().map(\.key) == [installed.key])
    }

    @Test("Undeclared import files are rejected without registry changes")
    func rejectsUndeclaredFiles() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let store = try await makeStore(fixture)
        let source = try writeSource(fixture)
        try Data("surprise".utf8).write(to: source.appendingPathComponent("undeclared.bin"))

        await #expect(throws: ModelManifestRegistrationError.undeclaredFile("undeclared.bin")) {
            _ = try await store.importModel(
                from: source,
                entry: fixture.entry,
                on: makeDevice()
            )
        }
        #expect(try await store.installedModels().isEmpty)
    }

    @Test("Archives require an explicitly configured safe extractor")
    func requiresArchiveExtractor() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let store = try await makeStore(fixture)
        let archive = fixture.root.appendingPathComponent("model.zip")
        try Data("not-an-archive".utf8).write(to: archive)

        await #expect(throws: InferPeerModelStoreError.archiveImporterRequired) {
            _ = try await store.importModel(
                from: archive,
                entry: fixture.entry,
                on: makeDevice()
            )
        }
        #expect(try await store.installedModels().isEmpty)
    }
}

private func makeStore(_ fixture: ModelStoreFixture) async throws -> InferPeerModelStore {
    try await InferPeerModelStore.open(
        configuration: fixture.configuration(
            downloader: MemoryModelDownloader(data: fixture.data),
            adapters: [TestRuntimeAdapter()]
        )
    )
}

private func writeSource(_ fixture: ModelStoreFixture) throws -> URL {
    let source = fixture.root.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try fixture.data.write(to: source.appendingPathComponent("model.gguf"))
    return source
}
