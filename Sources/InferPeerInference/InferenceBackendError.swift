/// A typed failure reported by an inference backend.
public enum InferenceBackendError: Error, Equatable, Sendable {
    /// The request cannot be executed as supplied.
    case invalidRequest

    /// The request exceeds the selected model's context limit.
    case contextTooLarge(limit: UInt32)

    /// The requested model is unavailable to this backend.
    case modelUnavailable(ModelReference)

    /// The backend cannot safely admit the request with its current resources.
    case resourceExhausted

    /// The request deadline elapsed before successful completion.
    case deadlineExceeded

    /// The attempt ended because cancellation was requested.
    case cancelled

    /// Model loading failed, with explicit transient-failure classification.
    case modelLoadFailed(retryable: Bool)

    /// Model execution failed, with explicit transient-failure classification.
    case executionFailed(retryable: Bool)

    /// Whether retrying this operation may succeed without changing the request.
    public var isRetryable: Bool {
        switch self {
        case .modelLoadFailed(let retryable), .executionFailed(let retryable):
            retryable
        default:
            false
        }
    }
}
