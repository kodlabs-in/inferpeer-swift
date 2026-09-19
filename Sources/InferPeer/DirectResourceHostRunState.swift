import InferPeerCore
import InferPeerInference

extension RunStatus {
    var isHostTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .expired, .interrupted: true
        default: false
        }
    }
}

extension RunEvent {
    var isHostTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .expired, .interrupted: true
        default: false
        }
    }

    func hostStatus(current: RunStatus) -> RunStatus {
        switch self {
        case .accepted: .accepted
        case .queued(let position): .queued(position: position)
        case .loadingModel(let model): .loadingModel(model)
        case .started(let model): .running(model)
        case .completed: .completed
        case .failed(let error): .failed(error)
        case .cancelled: .cancelled
        case .expired: .expired
        case .interrupted(let error): .interrupted(error)
        case .preprocessing, .textDelta, .transcriptSegment, .audioChunk, .usage: current
        }
    }
}
