import Foundation
@testable import InferPeer
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage
import InferPeerTelemetry
import Testing

@Suite("InferPeer facade")
struct InferPeerNodeTests {
    @Test("Coordinator lifecycle owns listener and advertisement")
    func coordinatorLifecycle() async throws {
        let transport = FakeTransport()
        let advertisement = FakeAdvertisement()
        let endpoint = try PeerEndpoint(host: "192.168.1.4", port: 8443)
        let node = try makeNode(
            roles: [.coordinator],
            endpoint: endpoint,
            transport: transport,
            optional: .init(advertisement: advertisement)
        )

        try await node.start()

        #expect(await node.state() == .started)
        #expect(await transport.listenEndpoints == [endpoint])
        #expect(await advertisement.startCount == 1)

        await node.stop()

        #expect(await node.state() == .stopped)
        #expect(await advertisement.stopCount == 1)
        #expect(await transport.stopCount == 1)
    }

    @Test("Concurrent starts cannot create duplicate coordinator resources")
    func rejectsConcurrentStart() async throws {
        let transport = SuspendedListenTransport()
        let endpoint = try PeerEndpoint(host: "192.168.1.4", port: 8443)
        let node = try makeNode(
            roles: [.coordinator],
            endpoint: endpoint,
            transport: transport
        )
        let firstStart = Task { try await node.start() }
        await transport.waitUntilListenStarts()

        await #expect(throws: InferPeerNodeError.alreadyStarted) {
            try await node.start()
        }

        await transport.resumeListen()
        try await firstStart.value
        #expect(await transport.listenCount == 1)
        await node.stop()
    }

    @Test("Stopping during startup prevents late resource installation")
    func stopCancelsInFlightStart() async throws {
        let transport = SuspendedListenTransport()
        let endpoint = try PeerEndpoint(host: "192.168.1.4", port: 8443)
        let node = try makeNode(
            roles: [.coordinator],
            endpoint: endpoint,
            transport: transport
        )
        let start = Task { try await node.start() }
        await transport.waitUntilListenStarts()

        await node.stop()
        await transport.resumeListen()

        await #expect(throws: CancellationError.self) {
            try await start.value
        }
        #expect(await node.state() == .stopped)
        #expect(await transport.stopCount >= 1)
    }

    @Test("Pairing sends the invitation without consuming coordinator state locally")
    func joinsEnabledRoles() async throws {
        let identity = FakeIdentityProvider()
        let transport = FakeTransport()
        let node = try makeNode(
            roles: [.caller, .worker],
            identity: identity,
            transport: transport,
            optional: .init(callerOutbox: FakeCallerOutbox())
        )
        try await node.start()
        let invitation = try makeInvitation()

        let sessions = try await node.join(invitation)

        #expect(sessions.caller != nil)
        #expect(sessions.worker != nil)
        #expect(await identity.consumedInvitationIDs.isEmpty)
        #expect(await transport.callerEndpoints == [invitation.coordinator.endpoint])
        #expect(await transport.workerEndpoints == [invitation.coordinator.endpoint])
        #expect(await transport.callerInvitationIDs == [invitation.invitationID])
        #expect(await transport.workerInvitationIDs == [invitation.invitationID])
    }

    @Test("Concurrent joins cannot create duplicate coordinator sessions")
    func rejectsConcurrentJoin() async throws {
        let transport = SuspendedJoinTransport()
        let node = try makeNode(
            roles: [.caller],
            transport: transport,
            optional: .init(callerOutbox: FakeCallerOutbox())
        )
        try await node.start()
        let invitation = try makeInvitation()
        let firstJoin = Task { try await node.join(invitation) }
        await transport.waitUntilJoinStarts()

        await #expect(throws: InferPeerNodeError.alreadyJoined) {
            _ = try await node.join(invitation)
        }

        await transport.resumeJoin()
        _ = try await firstJoin.value
        #expect(await transport.joinCount == 1)
        await node.stop()
    }

    @Test("Stopping during join closes the late session")
    func stopCancelsInFlightJoin() async throws {
        let transport = SuspendedJoinTransport()
        let node = try makeNode(
            roles: [.caller],
            transport: transport,
            optional: .init(callerOutbox: FakeCallerOutbox())
        )
        try await node.start()
        let join = Task { try await node.join(makeInvitation()) }
        await transport.waitUntilJoinStarts()

        await node.stop()
        await transport.resumeJoin()

        await #expect(throws: CancellationError.self) {
            _ = try await join.value
        }
        #expect(await transport.callerSession.closeCount == 1)
        #expect(await node.state() == .stopped)
    }

    @Test("Leaving a disconnected coordinator permits an explicit rejoin")
    func leavesAndRejoins() async throws {
        let transport = FakeTransport()
        let node = try makeNode(
            roles: [.caller],
            transport: transport,
            optional: .init(callerOutbox: FakeCallerOutbox())
        )
        try await node.start()
        let invitation = try makeInvitation()

        _ = try await node.join(invitation)
        await node.leaveCoordinator()
        _ = try await node.join(invitation)

        #expect(await transport.callerEndpoints.count == 2)
        await node.stop()
    }

    @Test("Caller joining fails before use when no durable outbox is configured")
    func requiresCallerOutbox() async throws {
        let transport = FakeTransport()
        let configuration = try InferPeerNodeConfiguration(roles: [.caller])
        let node = InferPeerNode(
            configuration: configuration,
            dependencies: InferPeerDependencies(
                identity: FakeIdentityProvider(),
                transport: transport,
                discovery: FakeDiscovery(),
                status: FakeStatusProvider()
            )
        )
        try await node.start()

        await #expect(throws: InferPeerNodeError.callerOutboxUnavailable) {
            _ = try await node.join(makeInvitation())
        }
        await node.stop()
    }

    @Test("Worker model operations use injected registry and backend")
    func delegatesModelOperations() async throws {
        let artifact = try makeArtifact()
        let registry = FakeModelRegistry(artifact: artifact)
        let backend = FakeInferenceBackend()
        let node = try makeNode(
            roles: [.worker],
            optional: .init(modelRegistry: registry, inferenceBackend: backend)
        )
        try await node.start()

        _ = try await node.registerModel(artifact)
        try await node.loadModel(artifact.descriptor.reference)

        #expect(await registry.registrationCount == 1)
        #expect(await backend.loadedReferences == [artifact.descriptor.reference])

        await node.stop()
        #expect(await backend.unloadedReferences == [artifact.descriptor.reference])
    }

    @Test("Submit persists before sending and cancellation stays durable")
    func submitsAndCancelsRequest() async throws {
        let outbox = FakeCallerOutbox()
        let transport = FakeTransport()
        let node = try makeNode(
            roles: [.caller],
            transport: transport,
            optional: .init(callerOutbox: outbox)
        )
        try await node.start()
        _ = try await node.join(makeInvitation())
        let requestID = try #require(RequestID(rawValue: "request-1"))

        let handle = try await node.submit(makeRequest(), requestID: requestID)
        let cancellation = try await node.cancel(requestID: requestID)

        #expect(handle.requestID == requestID)
        #expect(await outbox.enqueuedRequestIDs == [requestID])
        #expect(cancellation == .pending)
        let sent = transport.callerSession.sentRequests
        #expect(sent.count == 2)
        #expect(sent[0].metadata.sequence == 2)
        #expect(sent[0].metadata.requestID == requestID.rawValue)
        #expect(sent[0].submit.immutableInputSha256.count == RequestContentDigest.byteCount)
        #expect(sent[1].metadata.sequence == 3)
        if case .cancel = sent[1].payload {
            // Expected command.
        } else {
            Issue.record("Expected a cancellation command")
        }
    }
}
