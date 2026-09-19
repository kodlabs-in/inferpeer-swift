import Foundation
@testable import InferPeer
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Direct-resource facade")
struct DirectResourceFacadeTests {
    @Test("Local resource is present without discovery or networking")
    func localResourceIsAlwaysPresent() async throws {
        let fixture = try DirectResourceFixture()
        let resources = await fixture.facade.resources()

        #expect(resources.count == 1)
        #expect(resources.first?.id == .local)
        #expect(resources.first?.connection == .connected)
        #expect(resources.first?.execution == .available)
        #expect(resources.first?.models.map(\.key) == [fixture.model.descriptor.reference])
    }

    @Test("Resource watchers receive current and truthful local execution state")
    func resourceWatcherTracksLocalExecution() async throws {
        let fixture = try DirectResourceFixture(autoComplete: false)
        let updates = await fixture.facade.watchResources()
        var iterator = updates.makeAsyncIterator()

        let initial = await iterator.next()
        #expect(initial?.first?.execution == .available)
        #expect(initial?.first?.models.first?.readiness == .registered)

        let handle = try await fixture.facade.run(fixture.query(), resourceId: .local)
        await fixture.backend.waitUntilGenerationStarts(count: 1)

        let running = await iterator.next()
        #expect(running?.first?.execution == .busy)
        #expect(running?.first?.models.first?.readiness == .ready)

        await fixture.backend.completeAll()
        _ = try await handle.result()

        let finished = await iterator.next()
        #expect(finished?.first?.execution == .available)
        #expect(finished?.first?.models.first?.readiness == .ready)
    }

    @Test("Explicit preparation loads the exact local model and publishes readiness")
    func prepareModelUsesTheLocalExecutionSlot() async throws {
        let fixture = try DirectResourceFixture()

        try await fixture.facade.prepareModel(
            fixture.model.descriptor.reference,
            on: .local
        )

        let resources = await fixture.facade.resources()
        #expect(await fixture.backend.loadedModels() == [fixture.model.descriptor.reference])
        #expect(resources.first?.execution == .available)
        #expect(resources.first?.models.first?.readiness == .ready)
    }

    @Test("Switching models leaves only the new model ready")
    func modelSwitchPublishesFinalReadiness() async throws {
        let fixture = try DirectResourceFixture(
            modelIDs: ["direct-test-model-a", "direct-test-model-b"]
        )
        let firstModel = fixture.models[0].descriptor.reference
        let secondModel = fixture.models[1].descriptor.reference

        try await fixture.facade.prepareModel(firstModel, on: .local)
        try await fixture.facade.prepareModel(secondModel, on: .local)

        let snapshot = try #require(await fixture.facade.resources().first)
        let readiness = Dictionary(
            uniqueKeysWithValues: snapshot.models.map { ($0.key, $0.readiness) })
        #expect(readiness[firstModel] == .registered)
        #expect(readiness[secondModel] == .ready)
        #expect(await fixture.backend.unloadedModels() == [firstModel])
    }

    @Test("An idle local model unloads after its bounded warm-retention interval")
    func idleModelRetentionIsBounded() async throws {
        let fixture = try DirectResourceFixture(modelIdleTimeout: .milliseconds(10))

        try await fixture.facade.prepareModel(fixture.model.descriptor.reference, on: .local)
        try await Task.sleep(for: .milliseconds(30))

        let snapshot = try #require(await fixture.facade.resources().first)
        #expect(snapshot.models.first?.readiness == .registered)
        #expect(await fixture.backend.unloadedModels() == [fixture.model.descriptor.reference])
    }

    @Test("A model load failure is published and never reported ready")
    func modelLoadFailurePublishesFailedReadiness() async throws {
        let fixture = try DirectResourceFixture(failModelLoads: true)

        do {
            try await fixture.facade.prepareModel(fixture.model.descriptor.reference, on: .local)
            Issue.record("A failing model load unexpectedly succeeded")
        } catch let error as InferPeerError {
            #expect(error.code == .modelUnavailable)
        }

        let snapshot = try #require(await fixture.facade.resources().first)
        #expect(snapshot.execution == .available)
        #expect(snapshot.models.first?.readiness == .failed)
    }

    @Test("Memory admission rejects before model loading or generation")
    func insufficientMemoryFailsBeforeRuntimeAllocation() async throws {
        let fixture = try DirectResourceFixture(
            peakMemoryBytes: 2,
            memoryAvailability: DirectFixedMemoryAvailability(bytes: 1)
        )
        let handle = try await fixture.facade.run(fixture.query(), resourceId: .local)

        do {
            _ = try await handle.result()
            Issue.record("A run exceeding the safe memory budget unexpectedly completed")
        } catch let error as InferPeerError {
            #expect(error.code == .insufficientMemory)
        }

        #expect(await fixture.backend.loadedModels().isEmpty)
        #expect(await fixture.backend.generationCount() == 0)
        #expect(await fixture.facade.resources().first?.execution == .memoryLimited)
    }

    @Test("Explicit preparation obeys memory admission before loading")
    func prepareModelRejectsInsufficientMemory() async throws {
        let fixture = try DirectResourceFixture(
            peakMemoryBytes: 2,
            memoryAvailability: DirectFixedMemoryAvailability(bytes: 1)
        )

        do {
            try await fixture.facade.prepareModel(
                fixture.model.descriptor.reference,
                on: .local
            )
            Issue.record("Model preparation bypassed the memory admission limit")
        } catch let error as InferPeerError {
            #expect(error.code == .insufficientMemory)
        }

        #expect(await fixture.backend.loadedModels().isEmpty)
        #expect(await fixture.facade.resources().first?.execution == .memoryLimited)
    }

    @Test("Discovery handles share one browser and stop it after the last subscription")
    func discoveryIsReferenceCounted() async throws {
        let discovery = DirectFakeDiscovery()
        let fixture = try DirectResourceFixture(discovery: discovery)

        let first = try await fixture.facade.discovery()
        let second = try await fixture.facade.discovery()
        #expect(await discovery.startCount() == 1)

        await first.stop()
        #expect(await discovery.stopCount() == 0)

        await second.stop()
        #expect(await discovery.stopCount() == 1)
    }

    @Test("Exposure starts the injected endpoint without starting discovery")
    func exposureAndDiscoveryRemainIndependent() async throws {
        let discovery = DirectFakeDiscovery()
        let exposure = DirectFakeExposure()
        let fixture = try DirectResourceFixture(
            discovery: discovery,
            exposure: exposure
        )

        let handle = try await fixture.facade.expose()
        #expect(handle.endpoint == exposure.endpoint)
        #expect(await exposure.startCount() == 1)
        #expect(await discovery.startCount() == 0)

        await handle.stop()
        #expect(await exposure.stopCount() == 1)
    }

    @Test("Exposure can restart after its public handle stops the endpoint")
    func stoppedExposureCanRestart() async throws {
        let exposure = DirectFakeExposure()
        let fixture = try DirectResourceFixture(exposure: exposure)

        let first = try await fixture.facade.expose()
        await first.stop()
        let second = try await fixture.facade.expose()

        #expect(first.endpoint == second.endpoint)
        #expect(await exposure.startCount() == 2)
    }

    @Test("Pair, disconnect, and forget update one exact remote resource")
    func pairedResourceLifecycleUpdatesTheRegistry() async throws {
        let sessions = DirectFakeSessionManager()
        let fixture = try DirectResourceFixture(sessionManager: sessions)
        let invitation = try ResourcePairingInvitation(
            protocolMajor: 2,
            resourceID: ResourceID(rawValue: "remote-resource"),
            endpoint: PeerEndpoint(host: "192.168.1.25", port: 8443),
            certificateFingerprint: CertificateFingerprint(
                bytes: Data(repeating: 0xC4, count: CertificateFingerprint.byteCount)
            ),
            secret: Data(repeating: 0xD5, count: 32),
            expiresAt: Date().addingTimeInterval(120)
        )

        let pairedID = try await fixture.facade.pair(invitation)
        #expect(pairedID == invitation.resourceID)
        #expect(await fixture.facade.resources().map(\.id) == [.local, invitation.resourceID])

        await fixture.facade.disconnect(invitation.resourceID)
        #expect(await fixture.facade.resources().map(\.id) == [.local])
        let disconnected = await fixture.facade.resources(.known)
        #expect(disconnected.first { $0.id == invitation.resourceID }?.connection == .disconnected)

        try await fixture.facade.forget(invitation.resourceID)
        #expect(await fixture.facade.resources(.known).map(\.id) == [.local])
        #expect(await sessions.forgottenResources() == [invitation.resourceID])
    }

    @Test("Expired pairing data is rejected before opening a session")
    func expiredInvitationFailsClosed() async throws {
        let sessions = DirectFakeSessionManager()
        let fixture = try DirectResourceFixture(sessionManager: sessions)
        let invitation = try ResourcePairingInvitation(
            protocolMajor: 2,
            resourceID: ResourceID(rawValue: "expired-resource"),
            endpoint: PeerEndpoint(host: "192.168.1.25", port: 8443),
            certificateFingerprint: CertificateFingerprint(
                bytes: Data(repeating: 0xC4, count: CertificateFingerprint.byteCount)
            ),
            secret: Data(repeating: 0xD5, count: ResourcePairingInvitation.secretByteCount),
            expiresAt: Date().addingTimeInterval(-1)
        )

        do {
            _ = try await fixture.facade.pair(invitation)
            Issue.record("An expired invitation unexpectedly opened a session")
        } catch let error as InferPeerError {
            #expect(error.code == .unauthenticated)
        }
        #expect(await sessions.pairCount() == 0)
    }
}
