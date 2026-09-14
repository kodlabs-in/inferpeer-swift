import InferPeerProtocol

extension ModelDescriptor {
    /// Creates a validated descriptor from its protocol representation.
    public init(wireValue: InferPeer_V1_ModelDescriptor) throws {
        guard wireValue.hasReference else {
            throw InferenceValidationError.invalidWireValue(field: .modelReference)
        }
        let metadata = try ModelMetadata(
            quantization: wireValue.quantization,
            tokenizer: wireValue.tokenizer,
            chatTemplate: wireValue.chatTemplate,
            license: wireValue.license
        )
        try self.init(
            reference: ModelReference(wireValue: wireValue.reference),
            runtimeFormat: ModelRuntimeFormat(wireValue: wireValue.runtimeFormat),
            metadata: metadata,
            contextTokenLimit: wireValue.contextTokenLimit,
            contentDigest: ModelContentDigest(bytes: wireValue.contentSha256),
            measuredMemoryBytes: wireValue.hasMeasuredMemoryBytes
                ? wireValue.measuredMemoryBytes
                : nil
        )
    }

    /// The protocol representation of this descriptor.
    public var wireValue: InferPeer_V1_ModelDescriptor {
        InferPeer_V1_ModelDescriptor.with {
            $0.reference = reference.wireValue
            $0.runtimeFormat = runtimeFormat.wireValue
            $0.quantization = metadata.quantization
            $0.tokenizer = metadata.tokenizer
            $0.chatTemplate = metadata.chatTemplate
            $0.contextTokenLimit = contextTokenLimit
            $0.license = metadata.license
            $0.contentSha256 = contentDigest.bytes
            if let measuredMemoryBytes {
                $0.measuredMemoryBytes = measuredMemoryBytes
            }
        }
    }
}

private extension ModelRuntimeFormat {
    init(wireValue: InferPeer_V1_RuntimeFormat) throws {
        switch wireValue {
        case .mlx:
            self = .mlx
        case .unspecified, .UNRECOGNIZED:
            throw InferenceValidationError.invalidWireValue(field: .runtimeFormat)
        }
    }

    var wireValue: InferPeer_V1_RuntimeFormat {
        switch self {
        case .mlx:
            .mlx
        }
    }
}
