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

    @Test("Pairing opens only explicitly enabled joining roles")
    func joinsEnabledRoles() async throws {
        let identity = FakeIdentityProvider()
        let transport = FakeTransport()
        let node = try makeNode(
            roles: [.caller, .worker],
            identity: identity,
            transport: transport
        )
        try await node.start()
        let invitation = try makeInvitation()

        let sessions = try await node.join(invitation)

        #expect(sessions.caller != nil)
        #expect(sessions.worker != nil)
        #expect(await identity.consumedInvitationIDs == [invitation.invitationID])
        #expect(await transport.callerEndpoints == [invitation.coordinator.endpoint])
        #expect(await transport.workerEndpoints == [invitation.coordinator.endpoint])
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

    @Test("Request events replay with attempt boundaries and explicit acknowledgement")
    func replaysAndAcknowledgesEvents() async throws {
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
        _ = try await node.submit(makeRequest(), requestID: requestID)
        let events = try await node.events(requestID: requestID, after: nil)
        let task = Task { try await #require(events.first(where: { _ in true })) }
        await Task.yield()

        transport.callerSession.emit(acceptedResponse(requestID: requestID, cursor: 1))
        let event = try await task.value
        try await node.acknowledge(requestID: requestID, through: event.cursor)

        #expect(event.requestID == requestID)
        #expect(event.cursor == 1)
        #expect(event.payload == .accepted(.queued))
        #expect(await outbox.removedRequestIDs == [requestID])
        let status = try await node.requestStatus(requestID)
        #expect(status.phase == .accepted(.queued))
        #expect(status.acknowledgedEventCursor == 1)
    }

    @Test("Role-specific operations fail before touching adapters")
    func enforcesRoles() async throws {
        let node = try makeNode(roles: [.caller])
        try await node.start()

        await #expect(throws: InferPeerNodeError.roleNotEnabled(.worker)) {
            try await node.setParticipation(.available)
        }
    }

    @Test("Configuration requires a coordinator endpoint")
    func requiresCoordinatorEndpoint() {
        #expect(throws: InferPeerNodeError.coordinatorEndpointRequired) {
            _ = try InferPeerNodeConfiguration(roles: [.coordinator])
        }
    }

    private func makeNode(
        roles: Set<NodeRole>,
        endpoint: PeerEndpoint? = nil,
        identity: any IdentityProvider = FakeIdentityProvider(),
        transport: any PeerTransport = FakeTransport(),
        optional: InferPeerOptionalServices = .init()
    ) throws -> InferPeerNode {
        let configuration = try InferPeerNodeConfiguration(
            roles: roles,
            coordinatorEndpoint: endpoint
        )
        let dependencies = InferPeerDependencies(
            identity: identity,
            transport: transport,
            discovery: FakeDiscovery(),
            status: FakeStatusProvider(),
            optional: optional
        )
        return InferPeerNode(configuration: configuration, dependencies: dependencies)
    }

    private func makeInvitation() throws -> PairingInvitation {
        let endpoint = try PeerEndpoint(host: "192.168.1.4", port: 8443)
        let coordinator = PairingCoordinator(
            clusterID: try #require(ClusterID(rawValue: "cluster-1")),
            endpoint: endpoint,
            certificateFingerprint: try CertificateFingerprint(
                bytes: Data(repeating: 0xA5, count: 32)
            )
        )
        return PairingInvitation(
            invitationID: try #require(InvitationID(rawValue: "invitation-1")),
            coordinator: coordinator,
            expiresAt: Date().addingTimeInterval(60),
            proof: Data([0x01])
        )
    }

    private func makeArtifact() throws -> LocalModelArtifact {
        let reference = try ModelReference(
            modelID: #require(ModelID(rawValue: "model-1")),
            revision: "revision-1"
        )
        let metadata = try ModelMetadata(
            quantization: "4-bit",
            tokenizer: "tokenizer.json",
            chatTemplate: "template",
            license: "Apache-2.0"
        )
        let descriptor = try ModelDescriptor(
            reference: reference,
            runtimeFormat: .mlx,
            metadata: metadata,
            contextTokenLimit: 128,
            contentDigest: ModelContentDigest(bytes: Data(repeating: 0xA5, count: 32))
        )
        return try LocalModelArtifact(
            descriptor: descriptor,
            directoryURL: URL(fileURLWithPath: "/models/model-1", isDirectory: true)
        )
    }

    private func makeRequest() throws -> TextGenerationRequest {
        let context = try ConversationContext(
            conversationID: #require(ConversationID(rawValue: "conversation-1")),
            revision: 1,
            messages: [try TextMessage(role: .user, text: "Hello")]
        )
        let options = try GenerationOptions(
            modelRequirement: .exact(makeArtifact().descriptor.reference),
            maximumOutputTokens: 8
        )
        return TextGenerationRequest(context: context, options: options)
    }

    private func acceptedResponse(
        requestID: RequestID,
        cursor: UInt64
    ) -> InferPeer_V1_ClientSessionResponse {
        InferPeer_V1_ClientSessionResponse.with {
            $0.metadata.requestID = requestID.rawValue
            $0.metadata.eventCursor = cursor
            $0.requestAccepted.state = .queued
        }
    }
}
