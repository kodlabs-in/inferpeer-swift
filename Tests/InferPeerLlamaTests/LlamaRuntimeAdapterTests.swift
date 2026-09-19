import Foundation
import InferPeerCore
import InferPeerInference
@testable import InferPeerLlama
import InferPeerModelStore
import InferPeerProtocol
import Testing

@Suite("llama.cpp model-store adapter")
struct LlamaRuntimeAdapterTests {
    @Test("Accepts pinned GGUF text artifacts")
    func acceptsTextManifest() async throws {
        let support = await LlamaRuntimeAdapter().support(
            for: try manifest(),
            on: device()
        )

        #expect(support == .supported)
        #expect(LlamaRuntimeAdapter().runtimeVersion == "b10982.1")
    }

    @Test("Rejects a model assigned to another runtime")
    func rejectsAnotherRuntime() async throws {
        let support = await LlamaRuntimeAdapter().support(
            for: try manifest(runtime: "mlx"),
            on: device()
        )

        #expect(
            support == .unsupported(
                reasons: [.adapterRejected("runtime identifier is not llama.cpp")]
            )
        )
    }

    @Test("Never searches outside the package-managed installation")
    func rejectsMissingInstalledWeights() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let installed = InstalledModel(
            key: try key(),
            manifest: try manifest(),
            directoryURL: directory,
            installedByteCount: 1
        )

        await #expect(throws: LlamaAdapterError.missingArtifact) {
            _ = try await LlamaRuntimeAdapter().load(model: installed, configuration: .init())
        }
    }
}

private extension LlamaRuntimeAdapterTests {
    func manifest(runtime: String = "llama.cpp") throws -> ModelManifest {
        let digest = try ModelContentDigest(bytes: Data(repeating: 0xA5, count: 32))
        return try ModelManifest(
            modelID: #require(ModelID(rawValue: "llama-adapter-test")),
            family: "Test",
            name: "llama adapter test",
            upstreamRevision: "immutable-revision",
            source: "https://example.com/model.gguf",
            license: "Apache-2.0",
            runtime: ModelManifestRuntime(
                runtimeIdentifier: runtime,
                format: "GGUF",
                quantization: "Q8_0",
                minimumBackendVersion: "b10982.1"
            ),
            files: [
                try ModelManifestFile(
                    relativePath: "model.gguf",
                    role: .weights,
                    byteCount: 1,
                    sha256: digest
                )
            ],
            capabilities: [
                try ModelTaskCapability(
                    task: .textGeneration,
                    contextTokenLimit: 4_096,
                    maximumOutputTokens: 512,
                    inputFormats: ["text"],
                    outputFormats: ["text"]
                )
            ]
        )
    }

    func key() throws -> ModelKey {
        try ModelKey(
            modelID: #require(ModelID(rawValue: "llama-adapter-test")),
            revision: "manifest-v1-test"
        )
    }

    func device() -> ModelStoreDeviceProfile {
        ModelStoreDeviceProfile(
            resourceID: .local,
            platform: PlatformDescriptor(
                operatingSystem: .macOS,
                operatingSystemVersion: "27.0",
                hardwareIdentifier: "Mac17,2"
            ),
            tier: .mac,
            physicalMemoryBytes: 32_000_000_000,
            availableMemoryBytes: 16_000_000_000,
            freeStorageBytes: 100_000_000_000
        )
    }
}
