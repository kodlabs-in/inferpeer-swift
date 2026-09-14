import Foundation

/// A required metadata field in a model descriptor.
public enum ModelMetadataField: String, Equatable, Sendable {
    /// The model's quantization description.
    case quantization

    /// The tokenizer identity or relative filename.
    case tokenizer

    /// The chat-template identity.
    case chatTemplate

    /// The model's license identifier.
    case license
}

/// A backend-neutral model runtime representation.
public enum ModelRuntimeFormat: String, Sendable {
    /// The MLX model format used by the optional InferPeerMLX adapter.
    case mlx
}

/// Immutable descriptive metadata needed to execute and audit a model.
public struct ModelMetadata: Hashable, Sendable {
    /// The model's quantization description.
    public let quantization: String

    /// The tokenizer identity or relative filename.
    public let tokenizer: String

    /// The chat-template identity.
    public let chatTemplate: String

    /// The model's license identifier.
    public let license: String

    /// Creates validated model metadata.
    public init(
        quantization: String,
        tokenizer: String,
        chatTemplate: String,
        license: String
    ) throws {
        try Self.requireValue(quantization, for: .quantization)
        try Self.requireValue(tokenizer, for: .tokenizer)
        try Self.requireValue(chatTemplate, for: .chatTemplate)
        try Self.requireValue(license, for: .license)

        self.quantization = quantization
        self.tokenizer = tokenizer
        self.chatTemplate = chatTemplate
        self.license = license
    }

    private static func requireValue(_ value: String, for field: ModelMetadataField) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InferenceValidationError.emptyModelMetadata(field: field)
        }
    }
}

/// The SHA-256 digest of a model artifact's verified contents.
public struct ModelContentDigest: Hashable, Sendable {
    /// The required length of a SHA-256 digest.
    public static let byteCount = 32

    /// The digest bytes.
    public let bytes: Data

    /// Creates a digest from exactly 32 bytes.
    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw InferenceValidationError.invalidContentDigestLength(actual: bytes.count)
        }
        self.bytes = bytes
    }
}

/// Immutable identity, compatibility, and resource metadata for a registered model.
public struct ModelDescriptor: Hashable, Sendable {
    /// The exact model revision.
    public let reference: ModelReference

    /// The runtime representation required to load the model.
    public let runtimeFormat: ModelRuntimeFormat

    /// Descriptive execution and licensing metadata.
    public let metadata: ModelMetadata

    /// The maximum supported combined prompt and generation token count.
    public let contextTokenLimit: UInt32

    /// The verified digest of the model artifact.
    public let contentDigest: ModelContentDigest

    /// A measured peak memory cost, when known.
    public let measuredMemoryBytes: UInt64?

    /// Creates a validated model descriptor.
    public init(
        reference: ModelReference,
        runtimeFormat: ModelRuntimeFormat,
        metadata: ModelMetadata,
        contextTokenLimit: UInt32,
        contentDigest: ModelContentDigest,
        measuredMemoryBytes: UInt64? = nil
    ) throws {
        guard contextTokenLimit > 0 else {
            throw InferenceValidationError.invalidContextTokenLimit
        }
        if let measuredMemoryBytes, measuredMemoryBytes == 0 {
            throw InferenceValidationError.invalidMeasuredMemory
        }

        self.reference = reference
        self.runtimeFormat = runtimeFormat
        self.metadata = metadata
        self.contextTokenLimit = contextTokenLimit
        self.contentDigest = contentDigest
        self.measuredMemoryBytes = measuredMemoryBytes
    }
}

/// A verified model descriptor paired with its host-provided local directory.
public struct LocalModelArtifact: Hashable, Sendable {
    /// The model's immutable descriptor.
    public let descriptor: ModelDescriptor

    /// The local directory containing model files.
    public let directoryURL: URL

    /// Creates a local artifact from a file URL without accessing the filesystem.
    public init(descriptor: ModelDescriptor, directoryURL: URL) throws {
        guard directoryURL.isFileURL else {
            throw InferenceValidationError.invalidModelDirectory
        }
        self.descriptor = descriptor
        self.directoryURL = directoryURL
    }
}
