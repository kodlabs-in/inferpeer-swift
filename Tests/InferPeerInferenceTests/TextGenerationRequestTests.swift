import Foundation
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Text generation requests")
struct TextGenerationRequestTests {
    @Test("Preserves an immutable ordered context snapshot")
    func preservesContextSnapshot() throws {
        let conversationID = try #require(ConversationID(rawValue: "conversation-1"))
        let workerID = try #require(PeerID(rawValue: "worker-1"))
        let context = try ConversationContext(
            conversationID: conversationID,
            revision: 3,
            messages: [
                try TextMessage(role: .system, text: "Answer concisely."),
                try TextMessage(role: .user, text: "Hello"),
            ]
        )
        let sampling = try SamplingOptions(temperature: 0.2, topP: 0.9, seed: 42)
        let options = try GenerationOptions(
            modelRequirement: .exact(try makeModelReference()),
            maximumOutputTokens: 128,
            sampling: sampling,
            deadline: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let request = TextGenerationRequest(
            context: context,
            options: options,
            allowedWorkerIDs: [workerID]
        )

        #expect(request.context.messages.map(\.role) == [.system, .user])
        #expect(request.context.revision == 3)
        #expect(request.options.maximumOutputTokens == 128)
        #expect(request.allowedWorkerIDs == [workerID])
    }

    @Test("Rejects malformed context and generation options")
    func rejectsMalformedRequestValues() throws {
        let conversationID = try #require(ConversationID(rawValue: "conversation-1"))

        #expect(throws: InferenceValidationError.emptyMessage) {
            try TextMessage(role: .user, text: "")
        }
        #expect(throws: InferenceValidationError.emptyConversation) {
            try ConversationContext(
                conversationID: conversationID,
                revision: 1,
                messages: []
            )
        }
        #expect(throws: InferenceValidationError.invalidTemperature) {
            try SamplingOptions(temperature: -.infinity)
        }
        #expect(throws: InferenceValidationError.invalidTopP) {
            try SamplingOptions(topP: 1.1)
        }
        #expect(throws: InferenceValidationError.emptyPermittedModels) {
            try ModelRequirement.permitting([])
        }
        #expect(throws: InferenceValidationError.invalidMaximumOutputTokens) {
            try GenerationOptions(
                modelRequirement: .exact(try makeModelReference()),
                maximumOutputTokens: 0
            )
        }
    }

    @Test("Generation output defaults to and is capped at 512 tokens")
    func validatesMaximumOutputTokenLimit() throws {
        let defaultOptions = try GenerationOptions(
            modelRequirement: .exact(try makeModelReference())
        )

        #expect(defaultOptions.maximumOutputTokens == 512)
        #expect(throws: InferenceValidationError.invalidMaximumOutputTokens) {
            try GenerationOptions(
                modelRequirement: .exact(makeModelReference()),
                maximumOutputTokens: 513
            )
        }
    }

    private func makeModelReference() throws -> ModelReference {
        let modelID = try #require(ModelID(rawValue: "model-1"))
        return try ModelReference(modelID: modelID, revision: "revision-1")
    }
}
