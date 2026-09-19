import Foundation
import InferPeerCore
import InferPeerInference
@testable import InferPeerMLX
import InferPeerModelStore
import InferPeerProtocol
import Testing

@Suite("MLX model-store adapter")
struct MLXRuntimeAdapterTests {
    @Test("Accepts verified MLX text manifests")
    func acceptsTextManifest() async throws {
        let adapter = MLXRuntimeAdapter()

        let support = await adapter.support(
            for: try makeManifest(),
            on: try makeDeviceProfile()
        )

        #expect(support == .supported)
    }

    @Test("Rejects a model assigned to another runtime")
    func rejectsAnotherRuntime() async throws {
        let adapter = MLXRuntimeAdapter()

        let support = await adapter.support(
            for: try makeManifest(runtimeIdentifier: "llama.cpp"),
            on: try makeDeviceProfile()
        )

        guard case .unsupported(let reasons) = support else {
            Issue.record("Expected unsupported runtime")
            return
        }
        #expect(reasons == [.adapterRejected("runtime identifier is not mlx")])
    }

    @Test("Loads package-managed files and maps streamed text")
    func loadsAndStreams() async throws {
        let completion = MLXRuntimeCompletion(
            promptTokens: 2,
            outputTokens: 1,
            promptDuration: .milliseconds(2),
            generationDuration: .milliseconds(4),
            finishReason: .stop
        )
        let runtime = AdapterFakeRuntime(
            session: AdapterFakeSession(events: [
                .text("OK"),
                .completed(completion),
            ])
        )
        let adapter = MLXRuntimeAdapter {
            MLXInferenceBackend(configuration: .standard, runtime: runtime)
        }
        let installed = try makeInstalledModel()

        let session = try await adapter.load(model: installed, configuration: .init())
        let events = try await collect(
            session.run(
                .text(
                    model: .exact(installed.key),
                    messages: [.user("Reply OK")]
                )
            )
        )

        #expect(events.text == "OK")
        #expect(events.result?.text == "OK")
        #expect(events.result?.usage == TokenUsage(promptTokens: 2, outputTokens: 1))
        await session.unload()
        #expect(runtime.loadCount == 1)
        #expect(runtime.clearCount >= 1)
    }
}

private extension MLXRuntimeAdapterTests {
    struct CollectedEvents {
        var text = ""
        var result: RunResult?
    }

    func collect(_ stream: DirectRuntimeEventStream) async throws -> CollectedEvents {
        var collected = CollectedEvents()
        for try await event in stream {
            switch event {
            case .textDelta(let text):
                collected.text += text
            case .completed(let result):
                collected.result = result
            case .preprocessing, .transcriptSegment, .audioChunk:
                break
            }
        }
        return collected
    }

    func makeInstalledModel() throws -> InstalledModel {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return InstalledModel(
            key: try makeKey(),
            manifest: try makeManifest(),
            directoryURL: directory,
            installedByteCount: 3
        )
    }

    // Declarative manifest fixture is clearer when its exact files stay together.
    // swiftlint:disable:next function_body_length
    func makeManifest(runtimeIdentifier: String = "mlx") throws -> ModelManifest {
        let digest = try ModelContentDigest(bytes: Data(repeating: 0xA5, count: 32))
        return try ModelManifest(
            modelID: #require(ModelID(rawValue: "mlx-adapter-test")),
            family: "Test",
            name: "MLX adapter test",
            upstreamRevision: "revision-1",
            source: "https://example.com/model",
            license: "Apache-2.0",
            runtime: ModelManifestRuntime(
                runtimeIdentifier: runtimeIdentifier,
                format: "MLX",
                quantization: "4-bit",
                minimumBackendVersion: "0.2.0"
            ),
            files: [
                try ModelManifestFile(
                    relativePath: "model.safetensors",
                    role: .weights,
                    byteCount: 1,
                    sha256: digest
                ),
                try ModelManifestFile(
                    relativePath: "tokenizer.json",
                    role: .tokenizer,
                    byteCount: 1,
                    sha256: digest
                ),
                try ModelManifestFile(
                    relativePath: "tokenizer_config.json",
                    role: .chatTemplate,
                    byteCount: 1,
                    sha256: digest
                ),
            ],
            capabilities: [
                try ModelTaskCapability(
                    task: .textGeneration,
                    contextTokenLimit: 1_024,
                    maximumOutputTokens: 128,
                    inputFormats: ["text"],
                    outputFormats: ["text"]
                )
            ]
        )
    }

    func makeDeviceProfile() throws -> ModelStoreDeviceProfile {
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

    func makeKey() throws -> ModelKey {
        try ModelKey(
            modelID: #require(ModelID(rawValue: "mlx-adapter-test")),
            revision: "manifest-v1-test"
        )
    }
}

private actor AdapterFakeSession: MLXModelSession {
    let events: [MLXRuntimeEvent]

    init(events: [MLXRuntimeEvent]) {
        self.events = events
    }

    func tokenCount(messages _: [TextMessage]) -> Int { 2 }

    func generate(
        messages _: [TextMessage],
        sampling _: SamplingOptions,
        maximumOutputTokens _: UInt32
    ) -> MLXRuntimeEventStream {
        MLXRuntimeEventStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

private final class AdapterFakeRuntime: MLXRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private let session: any MLXModelSession
    private var storedLoadCount = 0
    private var storedClearCount = 0

    init(session: any MLXModelSession) {
        self.session = session
    }

    var loadCount: Int { lock.withLock { storedLoadCount } }
    var clearCount: Int { lock.withLock { storedClearCount } }

    // swiftlint:disable:next async_without_await
    func loadModel(at _: URL) async throws -> any MLXModelSession {
        lock.withLock { storedLoadCount += 1 }
        return session
    }

    func clearCache() {
        lock.withLock { storedClearCount += 1 }
    }
}
