import Crypto
import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import SwiftProtobuf

extension CallerRequestService {
    func receive(_ response: InferPeer_V1_ClientSessionResponse) async throws {
        if case .commandRejected(let rejection) = response.payload {
            try receiveCommandRejection(rejection, metadata: response.metadata)
            return
        }
        let context = try responseContext(response.metadata)
        if let latest = latestCursors[context.requestID], context.cursor <= latest { return }
        let payload = try eventPayload(response.payload)
        try await outbox.recordReceived(
            requestID: context.requestID,
            callerID: callerID,
            cursor: context.cursor
        )
        try await apply(payload, context: context)
        latestCursors[context.requestID] = context.cursor
        publish(
            InferPeerRequestEvent(
                requestID: context.requestID,
                attemptID: context.attemptID,
                cursor: context.cursor,
                payload: payload
            )
        )
    }

    func receiveCommandRejection(
        _ rejection: InferPeer_V1_CommandRejected,
        metadata: InferPeer_V1_MessageMetadata
    ) throws {
        guard metadata.hasRequestID, let requestID = RequestID(rawValue: metadata.requestID),
            !metadata.hasEventCursor
        else {
            throw InferPeerNodeError.invalidCoordinatorResponse
        }
        let error = InferPeerCommandRejection(
            error: InferPeerError(wireValue: rejection.error),
            attemptID: try optionalAttemptID(metadata),
            retainedTerminalResult: rejection.hasRetainedTerminalResult
                ? try GenerationResult(wireValue: rejection.retainedTerminalResult)
                : nil
        )
        if var lifecycle = lifecycles[requestID], lifecycle.phase == .awaitingAcceptance {
            try lifecycle.markSubmissionRejected()
            lifecycles[requestID] = lifecycle
        }
        commandRejections[requestID] = error
        if let subscription = subscriptions.removeValue(forKey: requestID) {
            subscription.continuation.finish(throwing: error)
        }
    }

    func responseContext(_ metadata: InferPeer_V1_MessageMetadata) throws
        -> ResponseContext
    {
        guard metadata.hasRequestID, let requestID = RequestID(rawValue: metadata.requestID) else {
            throw InferPeerNodeError.invalidCoordinatorResponse
        }
        guard metadata.hasEventCursor else {
            throw InferPeerNodeError.invalidCoordinatorResponse
        }
        let attemptID = try optionalAttemptID(metadata)
        return ResponseContext(
            requestID: requestID,
            attemptID: attemptID,
            cursor: metadata.eventCursor
        )
    }

    func optionalAttemptID(_ metadata: InferPeer_V1_MessageMetadata) throws -> AttemptID? {
        guard metadata.hasAttemptID else { return nil }
        guard let attemptID = AttemptID(rawValue: metadata.attemptID) else {
            throw InferPeerNodeError.invalidCoordinatorResponse
        }
        return attemptID
    }

    func eventPayload(
        _ payload: InferPeer_V1_ClientSessionResponse.OneOf_Payload?
    ) throws -> InferPeerRequestEventPayload {
        switch payload {
        case .requestAccepted(let accepted):
            return .accepted(try RequestState(wireValue: accepted.state))
        case .requestStateChanged(let changed):
            return .stateChanged(
                state: try RequestState(wireValue: changed.state),
                attemptNumber: changed.attemptNumber
            )
        case .generationEvent(let event):
            return try generationPayload(event)
        case .cancellationUpdated(let updated):
            return .cancellation(try CancellationState(wireValue: updated.state))
        case .requestFailed(let failed):
            return .failed(InferPeerError(wireValue: failed.error))
        default:
            throw InferPeerNodeError.invalidCoordinatorResponse
        }
    }

    func generationPayload(
        _ event: InferPeer_V1_GenerationEvent
    ) throws -> InferPeerRequestEventPayload {
        switch event.payload {
        case .textDelta(let delta):
            .generation(.textDelta(try TextDelta(wireValue: delta)))
        case .completed(let completed):
            .generation(.completed(try GenerationResult(wireValue: completed)))
        case .interrupted(let interrupted):
            .interrupted(
                error: InferPeerError(wireValue: interrupted.error),
                willRetry: interrupted.willRetry
            )
        case nil:
            throw InferPeerNodeError.invalidCoordinatorResponse
        }
    }

    func apply(
        _ payload: InferPeerRequestEventPayload,
        context: ResponseContext
    ) async throws {
        switch payload {
        case .accepted(let state):
            try await accept(requestID: context.requestID, state: state)
        case .stateChanged(let state, _):
            try observe(state: state, context: context)
        case .cancellation(let cancellation):
            try apply(cancellation: cancellation, requestID: context.requestID)
        case .failed:
            try observe(state: .failed, context: context)
        case .generation, .interrupted:
            break
        }
    }

    func accept(requestID: RequestID, state: RequestState) async throws {
        guard var lifecycle = lifecycles[requestID] else {
            throw InferPeerNodeError.requestNotTracked
        }
        try lifecycle.accept(coordinatorState: state)
        try await outbox.remove(requestID: requestID, callerID: callerID)
        lifecycles[requestID] = lifecycle
    }

    func observe(state: RequestState, context: ResponseContext) throws {
        guard var lifecycle = lifecycles[context.requestID] else {
            throw InferPeerNodeError.requestNotTracked
        }
        _ = try lifecycle.observe(coordinatorState: state, eventCursor: context.cursor)
        lifecycles[context.requestID] = lifecycle
    }

    func apply(cancellation: CancellationState, requestID: RequestID) throws {
        guard var lifecycle = lifecycles[requestID] else {
            throw InferPeerNodeError.requestNotTracked
        }
        try lifecycle.applyCancellation(cancellation)
        lifecycles[requestID] = lifecycle
    }

    func publish(_ event: InferPeerRequestEvent) {
        guard let subscription = subscriptions[event.requestID] else { return }
        guard case .dropped = subscription.continuation.yield(event) else { return }
        removeSubscription(requestID: event.requestID, subscriptionID: subscription.id)
        subscription.continuation.finish(throwing: InferPeerNodeError.eventStreamOverflow)
    }
}
