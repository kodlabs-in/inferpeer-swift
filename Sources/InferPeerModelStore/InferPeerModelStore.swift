import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerStorage

/// Injectable package services for deterministic tests and optional archive support.
public struct InferPeerModelStoreServices: Sendable {
    /// Package-controlled transport for model files.
    public let downloader: any ModelFileDownloading
    /// Optional safe archive decoder selected by the host.
    public let archiveExtractor: (any ModelArchiveExtracting)?
    /// Bounded HTTPS transport for optional catalog refreshes.
    public let catalogDownloader: any SignedModelCatalogDownloading

    /// Creates service dependencies.
    public init(
        downloader: any ModelFileDownloading = ResumableHTTPSModelDownloader(),
        archiveExtractor: (any ModelArchiveExtracting)? = nil,
        catalogDownloader: any SignedModelCatalogDownloading = HTTPSSignedModelCatalogDownloader()
    ) {
        self.downloader = downloader
        self.archiveExtractor = archiveExtractor
        self.catalogDownloader = catalogDownloader
    }
}

/// Immutable configuration used to open a model store.
public struct InferPeerModelStoreConfiguration: Sendable {
    /// Package-managed root directory.
    public let rootDirectory: URL
    /// Signed catalog shipped with the host build.
    public let builtInCatalog: SignedModelCatalog
    /// Pinned Ed25519 public keys keyed by identifier.
    public let trustedCatalogKeys: [String: Data]
    /// Runtime adapters linked by the host app.
    public let runtimeAdapters: [any InferPeerRuntimeAdapter]
    /// Download and optional archive services.
    public let services: InferPeerModelStoreServices

    /// Creates model-store configuration.
    public init(
        rootDirectory: URL,
        builtInCatalog: SignedModelCatalog,
        trustedCatalogKeys: [String: Data],
        runtimeAdapters: [any InferPeerRuntimeAdapter],
        services: InferPeerModelStoreServices = .init()
    ) {
        self.rootDirectory = rootDirectory
        self.builtInCatalog = builtInCatalog
        self.trustedCatalogKeys = trustedCatalogKeys
        self.runtimeAdapters = runtimeAdapters
        self.services = services
    }
}

/// Package-owned catalog, compatibility, download, import, registry, and runtime lifecycle.
public actor InferPeerModelStore {
    let layout: ModelStoreLayout
    let catalogVerifier: ModelCatalogVerifier
    let adapters: RuntimeAdapterRegistry
    let evaluator: ModelCompatibilityEvaluator
    let recommendations: ModelRecommendationEngine
    let registry: ModelStoreRegistry
    let manifestStore: SQLiteVerifiedModelManifestStore
    let downloader: any ModelFileDownloading
    private let archiveExtractor: (any ModelArchiveExtracting)?
    private let catalogDownloader: any SignedModelCatalogDownloading
    var catalogValue: ModelCatalog
    var activeJobs: [UUID: Task<Void, Never>] = [:]
    var activeEntries: Set<ModelCatalogKey> = []
    var sessions: [ModelKey: any InferPeerModelSession] = [:]
    var activeModelLifecycleOperations: Set<ModelKey> = []

    private init(
        configuration: InferPeerModelStoreConfiguration,
        layout: ModelStoreLayout,
        catalog: ModelCatalog,
        adapters: RuntimeAdapterRegistry,
        registry: ModelStoreRegistry,
        manifestStore: SQLiteVerifiedModelManifestStore
    ) {
        self.layout = layout
        catalogVerifier = ModelCatalogVerifier(trustedKeys: configuration.trustedCatalogKeys)
        self.adapters = adapters
        evaluator = ModelCompatibilityEvaluator(adapters: adapters)
        recommendations = ModelRecommendationEngine(evaluator: evaluator)
        self.registry = registry
        self.manifestStore = manifestStore
        downloader = configuration.services.downloader
        archiveExtractor = configuration.services.archiveExtractor
        catalogDownloader = configuration.services.catalogDownloader
        catalogValue = catalog
    }

    /// Opens the complete model store only after verifying its built-in signed catalog.
    public static func open(
        configuration: InferPeerModelStoreConfiguration
    ) async throws -> InferPeerModelStore {
        let layout = try ModelStoreLayout(root: configuration.rootDirectory)
        let verifier = ModelCatalogVerifier(trustedKeys: configuration.trustedCatalogKeys)
        let selection = try selectCatalog(
            configuration: configuration,
            layout: layout,
            verifier: verifier
        )
        let adapters = try RuntimeAdapterRegistry(configuration.runtimeAdapters)
        let registry = try ModelStoreRegistry(
            databaseURL: layout.databaseURL,
            installedDirectory: layout.installedDirectory
        )
        let manifestStore = try SQLiteVerifiedModelManifestStore(
            databaseURL: layout.databaseURL,
            modelRootDirectory: layout.installedDirectory
        )
        try await registry.replaceCatalog(selection.catalog)
        try Self.persist(selection.envelope, in: layout)
        let store = InferPeerModelStore(
            configuration: configuration,
            layout: layout,
            catalog: selection.catalog,
            adapters: adapters,
            registry: registry,
            manifestStore: manifestStore
        )
        try await store.reconcileInstallations()
        return store
    }

    /// Returns the currently verified catalog payload.
    public func catalog() -> ModelCatalog {
        catalogValue
    }

    /// Lists and ranks every entry for the exact selected resource, including explanations.
    public func catalog(
        task: InferenceTask,
        resource: ModelStoreDeviceProfile
    ) async -> [ModelCandidate] {
        await recommendations.candidates(in: catalogValue, task: task, device: resource)
    }

    /// Lists candidates using actual telemetry from a local or connected resource snapshot.
    public func catalog(
        task: InferenceTask,
        resource: ResourceSnapshot,
        chipFeatures: Set<String> = []
    ) async -> [ModelCandidate] {
        await catalog(
            task: task,
            resource: ModelStoreDeviceProfile(snapshot: resource, chipFeatures: chipFeatures)
        )
    }

    /// Returns the highest-ranked installable model without changing the chosen resource.
    public func recommendedModel(
        task: InferenceTask,
        resource: ModelStoreDeviceProfile
    ) async -> ModelCandidate? {
        await recommendations.recommended(in: catalogValue, task: task, device: resource)
    }

    /// Recommends from measured connected-resource facts without changing the selected resource.
    public func recommendedModel(
        task: InferenceTask,
        resource: ResourceSnapshot,
        chipFeatures: Set<String> = []
    ) async -> ModelCandidate? {
        await recommendedModel(
            task: task,
            resource: ModelStoreDeviceProfile(snapshot: resource, chipFeatures: chipFeatures)
        )
    }

    /// Verifies and persists an optional remote signed catalog refresh.
    public func refreshCatalog(_ signedCatalog: SignedModelCatalog) async throws {
        let replacement = try catalogVerifier.verify(signedCatalog)
        try catalogVerifier.validateUpdate(current: catalogValue, replacement: replacement)
        try await registry.replaceCatalog(replacement)
        try Self.persist(signedCatalog, in: layout)
        catalogValue = replacement
    }

    /// Fetches a signed envelope over HTTPS and applies the same pinned-key checks.
    public func refreshCatalog(from url: URL) async throws {
        let data = try await catalogDownloader.download(from: url)
        let signedCatalog = try JSONDecoder().decode(SignedModelCatalog.self, from: data)
        try await refreshCatalog(signedCatalog)
    }

    /// Imports a verified package directory or an archive handled by the configured extractor.
    public func importModel(
        from sourceURL: URL,
        entry: ModelCatalogEntry,
        on device: ModelStoreDeviceProfile
    ) async throws -> InstalledModel {
        let task = entry.manifest.capabilities[0].task
        let support = await evaluator.support(for: entry, task: task, on: device)
        try await recordCompatibility(entry: entry, support: support)
        guard support.isInstallable else {
            throw InferPeerModelStoreError.incompatible(support)
        }
        if let installed = try await exactInstallation(for: entry) { return installed }
        let versionRoot = try prepareVersionRoot(for: entry.metadata.key)
        let staging = try layout.importStaging(for: entry.metadata.key)
        try await ModelImporter.stage(
            sourceURL: sourceURL,
            entry: entry,
            stagingURL: staging,
            archiveExtractor: archiveExtractor
        )
        let installed = try await register(entry, staging: staging, installRoot: versionRoot)
        try await registry.recordInstallation(installed, entry: entry)
        return installed
    }

    /// Imports using a mandatory local manifest selected alongside the package.
    public func importModel(
        from sourceURL: URL,
        manifest manifestURL: URL,
        on device: ModelStoreDeviceProfile
    ) async throws -> InstalledModel {
        guard manifestURL.isFileURL else {
            throw InferPeerModelStoreError.unsafeImportLocation
        }
        let access = manifestURL.startAccessingSecurityScopedResource()
        defer {
            if access { manifestURL.stopAccessingSecurityScopedResource() }
        }
        let entry = try ModelCatalogVerifier.decodeEntry(Data(contentsOf: manifestURL))
        return try await importModel(from: sourceURL, entry: entry, on: device)
    }

    func entry(for key: ModelCatalogKey) throws -> ModelCatalogEntry {
        guard let entry = catalogValue.entries.first(where: { $0.metadata.key == key }) else {
            throw InferPeerModelStoreError.catalogEntryNotFound(key)
        }
        return entry
    }

    func exactInstallation(for entry: ModelCatalogEntry) async throws -> InstalledModel? {
        try await registry.installedModels().first(where: { $0.manifest == entry.manifest })
    }

    private static func persist(_ signedCatalog: SignedModelCatalog, in layout: ModelStoreLayout)
        throws
    {
        do {
            let data = try JSONEncoder().encode(signedCatalog)
            try data.write(
                to: layout.catalogDirectory.appendingPathComponent("catalog.signed.json"),
                options: .atomic
            )
        } catch {
            throw InferPeerModelStoreError.fileSystemFailure
        }
    }

}

private extension InferPeerModelStore {
    struct CatalogSelection {
        let envelope: SignedModelCatalog
        let catalog: ModelCatalog
    }

    static func selectCatalog(
        configuration: InferPeerModelStoreConfiguration,
        layout: ModelStoreLayout,
        verifier: ModelCatalogVerifier
    ) throws -> CatalogSelection {
        let bundled = CatalogSelection(
            envelope: configuration.builtInCatalog,
            catalog: try verifier.verify(configuration.builtInCatalog)
        )
        return persistedCatalog(in: layout, newerThan: bundled, verifier: verifier) ?? bundled
    }

    static func persistedCatalog(
        in layout: ModelStoreLayout,
        newerThan bundled: CatalogSelection,
        verifier: ModelCatalogVerifier
    ) -> CatalogSelection? {
        do {
            let url = layout.catalogDirectory.appendingPathComponent("catalog.signed.json")
            let envelope = try JSONDecoder().decode(
                SignedModelCatalog.self,
                from: Data(contentsOf: url)
            )
            let catalog = try verifier.verify(envelope)
            try verifier.validateUpdate(current: bundled.catalog, replacement: catalog)
            return CatalogSelection(envelope: envelope, catalog: catalog)
        } catch {
            return nil
        }
    }
}
