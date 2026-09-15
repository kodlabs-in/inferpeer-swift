import Foundation
@testable import InferPeer
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage
import InferPeerTelemetry
import Testing

extension InferPeerNodeTests {
    func makeNode(
        roles: Set<NodeRole>,
        endpoint: PeerEndpoint? = nil,
        identity: any IdentityProvider = FakeIdentityProvider(),
        transport: any PeerTransport = FakeTransport(),
        optional: InferPeerOptionalServices = .init()
    ) throws -> InferPeerNode {
        let resolvedOptional = InferPeerOptionalServices(
            coordinator: optional.coordinator
                ?? (roles.contains(.coordinator) ? FakeCoordinatorService() : nil),
            modelRegistry: optional.modelRegistry,
            callerOutbox: optional.callerOutbox,
            inferenceBackend: optional.inferenceBackend
                ?? (roles.contains(.worker) ? FakeInferenceBackend() : nil),
            advertisement: optional.advertisement
        )
        let configuration = try InferPeerNodeConfiguration(
            roles: roles,
            coordinatorEndpoint: endpoint
        )
        let dependencies = InferPeerDependencies(
            identity: identity,
            transport: transport,
            discovery: FakeDiscovery(),
            status: FakeStatusProvider(),
            optional: resolvedOptional
        )
        return InferPeerNode(configuration: configuration, dependencies: dependencies)
    }

    func makeInvitation() throws -> PairingInvitation {
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

    func makeArtifact() throws -> LocalModelArtifact {
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

    func makeRequest() throws -> TextGenerationRequest {
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

    func acceptedResponse(
        requestID: RequestID,
        cursor: UInt64
    ) -> InferPeer_V1_ClientSessionResponse {
        InferPeer_V1_ClientSessionResponse.with {
            $0.metadata.requestID = requestID.rawValue
            $0.metadata.eventCursor = cursor
            $0.requestAccepted.state = .queued
        }
    }

    func stateResponse(
        requestID: RequestID,
        cursor: UInt64,
        state: InferPeer_V1_RequestState
    ) -> InferPeer_V1_ClientSessionResponse {
        InferPeer_V1_ClientSessionResponse.with {
            $0.metadata.requestID = requestID.rawValue
            $0.metadata.eventCursor = cursor
            $0.requestStateChanged.state = state
            $0.requestStateChanged.attemptNumber = 1
        }
    }
}
