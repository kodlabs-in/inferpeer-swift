import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import SwiftProtobuf

enum StoredEventKind: Int, Sendable {
    case accepted = 1
    case stateChanged = 2
    case generation = 3
    case interrupted = 4
    case cancellation = 5
    case failed = 6
}

struct EncodedRequestEvent: Sendable {
    let kind: StoredEventKind
    let data: Data
}

enum RequestEventCodec {
    static func encode(_ payload: RequestEventPayload) throws -> EncodedRequestEvent {
        switch payload {
        case .accepted(let state):
            try encodeAccepted(state)
        case .stateChanged(let state, let attemptNumber):
            try encodeStateChanged(state: state, attemptNumber: attemptNumber)
        case .generation(let event):
            try encodeGeneration(event)
        case .interrupted(let error, let willRetry):
            try encodeInterrupted(error: error, willRetry: willRetry)
        case .cancellation(let state):
            try encodeCancellation(state)
        case .failed(let error):
            try encodeFailure(error)
        }
    }

    static func decode(kind rawKind: Int, data: Data) throws -> RequestEventPayload {
        guard let kind = StoredEventKind(rawValue: rawKind) else {
            throw SQLiteStorageError.corruptData
        }
        do {
            return try decode(kind: kind, data: data)
        } catch let error as SQLiteStorageError {
            throw error
        } catch {
            throw SQLiteStorageError.corruptData
        }
    }

    private static func decode(
        kind: StoredEventKind,
        data: Data
    ) throws -> RequestEventPayload {
        switch kind {
        case .accepted:
            let value = try InferPeer_V1_RequestAccepted(serializedBytes: data)
            return .accepted(try RequestState(wireValue: value.state))
        case .stateChanged:
            let value = try InferPeer_V1_RequestStateChanged(serializedBytes: data)
            return .stateChanged(
                state: try RequestState(wireValue: value.state),
                attemptNumber: value.attemptNumber
            )
        case .generation:
            let value = try InferPeer_V1_GenerationEvent(serializedBytes: data)
            return .generation(try decodeGeneration(value))
        case .interrupted:
            let value = try InferPeer_V1_GenerationInterrupted(serializedBytes: data)
            guard value.hasError else { throw SQLiteStorageError.corruptData }
            return .interrupted(
                error: InferPeerError(wireValue: value.error),
                willRetry: value.willRetry
            )
        case .cancellation:
            let value = try InferPeer_V1_CancellationUpdated(serializedBytes: data)
            return .cancellation(try CancellationState(wireValue: value.state))
        case .failed:
            let value = try InferPeer_V1_RequestFailed(serializedBytes: data)
            guard value.hasError else { throw SQLiteStorageError.corruptData }
            return .failed(InferPeerError(wireValue: value.error))
        }
    }

    private static func encodeAccepted(
        _ state: RequestState
    ) throws -> EncodedRequestEvent {
        let value = InferPeer_V1_RequestAccepted.with {
            $0.state = state.wireValue
        }
        return EncodedRequestEvent(kind: .accepted, data: try value.serializedData())
    }

    private static func encodeStateChanged(
        state: RequestState,
        attemptNumber: UInt32
    ) throws -> EncodedRequestEvent {
        let value = InferPeer_V1_RequestStateChanged.with {
            $0.state = state.wireValue
            $0.attemptNumber = attemptNumber
        }
        return EncodedRequestEvent(kind: .stateChanged, data: try value.serializedData())
    }

    private static func encodeGeneration(
        _ event: GenerationEvent
    ) throws -> EncodedRequestEvent {
        let value = InferPeer_V1_GenerationEvent.with {
            switch event {
            case .textDelta(let delta):
                $0.textDelta = delta.wireValue
            case .completed(let result):
                $0.completed = result.wireValue
            }
        }
        return EncodedRequestEvent(kind: .generation, data: try value.serializedData())
    }

    private static func encodeInterrupted(
        error: InferPeerError,
        willRetry: Bool
    ) throws -> EncodedRequestEvent {
        let value = InferPeer_V1_GenerationInterrupted.with {
            $0.error = error.wireValue
            $0.willRetry = willRetry
        }
        return EncodedRequestEvent(kind: .interrupted, data: try value.serializedData())
    }

    private static func encodeCancellation(
        _ state: CancellationState
    ) throws -> EncodedRequestEvent {
        let value = InferPeer_V1_CancellationUpdated.with {
            $0.state = state.wireValue
        }
        return EncodedRequestEvent(kind: .cancellation, data: try value.serializedData())
    }

    private static func encodeFailure(
        _ error: InferPeerError
    ) throws -> EncodedRequestEvent {
        let value = InferPeer_V1_RequestFailed.with {
            $0.error = error.wireValue
        }
        return EncodedRequestEvent(kind: .failed, data: try value.serializedData())
    }

    private static func decodeGeneration(
        _ value: InferPeer_V1_GenerationEvent
    ) throws -> GenerationEvent {
        switch value.payload {
        case .textDelta(let delta):
            .textDelta(try TextDelta(wireValue: delta))
        case .completed(let result):
            .completed(try GenerationResult(wireValue: result))
        case .interrupted:
            throw SQLiteStorageError.corruptData
        case nil:
            throw SQLiteStorageError.corruptData
        }
    }
}
