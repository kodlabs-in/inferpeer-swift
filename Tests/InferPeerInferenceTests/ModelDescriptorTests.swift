import Foundation
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Inference model descriptors")
struct ModelDescriptorTests {
    @Test("Creates an exact model reference")
    func createsModelReference() throws {
        let modelID = try #require(ModelID(rawValue: "smollm2-1.7b"))

        let reference = try ModelReference(modelID: modelID, revision: "revision-42")

        #expect(reference.modelID == modelID)
        #expect(reference.revision == "revision-42")
    }

    @Test("Rejects an invalid model revision")
    func rejectsInvalidRevision() throws {
        let modelID = try #require(ModelID(rawValue: "model-1"))

        #expect(throws: InferenceValidationError.invalidModelRevision) {
            try ModelReference(modelID: modelID, revision: "")
        }
        #expect(throws: InferenceValidationError.invalidModelRevision) {
            try ModelReference(modelID: modelID, revision: "contains space")
        }
    }

    @Test("Describes a verified local model artifact")
    func describesLocalModelArtifact() throws {
        let reference = try makeReference()
        let metadata = try ModelMetadata(
            quantization: "Q4_K_M",
            tokenizer: "tokenizer.json",
            chatTemplate: "chat-template",
            license: "Apache-2.0"
        )
        let digest = try ModelContentDigest(bytes: Data(repeating: 0xA5, count: 32))
        let descriptor = try ModelDescriptor(
            reference: reference,
            runtimeFormat: .mlx,
            metadata: metadata,
            contextTokenLimit: 4_096,
            contentDigest: digest,
            measuredMemoryBytes: 2_000_000_000
        )
        let artifact = try LocalModelArtifact(
            descriptor: descriptor,
            directoryURL: URL(fileURLWithPath: "/models/smollm", isDirectory: true)
        )

        #expect(artifact.descriptor == descriptor)
        #expect(artifact.directoryURL.isFileURL)
        #expect(descriptor.contentDigest.bytes.count == ModelContentDigest.byteCount)
    }

    @Test("Rejects malformed model registration values")
    func rejectsMalformedDescriptor() throws {
        let reference = try makeReference()
        let metadata = try ModelMetadata(
            quantization: "Q4_K_M",
            tokenizer: "tokenizer.json",
            chatTemplate: "chat-template",
            license: "Apache-2.0"
        )
        let digest = try ModelContentDigest(bytes: Data(repeating: 0xA5, count: 32))

        #expect(throws: InferenceValidationError.invalidContentDigestLength(actual: 31)) {
            try ModelContentDigest(bytes: Data(repeating: 0xA5, count: 31))
        }
        #expect(throws: InferenceValidationError.invalidContextTokenLimit) {
            try ModelDescriptor(
                reference: reference,
                runtimeFormat: .mlx,
                metadata: metadata,
                contextTokenLimit: 0,
                contentDigest: digest
            )
        }
        #expect(throws: InferenceValidationError.invalidModelDirectory) {
            try LocalModelArtifact(
                descriptor: try makeDescriptor(),
                directoryURL: try #require(URL(string: "https://example.com/model"))
            )
        }
    }

    private func makeReference() throws -> ModelReference {
        let modelID = try #require(ModelID(rawValue: "smollm2-1.7b"))
        return try ModelReference(modelID: modelID, revision: "revision-42")
    }

    private func makeDescriptor() throws -> ModelDescriptor {
        let metadata = try ModelMetadata(
            quantization: "Q4_K_M",
            tokenizer: "tokenizer.json",
            chatTemplate: "chat-template",
            license: "Apache-2.0"
        )
        return try ModelDescriptor(
            reference: makeReference(),
            runtimeFormat: .mlx,
            metadata: metadata,
            contextTokenLimit: 4_096,
            contentDigest: ModelContentDigest(bytes: Data(repeating: 0xA5, count: 32))
        )
    }
}
