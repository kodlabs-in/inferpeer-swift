import GRPCCore
import InferPeerCore

/// A transport failure which does not expose gRPC or HTTP implementation details to callers.
public enum InferPeerGRPCError: Error, Equatable, Sendable {
    case invalidConfiguration
    case endpointNotAllowed
    case roleDisabled
    case coordinatorPinMissing
    case unauthenticated
    case permissionDenied
    case protocolMismatch
    case invalidMessage
    case sequenceViolation
    case invalidBufferLimit
    case bufferExhausted
    case streamAlreadyConsumed
    case sessionClosed
    case unavailable
    case deadlineExceeded
    case cancelled
    case handshakeRejected(InferPeerError)
    case internalFailure
}

enum GRPCErrorMapper {
    static func publicError(from error: any Error) -> InferPeerGRPCError {
        if let error = error as? InferPeerGRPCError {
            return error
        }
        guard let error = error as? RPCError else {
            return .internalFailure
        }
        return mappedRPCCode(error.code)
    }

    static func rpcError(from error: any Error) -> RPCError {
        let publicError = publicError(from: error)
        return RPCError(code: rpcCode(for: publicError), message: message(for: publicError))
    }

    private static func mappedRPCCode(_ code: RPCError.Code) -> InferPeerGRPCError {
        switch code {
        case .unauthenticated: .unauthenticated
        case .permissionDenied: .permissionDenied
        case .invalidArgument, .failedPrecondition: .invalidMessage
        case .resourceExhausted: .bufferExhausted
        case .deadlineExceeded: .deadlineExceeded
        case .cancelled: .cancelled
        case .unavailable: .unavailable
        default: .internalFailure
        }
    }

    private static func rpcCode(for error: InferPeerGRPCError) -> RPCError.Code {
        switch error {
        case .unauthenticated: .unauthenticated
        case .permissionDenied: .permissionDenied
        case .bufferExhausted: .resourceExhausted
        case .deadlineExceeded: .deadlineExceeded
        case .cancelled: .cancelled
        case .unavailable: .unavailable
        case .protocolMismatch: .failedPrecondition
        case .handshakeRejected(let error): rpcCode(for: error.code)
        default: .invalidArgument
        }
    }

    private static func rpcCode(for errorCode: InferPeerErrorCode) -> RPCError.Code {
        switch errorCode {
        case .unauthenticated: .unauthenticated
        case .permissionDenied: .permissionDenied
        case .resourceExhausted: .resourceExhausted
        case .deadlineExceeded: .deadlineExceeded
        case .cancelled: .cancelled
        case .protocolMismatch: .failedPrecondition
        default: .invalidArgument
        }
    }

    private static func message(for error: InferPeerGRPCError) -> String {
        switch error {
        case .handshakeRejected(let rejection): rejection.message
        default: String(describing: error)
        }
    }
}
