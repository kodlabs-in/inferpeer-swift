import InferPeerInference
import InferPeerProtocol

/// A stable, forward-compatible InferPeer error code.
public struct InferPeerErrorCode: RawRepresentable, Hashable, Sendable {
    /// The protocol enum's numeric value.
    public let rawValue: Int

    /// The peer did not authenticate successfully.
    public static let unauthenticated = Self(rawValue: 1)

    /// The authenticated peer lacks permission for the operation.
    public static let permissionDenied = Self(rawValue: 2)

    /// The peers could not negotiate a compatible protocol.
    public static let protocolMismatch = Self(rawValue: 3)

    /// The request is structurally or semantically invalid.
    public static let invalidRequest = Self(rawValue: 4)

    /// The complete context exceeds a selected model's limit.
    public static let contextTooLarge = Self(rawValue: 5)

    /// The required model revision is unavailable.
    public static let modelUnavailable = Self(rawValue: 6)

    /// No worker can currently execute the request.
    public static let workerUnavailable = Self(rawValue: 7)

    /// A queue, memory, stream, or storage limit was reached.
    public static let resourceExhausted = Self(rawValue: 8)

    /// The request deadline elapsed.
    public static let deadlineExceeded = Self(rawValue: 9)

    /// Cancellation became the terminal outcome.
    public static let cancelled = Self(rawValue: 10)

    /// Requested replay data is no longer retained.
    public static let replayExpired = Self(rawValue: 11)

    /// An implementation failure has no safer public classification.
    public static let `internal` = Self(rawValue: 12)

    /// Creates a code from its stable protocol number.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Preserves an error code introduced by a future protocol revision.
    public static func unrecognized(_ rawValue: Int) -> Self {
        Self(rawValue: rawValue)
    }

    /// A safe default message that contains no request or model payload.
    public var defaultMessage: String {
        Self.defaultMessages[rawValue] ?? "Unrecognized InferPeer error"
    }

    private static let defaultMessages: [Int: String] = [
        unauthenticated.rawValue: "Authentication failed",
        permissionDenied.rawValue: "Permission denied",
        protocolMismatch.rawValue: "Protocol mismatch",
        invalidRequest.rawValue: "Invalid request",
        contextTooLarge.rawValue: "Context is too large",
        modelUnavailable.rawValue: "Model is unavailable",
        workerUnavailable.rawValue: "Worker is unavailable",
        resourceExhausted.rawValue: "Resource limit reached",
        deadlineExceeded.rawValue: "Request deadline exceeded",
        cancelled.rawValue: "Request cancelled",
        replayExpired.rawValue: "Replay data expired",
        `internal`.rawValue: "Internal failure",
    ]
}

/// A stable public failure without private prompt, output, or credential data.
public struct InferPeerError: Error, Equatable, Sendable {
    /// The stable error classification.
    public let code: InferPeerErrorCode

    /// A payload-safe diagnostic message.
    public let message: String

    /// Whether the same operation may succeed without changing its input.
    public let isRetryable: Bool

    /// Creates an explicitly classified public error.
    public init(code: InferPeerErrorCode, message: String? = nil, isRetryable: Bool) {
        self.code = code
        self.message = message ?? code.defaultMessage
        self.isRetryable = isRetryable
    }

    /// Creates a public error from a backend failure.
    public init(backendError: InferenceBackendError) {
        let code = Self.code(for: backendError)
        self.init(code: code, isRetryable: backendError.isRetryable)
    }

    /// Creates an error while preserving unknown protocol enum values.
    public init(wireValue: InferPeer_V1_ProtocolError) {
        code = InferPeerErrorCode(rawValue: wireValue.code.rawValue)
        message = wireValue.message
        isRetryable = wireValue.retryable
    }

    /// The protocol representation of this public error.
    public var wireValue: InferPeer_V1_ProtocolError {
        InferPeer_V1_ProtocolError.with {
            $0.code = InferPeer_V1_ErrorCode(rawValue: code.rawValue) ?? .internal
            $0.message = message
            $0.retryable = isRetryable
        }
    }

    private static func code(for error: InferenceBackendError) -> InferPeerErrorCode {
        switch error {
        case .invalidRequest:
            .invalidRequest
        case .contextTooLarge:
            .contextTooLarge
        case .modelUnavailable, .modelLoadFailed:
            .modelUnavailable
        case .resourceExhausted:
            .resourceExhausted
        case .deadlineExceeded:
            .deadlineExceeded
        case .cancelled:
            .cancelled
        case .executionFailed:
            .internal
        }
    }
}
