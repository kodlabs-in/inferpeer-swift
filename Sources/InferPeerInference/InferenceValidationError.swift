/// A structural validation failure in an inference value.
public enum InferenceValidationError: Error, Equatable, Sendable {
    /// A model revision was empty, too long, or contained non-printable ASCII.
    case invalidModelRevision

    /// Required model metadata was empty.
    case emptyModelMetadata(field: ModelMetadataField)

    /// A model digest was not a SHA-256-sized value.
    case invalidContentDigestLength(actual: Int)

    /// A model declared no usable context tokens.
    case invalidContextTokenLimit

    /// A measured memory value was present but zero.
    case invalidMeasuredMemory

    /// A local model artifact did not reference a file URL.
    case invalidModelDirectory

    /// A text message contained no text.
    case emptyMessage

    /// A conversation snapshot contained no messages.
    case emptyConversation

    /// A sampling temperature was negative or not finite.
    case invalidTemperature

    /// A top-p value was outside the interval `(0, 1]` or was not finite.
    case invalidTopP

    /// A permitted model selection contained no models.
    case emptyPermittedModels

    /// A generation requested zero output tokens.
    case invalidMaximumOutputTokens

    /// A streamed text delta contained no text.
    case emptyTextDelta

    /// A resource estimate supplied a zero, negative, or non-finite metric.
    case invalidResourceEstimate(metric: InferenceResourceMetric)

    /// A deadline cannot be represented as protocol milliseconds since 1970.
    case invalidDeadline

    /// A required protocol field was absent, unknown, or malformed.
    case invalidWireValue(field: InferenceWireField)
}

/// A protocol field that could not be converted into a validated inference value.
public enum InferenceWireField: String, Equatable, Sendable {
    /// A model identifier.
    case modelID

    /// A required model reference message.
    case modelReference

    /// A model runtime format.
    case runtimeFormat

    /// A text-message role.
    case messageRole

    /// A conversation identifier.
    case conversationID

    /// An exact or permitted model selector.
    case modelRequirement

    /// An allowed worker identifier.
    case allowedWorkerID

    /// A generation finish reason.
    case finishReason

    /// Required token-usage measurements.
    case tokenUsage
}
