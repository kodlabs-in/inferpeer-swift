import InferPeer
import InferPeerCore
import InferPeerModelStore
import Testing

@Suite("InferPeer model store")
struct ModelStoreSmokeTests {
    @Test("Runtime identifiers preserve adapter identity")
    func runtimeIdentity() {
        #expect(RuntimeID(rawValue: "llama.cpp").rawValue == "llama.cpp")
    }

    @Test("Llama and WhisperKit adapter objects register without core changes")
    func registersIndependentAdapters() async throws {
        let llama = TestRuntimeAdapter(runtimeID: RuntimeID(rawValue: "llama.cpp"))
        let whisper = TestRuntimeAdapter(runtimeID: RuntimeID(rawValue: "whisperkit"))
        let registry = try RuntimeAdapterRegistry([llama, whisper])

        let runtimes = await registry.registeredRuntimes()

        #expect(runtimes[llama.runtimeID] == "1.0.0")
        #expect(runtimes[whisper.runtimeID] == "1.0.0")
    }

    @Test("The public facade exposes its configured package model store")
    func facadeComposition() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let store = try await InferPeerModelStore.open(
            configuration: fixture.configuration(
                downloader: MemoryModelDownloader(data: fixture.data),
                adapters: [TestRuntimeAdapter()]
            )
        )
        let engine = try InferPeer(
            configuration: InferPeerConfiguration(
                localResource: LocalResourceConfiguration(
                    displayName: "Test Mac",
                    platform: PlatformDescriptor(
                        operatingSystem: .macOS,
                        operatingSystemVersion: "15.0"
                    )
                ),
                modelStore: store
            )
        )

        let exposed = try #require(engine.modelStore)
        #expect(exposed === store)
    }
}
