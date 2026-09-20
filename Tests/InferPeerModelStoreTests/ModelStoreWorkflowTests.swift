import Foundation
import GRDB
import InferPeerCore
import InferPeerInference
import InferPeerModelStore
import InferPeerStorage
import Testing

@Suite("Model store workflows")
struct ModelStoreWorkflowTests {
    @Test("Download verifies, registers, runs offline, and removes safely")
    func completeLifecycle() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let downloader = MemoryModelDownloader(data: fixture.data)
        let adapter = TestRuntimeAdapter()
        let store = try await InferPeerModelStore.open(
            configuration: fixture.configuration(
                downloader: downloader,
                adapters: [adapter]
            )
        )
        let installation = try await store.install(
            fixture.entry.metadata.key,
            task: .textGeneration,
            on: makeDevice(),
            authorization: ModelDownloadAuthorization(resourceID: .local)
        )

        let result = try await collect(installation)
        let installed = try #require(result.installed)
        #expect(result.states.contains(.verifying))
        #expect(!result.progress.isEmpty)
        #expect(FileManager.default.fileExists(atPath: installed.directoryURL.path))
        #expect(try await store.installedModels().count == 1)

        let duplicate = try await store.install(
            fixture.entry.metadata.key,
            task: .textGeneration,
            on: makeDevice(),
            authorization: ModelDownloadAuthorization(resourceID: .local)
        )
        #expect(try await collect(duplicate).installed?.key == installed.key)
        #expect(await downloader.calls == 1)
        try await verifyRuntimeLifecycle(store: store, installed: installed, adapter: adapter)
    }

    @Test("Interrupted jobs resume from durable partial bytes")
    func resumesInterruptedDownload() async throws {
        let fixture = try ModelStoreFixture(data: Data("resumable-model-data".utf8))
        defer { fixture.remove() }
        let downloader = MemoryModelDownloader(
            data: fixture.data,
            interruptFirstDownload: true
        )
        let store = try await InferPeerModelStore.open(
            configuration: fixture.configuration(
                downloader: downloader,
                adapters: [TestRuntimeAdapter()]
            )
        )
        let first = try await store.install(
            fixture.entry.metadata.key,
            task: .textGeneration,
            on: makeDevice(),
            authorization: ModelDownloadAuthorization(resourceID: .local)
        )

        let paused = try await collect(first)
        #expect(paused.states.last == .paused)
        #expect(try await store.installedModels().isEmpty)

        let resumed = try await store.install(
            fixture.entry.metadata.key,
            task: .textGeneration,
            on: makeDevice(),
            authorization: ModelDownloadAuthorization(resourceID: .local)
        )
        #expect(try await collect(resumed).installed != nil)
        #expect(await downloader.calls == 2)
        #expect(await downloader.resumeOffsets == [0, fixture.data.count / 2])
    }

    @Test("A verified staging download replaces an orphaned destination")
    func recoversVerifiedStagingAfterInterruptedRegistration() async throws {
        let fixture = try ModelStoreFixture(data: Data("complete-staged-model".utf8))
        defer { fixture.remove() }
        let downloader = MemoryModelDownloader(data: fixture.data)
        let store = try await InferPeerModelStore.open(
            configuration: fixture.configuration(
                downloader: downloader,
                adapters: [TestRuntimeAdapter()]
            )
        )
        let versionRoot = fixture.root
            .appendingPathComponent("installed", isDirectory: true)
            .appendingPathComponent(fixture.entry.metadata.key.modelID.rawValue, isDirectory: true)
            .appendingPathComponent(fixture.entry.metadata.key.version, isDirectory: true)
        let staging = versionRoot.appendingPathComponent("download.staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try fixture.data.write(to: staging.appendingPathComponent("model.gguf"))
        let verified = try ModelManifestVerifier().verify(fixture.entry.manifest, in: staging)
        let orphanedDestination = versionRoot.appendingPathComponent(
            verified.key.revision,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: orphanedDestination,
            withIntermediateDirectories: true
        )
        try Data("stale-model".utf8).write(
            to: orphanedDestination.appendingPathComponent("model.gguf")
        )

        let installation = try await store.install(
            fixture.entry.metadata.key,
            task: .textGeneration,
            on: makeDevice(),
            authorization: ModelDownloadAuthorization(resourceID: .local)
        )
        let installed = try #require(try await collect(installation).installed)

        #expect(
            try Data(contentsOf: installed.directoryURL.appendingPathComponent("model.gguf"))
                == fixture.data
        )
        #expect(await downloader.calls == 0)
    }

    @Test("Corrupt model bytes never become installed")
    func rejectsCorruptDownloads() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let corrupt = Data(repeating: 0xFF, count: fixture.data.count)
        let store = try await InferPeerModelStore.open(
            configuration: fixture.configuration(
                downloader: MemoryModelDownloader(data: corrupt),
                adapters: [TestRuntimeAdapter()]
            )
        )
        let installation = try await store.install(
            fixture.entry.metadata.key,
            task: .textGeneration,
            on: makeDevice(),
            authorization: ModelDownloadAuthorization(resourceID: .local)
        )

        await #expect(throws: ModelManifestRegistrationError.self) {
            _ = try await collect(installation)
        }
        #expect(try await store.installedModels().isEmpty)
    }

    @Test("Remote downloads and click-through licenses require explicit approval")
    func enforcesRemoteAuthorization() async throws {
        let fixture = try ModelStoreFixture(licenseAcceptanceRequired: true)
        defer { fixture.remove() }
        let downloader = MemoryModelDownloader(data: fixture.data)
        let store = try await InferPeerModelStore.open(
            configuration: fixture.configuration(
                downloader: downloader,
                adapters: [TestRuntimeAdapter()]
            )
        )
        let remoteID = ResourceID(rawValue: "remote-phone")
        let device = makeDevice(id: remoteID)

        await #expect(throws: InferPeerModelStoreError.remoteApprovalRequired(remoteID)) {
            _ = try await store.install(
                fixture.entry.metadata.key,
                task: .textGeneration,
                on: device,
                authorization: ModelDownloadAuthorization(resourceID: remoteID)
            )
        }
        await #expect(
            throws: InferPeerModelStoreError.licenseAcceptanceRequired("Apache-2.0")
        ) {
            _ = try await store.install(
                fixture.entry.metadata.key,
                task: .textGeneration,
                on: device,
                authorization: ModelDownloadAuthorization(
                    resourceID: remoteID,
                    remoteApprovalGranted: true
                )
            )
        }
        #expect(await downloader.calls == 0)
    }

    @Test("Directory import shares exact verification and registry tables")
    func importsAndPersistsRegistry() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let store = try await InferPeerModelStore.open(
            configuration: fixture.configuration(
                downloader: MemoryModelDownloader(data: fixture.data),
                adapters: [TestRuntimeAdapter()]
            )
        )
        let source = fixture.root.appendingPathComponent("import-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try fixture.data.write(to: source.appendingPathComponent("model.gguf"))

        let installed = try await store.importModel(
            from: source,
            entry: fixture.entry,
            on: makeDevice()
        )

        #expect(FileManager.default.fileExists(atPath: installed.directoryURL.path))
        let database = try DatabaseQueue(
            path: fixture.root.appendingPathComponent("registry.sqlite").path
        )
        let tables = try await database.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
        }
        let compatibilityCount = try await database.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM adapter_compatibility")
        }
        let required = Set([
            "catalog_entries", "model_versions", "model_files", "installations",
            "adapter_compatibility", "download_jobs", "validation_runs",
        ])
        #expect(required.isSubset(of: Set(tables)))
        #expect(compatibilityCount == 1)
    }

    @Test("Opening the store quarantines an installation modified on disk")
    func reconcilesModifiedInstallations() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let configuration = try fixture.configuration(
            downloader: MemoryModelDownloader(data: fixture.data),
            adapters: [TestRuntimeAdapter()]
        )
        let store = try await InferPeerModelStore.open(configuration: configuration)
        let installation = try await store.install(
            fixture.entry.metadata.key,
            task: .textGeneration,
            on: makeDevice(),
            authorization: ModelDownloadAuthorization(resourceID: .local)
        )
        let installed = try #require(try await collect(installation).installed)
        try Data("modified".utf8).write(
            to: installed.directoryURL.appendingPathComponent("model.gguf")
        )

        let reopened = try await InferPeerModelStore.open(configuration: configuration)

        #expect(try await reopened.installedModels().isEmpty)
        #expect(try await reopened.status(of: installed.key)?.state == .corrupt)

        let repair = try await reopened.install(
            fixture.entry.metadata.key,
            task: .textGeneration,
            on: makeDevice(),
            authorization: ModelDownloadAuthorization(resourceID: .local)
        )
        let repaired = try #require(try await collect(repair).installed)
        #expect(
            try Data(contentsOf: repaired.directoryURL.appendingPathComponent("model.gguf"))
                == fixture.data
        )
        #expect(try await reopened.status(of: repaired.key)?.state == .installed)
    }

}

private func verifyRuntimeLifecycle(
    store: InferPeerModelStore,
    installed: InstalledModel,
    adapter: TestRuntimeAdapter
) async throws {
    let installedStatus = try #require(try await store.status(of: installed.key))
    #expect(installedStatus.state == .installed)
    #expect(installedStatus.isSafeToRemove)
    try await store.load(installed.key, on: makeDevice())
    let readyStatus = try #require(try await store.status(of: installed.key))
    #expect(readyStatus.state == .ready)
    #expect(readyStatus.isLoaded)
    #expect(!readyStatus.isSafeToRemove)
    let query = InferenceQuery.text(
        model: .exact(installed.key),
        messages: [.user("Run without a network")]
    )
    let events = try await collect(try await store.run(query, using: installed.key))
    #expect(events.text == "offline")
    #expect(events.completedModel == installed.key)

    await #expect(throws: InferPeerModelStoreError.modelInUse(installed.key)) {
        try await store.remove(installed.key)
    }
    try await store.remove(installed.key, policy: .unloadAndRemove)
    #expect(try await store.installedModels().isEmpty)
    #expect(try await store.status(of: installed.key)?.state == .removed)
    #expect(await adapter.probe.loadCount == 1)
    #expect(await adapter.probe.unloadCount == 1)
}

func collect(
    _ installation: ModelInstallation
) async throws -> (
    states: [ModelInstallationState],
    progress: [ModelInstallationProgress],
    installed: InstalledModel?
) {
    var states: [ModelInstallationState] = []
    var progress: [ModelInstallationProgress] = []
    var installed: InstalledModel?
    for try await event in installation.events {
        switch event {
        case .state(let state):
            states.append(state)
        case .progress(let value):
            progress.append(value)
        case .installed(let value):
            installed = value
        }
    }
    return (states, progress, installed)
}

func collect(
    _ stream: DirectRuntimeEventStream
) async throws -> (text: String, completedModel: ModelKey?) {
    var text = ""
    var completedModel: ModelKey?
    for try await event in stream {
        switch event {
        case .textDelta(let delta):
            text += delta
        case .completed(let result):
            completedModel = result.model
        case .preprocessing, .transcriptSegment, .audioChunk:
            break
        }
    }
    return (text, completedModel)
}
