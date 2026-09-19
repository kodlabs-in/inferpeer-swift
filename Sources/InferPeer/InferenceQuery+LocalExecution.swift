import InferPeerCore
import InferPeerInference
import InferPeerProtocol

extension InferenceQuery {
    func textQuery() throws -> TextInferenceQuery {
        switch self {
        case .text(let query):
            query
        case .vision, .audioTranscription, .speechSynthesis:
            throw InferPeerError(
                code: .unsupportedTask,
                message: "The selected local runtime does not support this task",
                isRetryable: false
            )
        }
    }
}

extension TextInferenceQuery {
    func legacyRequest(
        conversationID: ConversationID,
        model: ModelKey
    ) throws -> TextGenerationRequest {
        guard !messages.isEmpty else {
            throw InferPeerError(
                code: .invalidRequest,
                message: "A text query requires at least one message",
                isRetryable: false
            )
        }
        let legacyMessages = try messages.map { try TextMessage(role: $0.role, text: $0.text) }
        let context = try ConversationContext(
            conversationID: conversationID,
            revision: 1,
            messages: legacyMessages
        )
        let sampling = try SamplingOptions(
            temperature: generation.temperature,
            topP: generation.topP,
            seed: generation.seed
        )
        let options = try GenerationOptions(
            modelRequirement: .exact(model),
            maximumOutputTokens: generation.maxOutputTokens,
            sampling: sampling
        )
        return TextGenerationRequest(context: context, options: options)
    }
}
