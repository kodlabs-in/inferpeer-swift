import Crypto
import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerModelStore
import InferPeerProtocol
import Testing

struct ModelStoreFixture {
    let root: URL
    let privateKey: Curve25519.Signing.PrivateKey
    let keyID = "test-catalog-key"
    let data: Data
    let entry: ModelCatalogEntry

    init(
        data: Data = Data("verified-model".utf8),
        modelID: String = "fixture-text",
        version: String = "1.0.0",
        status: ModelCatalogStatus = .stable,
        tier: ModelDeviceTier = .iPhone,
        minimumPhysicalMemoryBytes: UInt64 = 1_000,
        licenseAcceptanceRequired: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        privateKey = Curve25519.Signing.PrivateKey()
        self.data = data
        let options = EntryOptions(
            version: version,
            status: status,
            tier: tier,
            minimumPhysicalMemoryBytes: minimumPhysicalMemoryBytes,
            licenseAcceptanceRequired: licenseAcceptanceRequired
        )
        let manifest = try Self.makeManifest(data: data, modelID: modelID)
        entry = try Self.makeEntry(data: data, manifest: manifest, options: options)
    }

    private static func makeManifest(data: Data, modelID: String) throws -> ModelManifest {
        let identifier = try #require(ModelID(rawValue: modelID))
        let digest = try ModelContentDigest(bytes: Data(SHA256.hash(data: data)))
        let file = try ModelManifestFile(
            relativePath: "model.gguf",
            role: .weights,
            byteCount: UInt64(data.count),
            sha256: digest
        )
        return try ModelManifest(
            modelID: identifier,
            family: "Fixture",
            name: "Fixture Text Model",
            upstreamRevision: "immutable-revision",
            source: "https://example.test/models/fixture",
            license: "Apache-2.0",
            runtime: ModelManifestRuntime(
                runtimeIdentifier: "llama.cpp",
                format: "GGUF",
                quantization: "Q8_0",
                minimumBackendVersion: "1.0.0"
            ),
            files: [file],
            capabilities: [
                ModelTaskCapability(
                    task: .textGeneration,
                    contextTokenLimit: 2_048,
                    maximumOutputTokens: 256,
                    outputFormats: ["text/plain"]
                )
            ]
        )
    }

    private static func makeEntry(
        data: Data,
        manifest: ModelManifest,
        options: EntryOptions
    ) throws -> ModelCatalogEntry {
        let file = manifest.files[0]
        let metadata = ModelCatalogMetadata(
            key: ModelCatalogKey(modelID: manifest.modelID, version: options.version),
            displayName: "Fixture Text",
            publisher: "Fixture Publisher",
            status: options.status,
            recommendedTier: options.tier
        )
        return try ModelCatalogEntry(
            metadata: metadata,
            manifest: manifest,
            downloadFiles: [
                ModelDownloadFile(
                    relativePath: file.relativePath,
                    url: try #require(
                        URL(string: "https://example.test/immutable/model.gguf")
                    ),
                    byteCount: file.byteCount,
                    sha256: file.sha256
                )
            ],
            license: ModelLicense(
                identifier: manifest.license,
                url: try #require(URL(string: "https://example.test/license")),
                acceptanceRequired: options.licenseAcceptanceRequired
            ),
            requirements: requirements(data: data, options: options),
            validation: validation(status: options.status)
        )
    }

    private static func requirements(data: Data, options: EntryOptions) -> ModelRequirements {
        ModelRequirements(
            minimumOperatingSystems: [
                MinimumOperatingSystem(operatingSystem: .iOS, version: "18.0"),
                MinimumOperatingSystem(operatingSystem: .iPadOS, version: "18.0"),
                MinimumOperatingSystem(operatingSystem: .macOS, version: "15.0"),
            ],
            resources: ModelResourceRequirements(
                minimumPhysicalMemoryBytes: options.minimumPhysicalMemoryBytes,
                minimumAvailableMemoryBytes: 500,
                minimumFreeStorageBytes: UInt64(data.count) + 1_000
            )
        )
    }

    private static func validation(status: ModelCatalogStatus) -> [ModelValidationRecord] {
        guard status == .stable else { return [] }
        return [
            ModelValidationRecord(
                hardwareIdentifier: "iPhone15,4",
                operatingSystemVersion: "18.0",
                adapterVersion: "1.0.0",
                passedAt: Date(timeIntervalSince1970: 1_000)
            )
        ]
    }

    func signedCatalog(
        entries: [ModelCatalogEntry]? = nil,
        revision: String = "catalog-1",
        generatedAt: Date = Date(timeIntervalSince1970: 2_000)
    ) throws -> SignedModelCatalog {
        let catalog = try ModelCatalog(
            revision: revision,
            generatedAt: generatedAt,
            entries: entries ?? [entry]
        )
        let payload = try ModelCatalogVerifier.encode(catalog)
        return SignedModelCatalog(
            keyID: keyID,
            payload: payload,
            signature: try privateKey.signature(for: payload)
        )
    }

    func configuration(
        downloader: any ModelFileDownloading,
        adapters: [any InferPeerRuntimeAdapter]
    ) throws -> InferPeerModelStoreConfiguration {
        try InferPeerModelStoreConfiguration(
            rootDirectory: root,
            builtInCatalog: signedCatalog(),
            trustedCatalogKeys: [keyID: privateKey.publicKey.rawRepresentation],
            runtimeAdapters: adapters,
            services: .init(downloader: downloader)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct EntryOptions {
    let version: String
    let status: ModelCatalogStatus
    let tier: ModelDeviceTier
    let minimumPhysicalMemoryBytes: UInt64
    let licenseAcceptanceRequired: Bool
}

func makeDevice(
    id: ResourceID = .local,
    physicalMemoryBytes: UInt64 = 8_000,
    hardwareIdentifier: String = "iPhone15,4"
) -> ModelStoreDeviceProfile {
    ModelStoreDeviceProfile(
        resourceID: id,
        platform: PlatformDescriptor(
            operatingSystem: .iOS,
            operatingSystemVersion: "18.2",
            hardwareIdentifier: hardwareIdentifier
        ),
        tier: .iPhone,
        physicalMemoryBytes: physicalMemoryBytes,
        availableMemoryBytes: 4_000,
        freeStorageBytes: 1_000_000,
        chipFeatures: ["metal"]
    )
}

actor MemoryModelDownloader: ModelFileDownloading {
    private let data: Data
    private let interruptFirstDownload: Bool
    private(set) var calls = 0
    private(set) var resumeOffsets: [Int] = []

    init(data: Data, interruptFirstDownload: Bool = false) {
        self.data = data
        self.interruptFirstDownload = interruptFirstDownload
    }

    func download(
        _ file: ModelDownloadFile,
        to partialURL: URL,
        progress: @escaping @Sendable (UInt64) -> Void
    ) async throws -> UInt64 {
        await Task.yield()
        calls += 1
        try FileManager.default.createDirectory(
            at: partialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing = (try? Data(contentsOf: partialURL)) ?? Data()
        resumeOffsets.append(existing.count)
        if interruptFirstDownload, calls == 1 {
            let boundary = max(1, data.count / 2)
            try Data(data.prefix(boundary)).write(to: partialURL)
            progress(UInt64(boundary))
            throw CancellationError()
        }
        var completed = existing
        completed.append(data.dropFirst(existing.count))
        try completed.write(to: partialURL)
        progress(UInt64(completed.count))
        return UInt64(completed.count)
    }
}

actor AdapterProbe {
    private(set) var loadCount = 0
    private(set) var unloadCount = 0

    func loaded() { loadCount += 1 }
    func unloaded() { unloadCount += 1 }
}

struct TestRuntimeAdapter: InferPeerRuntimeAdapter {
    let runtimeID: RuntimeID
    let runtimeVersion: String
    let supportValue: ModelSupport
    let probe: AdapterProbe

    init(
        runtimeID: RuntimeID = RuntimeID(rawValue: "llama.cpp"),
        runtimeVersion: String = "1.0.0",
        support: ModelSupport = .supported,
        probe: AdapterProbe = AdapterProbe()
    ) {
        self.runtimeID = runtimeID
        self.runtimeVersion = runtimeVersion
        supportValue = support
        self.probe = probe
    }

    func support(
        for model: ModelManifest,
        on device: ModelStoreDeviceProfile
    ) async -> ModelSupport {
        await Task.yield()
        return supportValue
    }

    func load(
        model: InstalledModel,
        configuration: ModelLoadConfiguration
    ) async throws -> any InferPeerModelSession {
        await probe.loaded()
        return TestModelSession(key: model.key, probe: probe)
    }
}

struct TestModelSession: InferPeerModelSession {
    let modelKey: ModelKey
    let capabilities: Set<InferenceTask> = [.textGeneration]
    let probe: AdapterProbe

    init(key: ModelKey, probe: AdapterProbe) {
        modelKey = key
        self.probe = probe
    }

    func run(_ request: InferenceQuery) -> DirectRuntimeEventStream {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("offline"))
            continuation.yield(
                .completed(
                    RunResult(
                        text: "offline",
                        model: modelKey,
                        finishReason: .stop,
                        usage: TokenUsage(promptTokens: 1, outputTokens: 1)
                    )
                )
            )
            continuation.finish()
        }
    }

    func unload() async {
        await probe.unloaded()
    }
}
