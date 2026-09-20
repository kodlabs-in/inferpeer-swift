import InferPeerCore
import InferPeerInference
import InferPeerModelStore
import Testing

@Suite("Model store lifecycle concurrency")
struct ModelStoreLifecycleConcurrencyTests {
    @Test("Model lifecycle reservations prevent overlapping load and removal")
    func serializesModelLifecycleOperations() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let gate = ModelLoadGate()
        let adapter = BlockingRuntimeAdapter(gate: gate)
        let store = try await InferPeerModelStore.open(
            configuration: fixture.configuration(
                downloader: MemoryModelDownloader(data: fixture.data),
                adapters: [adapter]
            )
        )
        let installation = try await store.install(
            fixture.entry.metadata.key,
            task: .textGeneration,
            on: makeDevice(),
            authorization: ModelDownloadAuthorization(resourceID: .local)
        )
        let installed = try #require(try await collect(installation).installed)
        let firstLoad = Task {
            try await store.load(installed.key, on: makeDevice())
        }
        await gate.waitUntilStarted()

        await #expect(throws: InferPeerModelStoreError.modelInUse(installed.key)) {
            try await store.load(installed.key, on: makeDevice())
        }
        await #expect(throws: InferPeerModelStoreError.modelInUse(installed.key)) {
            try await store.remove(installed.key, policy: .unloadAndRemove)
        }

        await gate.open()
        try await firstLoad.value
        #expect(try await store.status(of: installed.key)?.isLoaded == true)
    }
}

private actor ModelLoadGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private struct BlockingRuntimeAdapter: InferPeerRuntimeAdapter {
    let runtimeID = RuntimeID(rawValue: "llama.cpp")
    let runtimeVersion = "1.0.0"
    let gate: ModelLoadGate

    func support(
        for _: ModelManifest,
        on _: ModelStoreDeviceProfile
    ) async -> ModelSupport {
        await Task.yield()
        return .supported
    }

    func load(
        model: InstalledModel,
        configuration _: ModelLoadConfiguration
    ) async throws -> any InferPeerModelSession {
        await gate.wait()
        return TestModelSession(key: model.key, probe: AdapterProbe())
    }
}
