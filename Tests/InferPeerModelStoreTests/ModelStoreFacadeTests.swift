import Foundation
import InferPeer
import InferPeerCore
import InferPeerInference
import InferPeerModelStore
import Testing

@Suite("Model-store facade execution")
struct ModelStoreFacadeTests {
    @Test("InferPeer runs an exact package-managed model without a parallel app runtime")
    func runsInstalledModelThroughFacade() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let profile = makeDevice()
        let store = try await InferPeerModelStore.open(
            configuration: fixture.configuration(
                downloader: MemoryModelDownloader(data: fixture.data),
                adapters: [TestRuntimeAdapter()]
            )
        )
        let inferPeer = try InferPeer(
            configuration: InferPeerConfiguration(
                localResource: LocalResourceConfiguration(
                    displayName: "Fixture device",
                    platform: profile.platform
                ),
                modelStore: store,
                modelStoreDeviceProfile: profile
            )
        )
        let installation = try await store.install(
            fixture.entry.metadata.key,
            task: .textGeneration,
            on: profile,
            authorization: ModelDownloadAuthorization(resourceID: .local)
        )
        let installed = try await facadeInstalledModel(from: installation)
        let reloaded = try await inferPeer.reloadInstalledModels()
        let handle = try await inferPeer.run(
            .text(model: .exact(installed.key), messages: [.user("Hello")]),
            resourceId: .local
        )

        let result = try await handle.result()
        let snapshot = try #require(await inferPeer.resources().first)

        #expect(result.text == "offline")
        #expect(reloaded.map(\.key) == [installed.key])
        #expect(snapshot.models.first?.key == installed.key)
        #expect(snapshot.capabilities.supportedTasks == [.textGeneration])
    }
}

private func facadeInstalledModel(
    from installation: ModelInstallation
) async throws -> InstalledModel {
    for try await event in installation.events {
        if case .installed(let model) = event { return model }
    }
    throw InferPeerError(code: .modelUnavailable, isRetryable: false)
}
