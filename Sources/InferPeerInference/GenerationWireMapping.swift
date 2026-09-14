import InferPeerProtocol

extension TextDelta {
    /// Creates a validated text delta from its protocol representation.
    public init(wireValue: InferPeer_V1_TextDelta) throws {
        try self.init(wireValue.text)
    }

    /// The protocol representation of this text delta.
    public var wireValue: InferPeer_V1_TextDelta {
        InferPeer_V1_TextDelta.with {
            $0.text = text
        }
    }
}

extension TokenUsage {
    /// Creates token usage from its protocol representation.
    public init(wireValue: InferPeer_V1_TokenUsage) {
        self.init(
            promptTokens: wireValue.promptTokens,
            outputTokens: wireValue.outputTokens
        )
    }

    /// The protocol representation of this token usage.
    public var wireValue: InferPeer_V1_TokenUsage {
        InferPeer_V1_TokenUsage.with {
            $0.promptTokens = promptTokens
            $0.outputTokens = outputTokens
        }
    }
}

extension GenerationResult {
    /// Creates a completed generation result from its protocol representation.
    public init(wireValue: InferPeer_V1_GenerationCompleted) throws {
        guard wireValue.hasModelUsed else {
            throw InferenceValidationError.invalidWireValue(field: .modelReference)
        }
        guard wireValue.hasUsage else {
            throw InferenceValidationError.invalidWireValue(field: .tokenUsage)
        }
        self.init(
            fullText: wireValue.fullText,
            modelUsed: try ModelReference(wireValue: wireValue.modelUsed),
            finishReason: try GenerationFinishReason(wireValue: wireValue.finishReason),
            usage: TokenUsage(wireValue: wireValue.usage)
        )
    }

    /// The protocol representation of this completed result.
    public var wireValue: InferPeer_V1_GenerationCompleted {
        InferPeer_V1_GenerationCompleted.with {
            $0.fullText = fullText
            $0.modelUsed = modelUsed.wireValue
            $0.finishReason = finishReason.wireValue
            $0.usage = usage.wireValue
        }
    }
}

private extension GenerationFinishReason {
    init(wireValue: InferPeer_V1_FinishReason) throws {
        switch wireValue {
        case .stop:
            self = .stop
        case .maximumTokens:
            self = .maximumTokens
        case .unspecified, .UNRECOGNIZED:
            throw InferenceValidationError.invalidWireValue(field: .finishReason)
        }
    }

    var wireValue: InferPeer_V1_FinishReason {
        switch self {
        case .stop:
            .stop
        case .maximumTokens:
            .maximumTokens
        }
    }
}
