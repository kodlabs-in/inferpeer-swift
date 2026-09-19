import Foundation
import InferPeerInference
import Testing

@Suite("Direct inference query schemas")
struct DirectInferenceQueryTests {
    @Test("Every v2 query reports its exact task")
    func taskIdentityIsExplicit() {
        let model = InferenceModelSelection.taskDefault
        let image = InferenceAssetReference.file(URL(fileURLWithPath: "/tmp/input.jpg"))
        let audio = InferenceAssetReference.file(URL(fileURLWithPath: "/tmp/input.wav"))

        let queries: [(InferenceQuery, InferenceTask)] = [
            (
                .text(model: model, messages: [.user("Hello")]),
                .textGeneration
            ),
            (
                .vision(
                    model: model,
                    messages: [.user("Describe the image")],
                    images: [image]
                ),
                .imageUnderstanding
            ),
            (
                .transcribe(
                    model: model,
                    audio: audio,
                    mode: .transcription
                ),
                .transcribe
            ),
            (
                .synthesizeSpeech(
                    model: model,
                    voiceID: "test-voice",
                    text: "Hello"
                ),
                .synthesizeSpeech
            ),
        ]

        for (query, expectedTask) in queries {
            #expect(query.task == expectedTask)
        }
    }

    @Test("V2 query bounds reject malformed and oversized inputs before admission")
    func validatesDirectQueryBounds() throws {
        #expect(throws: InferenceQueryValidationError.emptyInput) {
            try InferenceQuery.text(
                model: .taskDefault,
                messages: []
            ).validate()
        }
        #expect(throws: InferenceQueryValidationError.invalidGenerationOptions) {
            try InferenceQuery.text(
                model: .taskDefault,
                messages: [.user("Hello")],
                generation: .init(maxOutputTokens: 0)
            ).validate()
        }
        #expect(throws: InferenceQueryValidationError.inputTooLarge) {
            try InferenceQuery.vision(
                model: .taskDefault,
                messages: [.user("Describe")],
                images: Array(
                    repeating: .file(URL(fileURLWithPath: "/tmp/input.jpg")),
                    count: 9
                )
            ).validate()
        }
        #expect(throws: InferenceQueryValidationError.invalidAsset) {
            try InferenceQuery.transcribe(
                model: .taskDefault,
                audio: .receipt(.init(rawValue: ""))
            ).validate()
        }
        #expect(throws: InferenceQueryValidationError.inputTooLarge) {
            try InferenceQuery.synthesizeSpeech(
                model: .taskDefault,
                voiceID: "voice",
                text: String(repeating: "a", count: 8_001)
            ).validate()
        }
    }
}
