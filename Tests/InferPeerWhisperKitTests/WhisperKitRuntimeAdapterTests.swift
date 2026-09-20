import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerModelStore
import InferPeerProtocol
@testable import InferPeerWhisperKit
import Testing

@Suite("WhisperKit model-store adapter")
struct WhisperKitRuntimeAdapterTests {
    @Test("Accepts pinned Core ML transcription artifacts")
    func acceptsTranscriptionManifest() async throws {
        let adapter = WhisperKitRuntimeAdapter()

        let support = await adapter.support(for: try manifest(), on: device())

        #expect(support == .supported)
        #expect(adapter.runtimeVersion == "1.1.0.1")
    }

    @Test("Rejects incomplete local tokenizers before runtime initialization")
    func rejectsIncompleteTokenizer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        let installed = InstalledModel(
            key: try key(),
            manifest: try manifest(),
            directoryURL: directory,
            installedByteCount: 3
        )

        await #expect(throws: WhisperKitAdapterError.incompleteTokenizer) {
            _ = try await adapter().load(model: installed, configuration: .init())
        }
    }
}

private extension WhisperKitRuntimeAdapterTests {
    func adapter() -> WhisperKitRuntimeAdapter {
        WhisperKitRuntimeAdapter()
    }

    func manifest() throws -> ModelManifest {
        let digest = try ModelContentDigest(bytes: Data(repeating: 0x5A, count: 32))
        return try ModelManifest(
            modelID: #require(ModelID(rawValue: "whisperkit-adapter-test")),
            family: "Whisper",
            name: "WhisperKit adapter test",
            upstreamRevision: "immutable-revision",
            source: "https://example.com/whisper",
            license: "MIT AND Apache-2.0",
            runtime: ModelManifestRuntime(
                runtimeIdentifier: "whisperkit",
                format: "CoreML",
                quantization: "fp16",
                minimumBackendVersion: "1.1.0.1"
            ),
            files: [
                try file("AudioEncoder.mlmodelc/weights.bin", role: .weights, digest: digest),
                try file("MelSpectrogram.mlmodelc/model.mil", role: .audioModel, digest: digest),
                try file("tokenizer.json", role: .tokenizer, digest: digest),
            ],
            capabilities: [
                try ModelTaskCapability(
                    task: .transcribe,
                    inputFormats: ["audio/wav", "audio/m4a"],
                    outputFormats: ["text"]
                )
            ]
        )
    }

    func file(
        _ path: String,
        role: ModelManifestFileRole,
        digest: ModelContentDigest
    ) throws -> ModelManifestFile {
        try ModelManifestFile(
            relativePath: path,
            role: role,
            byteCount: 1,
            sha256: digest
        )
    }

    func key() throws -> ModelKey {
        try ModelKey(
            modelID: #require(ModelID(rawValue: "whisperkit-adapter-test")),
            revision: "manifest-v1-test"
        )
    }

    func device() -> ModelStoreDeviceProfile {
        ModelStoreDeviceProfile(
            resourceID: .local,
            platform: PlatformDescriptor(
                operatingSystem: .iPadOS,
                operatingSystemVersion: "27.0",
                hardwareIdentifier: "iPad14,3"
            ),
            tier: .iPad,
            physicalMemoryBytes: 8_000_000_000,
            availableMemoryBytes: 4_000_000_000,
            freeStorageBytes: 20_000_000_000
        )
    }
}
