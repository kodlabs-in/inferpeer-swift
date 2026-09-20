import InferPeerCore
import InferPeerInference
import InferPeerProtocol

extension DirectWireMapper {
    /// Converts the current public run status to its durable v2 state.
    public static func wireRunState(_ status: RunStatus) -> InferPeer_V2_RunState {
        switch status {
        case .accepted: .accepted
        case .queued: .queued
        case .loadingModel: .preparing
        case .running: .running
        case .cancelling: .cancelRequested
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        case .expired: .expired
        case .interrupted: .interrupted
        }
    }

    /// Reconstructs a public status from a durable state and its associated wire fields.
    public static func runStatus(
        _ state: InferPeer_V2_RunState,
        model: ModelKey? = nil,
        queuePosition: UInt32? = nil,
        error: InferPeerError? = nil
    ) throws -> RunStatus {
        switch state {
        case .accepted, .queued, .preparing, .running, .cancelRequested:
            try activeRunStatus(state, model: model, queuePosition: queuePosition)
        case .completed, .failed, .cancelled, .expired, .interrupted:
            terminalRunStatus(state, error: error)
        case .unspecified, .UNRECOGNIZED:
            throw DirectWireMappingError.invalidEnum("run state")
        }
    }

    private static func activeRunStatus(
        _ state: InferPeer_V2_RunState,
        model: ModelKey?,
        queuePosition: UInt32?
    ) throws -> RunStatus {
        switch state {
        case .accepted: .accepted
        case .queued: .queued(position: Int(queuePosition ?? 0))
        case .preparing: .loadingModel(try requiredModel(model))
        case .running: .running(try requiredModel(model))
        default: .cancelling
        }
    }

    private static func terminalRunStatus(
        _ state: InferPeer_V2_RunState,
        error: InferPeerError?
    ) -> RunStatus {
        switch state {
        case .completed: .completed
        case .failed: .failed(error ?? InferPeerError(code: .internal, isRetryable: false))
        case .cancelled: .cancelled
        case .expired: .expired
        default: .interrupted(error ?? InferPeerError(code: .interrupted, isRetryable: false))
        }
    }

    private static func requiredModel(_ model: ModelKey?) throws -> ModelKey {
        guard let model else { throw DirectWireMappingError.invalidModel }
        return model
    }
}
