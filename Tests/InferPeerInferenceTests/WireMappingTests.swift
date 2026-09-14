import Foundation
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Inference wire mapping")
struct WireMappingTests {
    @Test("Round-trips a complete text request without losing intent")
    func textRequestRoundTrip() throws {
        let request = try makeRequest()

        let wireValue = request.wireValue
        let decoded = try TextGenerationRequest(wireValue: wireValue)

        #expect(decoded == request)
        #expect(wireValue.messages.map(\.role) == [.system, .user])
        #expect(wireValue.allowedWorkerIds == ["worker-a", "worker-b"])
        #expect(wireValue.hasDeadlineUnixMilliseconds)
    }

    @Test("Round-trips model metadata and completed output")
    func modelAndResultRoundTrip() throws {
        let descriptor = try makeDescriptor()
        let result = GenerationResult(
            fullText: "Hello",
            modelUsed: descriptor.reference,
            finishReason: .maximumTokens,
            usage: TokenUsage(promptTokens: 12, outputTokens: 4)
        )

        let decodedDescriptor = try ModelDescriptor(wireValue: descriptor.wireValue)
        let decodedResult = try GenerationResult(wireValue: result.wireValue)

        #expect(decodedDescriptor == descriptor)
        #expect(decodedResult == result)
    }

    @Test("Rejects unknown required wire enums")
    func rejectsUnknownWireEnum() throws {
        let unknownRole = try #require(InferPeer_V1_MessageRole(rawValue: 999))
        let message = InferPeer_V1_TextMessage.with {
            $0.role = unknownRole
            $0.text = "Hello"
        }

        #expect(throws: InferenceValidationError.invalidWireValue(field: .messageRole)) {
            try TextMessage(wireValue: message)
        }
    }

    private func makeRequest() throws -> TextGenerationRequest {
        let conversationID = try #require(ConversationID(rawValue: "conversation-1"))
        let workerA = try #require(PeerID(rawValue: "worker-a"))
        let workerB = try #require(PeerID(rawValue: "worker-b"))
        let context = try ConversationContext(
            conversationID: conversationID,
            revision: 2,
            messages: [
                try TextMessage(role: .system, text: "Be concise."),
                try TextMessage(role: .user, text: "Hello"),
            ]
        )
        let firstModel = try makeModelReference(id: "model-a")
        let secondModel = try makeModelReference(id: "model-b")
        let options = try GenerationOptions(
            modelRequirement: try .permitting([firstModel, secondModel]),
            maximumOutputTokens: 128,
            sampling: try SamplingOptions(temperature: 0.2, topP: 0.9, seed: 42),
            deadline: Date(timeIntervalSince1970: 2_000_000_000)
        )
        return TextGenerationRequest(
            context: context,
            options: options,
            allowedWorkerIDs: [workerB, workerA]
        )
    }

    private func makeModelReference(id: String) throws -> ModelReference {
        let modelID = try #require(ModelID(rawValue: id))
        return try ModelReference(modelID: modelID, revision: "revision-1")
    }

    private func makeDescriptor() throws -> ModelDescriptor {
        let metadata = try ModelMetadata(
            quantization: "Q4_K_M",
            tokenizer: "tokenizer.json",
            chatTemplate: "chat-template",
            license: "Apache-2.0"
        )
        return try ModelDescriptor(
            reference: makeModelReference(id: "model-a"),
            runtimeFormat: .mlx,
            metadata: metadata,
            contextTokenLimit: 4_096,
            contentDigest: ModelContentDigest(bytes: Data(repeating: 0xA5, count: 32)),
            measuredMemoryBytes: 2_000_000_000
        )
    }
}
