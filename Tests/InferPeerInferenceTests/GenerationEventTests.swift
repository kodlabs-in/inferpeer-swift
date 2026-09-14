import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Inference generation events")
struct GenerationEventTests {
    @Test("Carries streamed text and one complete result")
    func carriesGenerationProgress() throws {
        let reference = try makeModelReference()
        let delta = try TextDelta("Hello")
        let result = GenerationResult(
            fullText: "Hello there",
            modelUsed: reference,
            finishReason: .stop,
            usage: TokenUsage(promptTokens: 5, outputTokens: 2)
        )
        let events: [GenerationEvent] = [
            .textDelta(delta),
            .completed(result),
        ]

        #expect(events.first == .textDelta(delta))
        #expect(events.last == .completed(result))
        #expect(result.modelUsed == reference)
    }

    @Test("Rejects an empty streamed text fragment")
    func rejectsEmptyDelta() {
        #expect(throws: InferenceValidationError.emptyTextDelta) {
            try TextDelta("")
        }
    }

    private func makeModelReference() throws -> ModelReference {
        let modelID = try #require(ModelID(rawValue: "model-1"))
        return try ModelReference(modelID: modelID, revision: "revision-1")
    }
}
