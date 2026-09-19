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

    /// The selected resource does not advertise the requested operation.
    public static let unsupportedTask = Self(rawValue: 13)

    /// The selected resource does not support one explicitly requested option.
    public static let unsupportedOption = Self(rawValue: 14)

    /// One request identity was reused for different immutable content.
    public static let requestConflict = Self(rawValue: 15)

    /// Execution stopped because its process or execution grant was lost.
    public static let interrupted = Self(rawValue: 16)

    /// Local-network permission or route policy denied the operation.
    public static let localNetworkDenied = Self(rawValue: 17)
    /// Direct-resource discovery cannot run in the current environment.
    public static let discoveryUnavailable = Self(rawValue: 18)
    /// The resource has no approved pairing for this app identity.
    public static let notPaired = Self(rawValue: 19)
    /// Current lifecycle state forbids background execution.
    public static let backgroundRestricted = Self(rawValue: 20)
    /// Current thermal policy forbids or stopped execution.
    public static let thermalLimited = Self(rawValue: 21)
    /// Current power policy forbids execution.
    public static let batteryPolicy = Self(rawValue: 22)
    /// The exact artifact is incompatible with the selected runtime.
    public static let modelIncompatible = Self(rawValue: 23)
    /// Verified model content or structure is corrupt.
    public static let modelCorrupt = Self(rawValue: 24)
    /// The selected resource cannot safely reserve enough memory.
    public static let insufficientMemory = Self(rawValue: 25)
    /// A bounded request input exceeds its negotiated limit.
    public static let inputTooLarge = Self(rawValue: 26)
    /// Uploaded asset content or metadata failed validation.
    public static let assetInvalid = Self(rawValue: 27)
    /// An asset ticket or retained receipt expired.
    public static let assetExpired = Self(rawValue: 28)
    /// An upload did not resume from the resource-confirmed offset.
    public static let uploadOffsetMismatch = Self(rawValue: 29)
    /// The authenticated connection ended before reconciliation.
    public static let connectionLost = Self(rawValue: 30)
    /// Acceptance or terminal outcome cannot yet be reconciled.
    public static let outcomeUnknown = Self(rawValue: 31)
    /// Request metadata is outside its retention window.
    public static let historyExpired = Self(rawValue: 32)
    /// Terminal status remains, but its result content was not retained.
    public static let resultExpired = Self(rawValue: 33)
    /// A bounded output consumer could not keep up safely.
    public static let outputBackpressure = Self(rawValue: 34)
    /// Required private persistence has no remaining capacity.
    public static let storageFull = Self(rawValue: 35)
    /// The selected resource's bounded queue is full.
    public static let queueFull = Self(rawValue: 36)
    /// Runtime loading of a verified model artifact failed.
    public static let modelLoadFailed = Self(rawValue: 37)

    /// Compatibility alias for failed authentication.
    public static let authenticationFailed = unauthenticated
    /// Compatibility alias for a selected unavailable resource.
    public static let resourceUnavailable = workerUnavailable
    /// Compatibility alias for an unavailable exact model artifact.
    public static let modelNotInstalled = modelUnavailable

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
        unsupportedTask.rawValue: "Task is unsupported",
        unsupportedOption.rawValue: "Option is unsupported",
        requestConflict.rawValue: "Request identity conflicts with existing content",
        interrupted.rawValue: "Execution was interrupted",
        localNetworkDenied.rawValue: "Local network access is denied",
        discoveryUnavailable.rawValue: "Discovery is unavailable",
        notPaired.rawValue: "Resource is not paired",
        backgroundRestricted.rawValue: "Background execution is restricted",
        thermalLimited.rawValue: "Resource is thermally limited",
        batteryPolicy.rawValue: "Battery policy prevents execution",
        modelIncompatible.rawValue: "Model is incompatible",
        modelCorrupt.rawValue: "Model is corrupt",
        insufficientMemory.rawValue: "Insufficient memory",
        inputTooLarge.rawValue: "Input is too large",
        assetInvalid.rawValue: "Asset is invalid",
        assetExpired.rawValue: "Asset has expired",
        uploadOffsetMismatch.rawValue: "Upload offset does not match",
        connectionLost.rawValue: "Connection was lost",
        outcomeUnknown.rawValue: "Request outcome is unknown",
        historyExpired.rawValue: "Request history has expired",
        resultExpired.rawValue: "Request result has expired",
        outputBackpressure.rawValue: "Output consumer is too slow",
        storageFull.rawValue: "Storage is full",
        queueFull.rawValue: "Queue is full",
        modelLoadFailed.rawValue: "Model loading failed",
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

    /// Creates a public error from the isolated v2 direct-resource wire contract.
    public init(wireValue: InferPeer_V2_ErrorDetail) {
        code = Self.v2Codes[wireValue.code.rawValue] ?? .unrecognized(wireValue.code.rawValue)
        message = wireValue.safeMessage
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

    /// The v2 direct-resource protocol representation of this public error.
    public var v2WireValue: InferPeer_V2_ErrorDetail {
        InferPeer_V2_ErrorDetail.with {
            $0.code = Self.v2WireCodes[code] ?? .UNRECOGNIZED(code.rawValue)
            $0.safeMessage = message
            $0.retryable = isRetryable
        }
    }

    private static let v2Codes: [Int: InferPeerErrorCode] = [
        InferPeer_V2_ErrorCode.localNetworkDenied.rawValue: .localNetworkDenied,
        InferPeer_V2_ErrorCode.discoveryUnavailable.rawValue: .discoveryUnavailable,
        InferPeer_V2_ErrorCode.notPaired.rawValue: .notPaired,
        InferPeer_V2_ErrorCode.authenticationFailed.rawValue: .authenticationFailed,
        InferPeer_V2_ErrorCode.permissionDenied.rawValue: .permissionDenied,
        InferPeer_V2_ErrorCode.protocolMismatch.rawValue: .protocolMismatch,
        InferPeer_V2_ErrorCode.unsupportedTask.rawValue: .unsupportedTask,
        InferPeer_V2_ErrorCode.unsupportedOption.rawValue: .unsupportedOption,
        InferPeer_V2_ErrorCode.resourceUnavailable.rawValue: .resourceUnavailable,
        InferPeer_V2_ErrorCode.backgroundRestricted.rawValue: .backgroundRestricted,
        InferPeer_V2_ErrorCode.thermalLimited.rawValue: .thermalLimited,
        InferPeer_V2_ErrorCode.batteryPolicy.rawValue: .batteryPolicy,
        InferPeer_V2_ErrorCode.modelNotInstalled.rawValue: .modelNotInstalled,
        InferPeer_V2_ErrorCode.modelIncompatible.rawValue: .modelIncompatible,
        InferPeer_V2_ErrorCode.modelCorrupt.rawValue: .modelCorrupt,
        InferPeer_V2_ErrorCode.modelLoadFailed.rawValue: .modelLoadFailed,
        InferPeer_V2_ErrorCode.insufficientMemory.rawValue: .insufficientMemory,
        InferPeer_V2_ErrorCode.contextTooLarge.rawValue: .contextTooLarge,
        InferPeer_V2_ErrorCode.inputTooLarge.rawValue: .inputTooLarge,
        InferPeer_V2_ErrorCode.queueFull.rawValue: .queueFull,
        InferPeer_V2_ErrorCode.assetInvalid.rawValue: .assetInvalid,
        InferPeer_V2_ErrorCode.assetExpired.rawValue: .assetExpired,
        InferPeer_V2_ErrorCode.uploadOffsetMismatch.rawValue: .uploadOffsetMismatch,
        InferPeer_V2_ErrorCode.requestConflict.rawValue: .requestConflict,
        InferPeer_V2_ErrorCode.deadlineExceeded.rawValue: .deadlineExceeded,
        InferPeer_V2_ErrorCode.cancelled.rawValue: .cancelled,
        InferPeer_V2_ErrorCode.interrupted.rawValue: .interrupted,
        InferPeer_V2_ErrorCode.connectionLost.rawValue: .connectionLost,
        InferPeer_V2_ErrorCode.outcomeUnknown.rawValue: .outcomeUnknown,
        InferPeer_V2_ErrorCode.replayExpired.rawValue: .replayExpired,
        InferPeer_V2_ErrorCode.historyExpired.rawValue: .historyExpired,
        InferPeer_V2_ErrorCode.resultExpired.rawValue: .resultExpired,
        InferPeer_V2_ErrorCode.outputBackpressure.rawValue: .outputBackpressure,
        InferPeer_V2_ErrorCode.storageFull.rawValue: .storageFull,
        InferPeer_V2_ErrorCode.internal.rawValue: .internal,
        InferPeer_V2_ErrorCode.invalidRequest.rawValue: .invalidRequest,
        InferPeer_V2_ErrorCode.resourceExhausted.rawValue: .resourceExhausted,
    ]

    private static let v2WireCodes: [InferPeerErrorCode: InferPeer_V2_ErrorCode] =
        v2Codes.reduce(into: [:]) { result, entry in
            guard let wireCode = InferPeer_V2_ErrorCode(rawValue: entry.key) else { return }
            result[entry.value] = wireCode
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
