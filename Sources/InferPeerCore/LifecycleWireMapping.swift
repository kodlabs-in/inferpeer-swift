import InferPeerProtocol

/// A protocol enum value that Core cannot safely interpret.
public enum CoreWireMappingError: Error, Equatable, Sendable {
    /// A request lifecycle value was absent or unknown.
    case invalidRequestState

    /// A cancellation lifecycle value was unknown.
    case invalidCancellationState

    /// A participation state was absent or unknown.
    case invalidParticipationState

    /// A thermal state was absent or unknown.
    case invalidThermalState

    /// A worker model status omitted its exact model reference.
    case missingModelReference

    /// A protocol duration could not be represented by Core.
    case invalidDuration
}

extension RequestState {
    /// Creates a request lifecycle state from its protocol representation.
    public init(wireValue: InferPeer_V1_RequestState) throws {
        switch wireValue {
        case .queued: self = .queued
        case .assigned: self = .assigned
        case .running: self = .running
        case .completed: self = .completed
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        case .expired: self = .expired
        case .unspecified, .UNRECOGNIZED:
            throw CoreWireMappingError.invalidRequestState
        }
    }

    /// The protocol representation of this request lifecycle state.
    public var wireValue: InferPeer_V1_RequestState {
        switch self {
        case .queued: .queued
        case .assigned: .assigned
        case .running: .running
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        case .expired: .expired
        }
    }
}

extension CancellationState {
    /// Creates a cancellation state from its protocol representation.
    public init(wireValue: InferPeer_V1_CancellationState) throws {
        switch wireValue {
        case .unspecified: self = .notRequested
        case .pending: self = .pending
        case .confirmed: self = .confirmed
        case .tooLate: self = .tooLate
        case .UNRECOGNIZED:
            throw CoreWireMappingError.invalidCancellationState
        }
    }

    /// The protocol representation of this cancellation state.
    public var wireValue: InferPeer_V1_CancellationState {
        switch self {
        case .notRequested: .unspecified
        case .pending: .pending
        case .confirmed: .confirmed
        case .tooLate: .tooLate
        }
    }
}
