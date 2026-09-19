import Foundation
import GRPCCore
import InferPeerCore

/// Stable conversion between public direct-resource failures and gRPC status.
public enum DirectRPCErrorMapper {
    /// Converts an application or transport failure to a sanitized gRPC status.
    public static func rpcError(from error: any Error) -> RPCError {
        if let error = error as? RPCError { return error }
        if let error = error as? InferPeerError {
            return RPCError(code: rpcCode(for: error.code), message: error.message)
        }
        return GRPCErrorMapper.rpcError(from: error)
    }

    /// Converts a gRPC failure to the nearest stable direct-resource failure.
    public static func publicError(from error: any Error) -> InferPeerError {
        guard let error = error as? RPCError else {
            if let error = error as? InferPeerError { return error }
            return InferPeerError(code: .internal, isRetryable: false)
        }
        return InferPeerError(
            code: publicCode(for: error.code),
            message: safeMessage(error.message),
            isRetryable: retryable(error.code)
        )
    }

    private static func rpcCode(for code: InferPeerErrorCode) -> RPCError.Code {
        switch code {
        case .unauthenticated, .notPaired: .unauthenticated
        case .permissionDenied, .localNetworkDenied: .permissionDenied
        case .protocolMismatch, .requestConflict: .failedPrecondition
        case .contextTooLarge, .inputTooLarge, .assetInvalid, .invalidRequest,
            .unsupportedOption, .unsupportedTask, .uploadOffsetMismatch:
            .invalidArgument
        case .deadlineExceeded: .deadlineExceeded
        case .cancelled: .cancelled
        case .resourceExhausted, .queueFull, .insufficientMemory, .storageFull,
            .outputBackpressure:
            .resourceExhausted
        case .workerUnavailable, .connectionLost, .discoveryUnavailable:
            .unavailable
        case .assetExpired, .historyExpired, .replayExpired, .resultExpired:
            .notFound
        default: .internalError
        }
    }

    private static func publicCode(for code: RPCError.Code) -> InferPeerErrorCode {
        switch code {
        case .unauthenticated: .unauthenticated
        case .permissionDenied: .permissionDenied
        case .failedPrecondition: .protocolMismatch
        case .invalidArgument: .invalidRequest
        case .deadlineExceeded: .deadlineExceeded
        case .cancelled: .cancelled
        case .resourceExhausted: .resourceExhausted
        case .unavailable: .connectionLost
        case .notFound: .historyExpired
        default: .internal
        }
    }

    private static func retryable(_ code: RPCError.Code) -> Bool {
        switch code {
        case .deadlineExceeded, .resourceExhausted, .unavailable, .aborted: true
        default: false
        }
    }

    private static func safeMessage(_ message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(256))
    }
}
