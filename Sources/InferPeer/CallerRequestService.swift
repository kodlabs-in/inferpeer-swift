import Crypto
import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import SwiftProtobuf

actor CallerRequestService {
    private struct ResponseContext {
        let requestID: RequestID
        let attemptID: AttemptID?
        let cursor: UInt64
    }

    private let session: any CallerTransportSession
    private let outbox: any InferPeerCallerOutbox
    private let clusterID: ClusterID
    private let callerID: PeerID
    private let bufferingLimit: Int
    private var nextSequence: UInt64 = 2
    private var responseTask: Task<Void, Never>?
    private var lifecycles: [RequestID: CallerRequestLifecycle] = [:]
    private var latestCursors: [RequestID: UInt64] = [:]
    private var acknowledgedCursors: [RequestID: UInt64] = [:]
    private var subscriptions: [RequestID: InferPeerRequestEventStream.Continuation] = [:]

    init(
        session: any CallerTransportSession,
        outbox: any InferPeerCallerOutbox,
        clusterID: ClusterID,
        callerID: PeerID,
        bufferingLimit: Int
    ) {
        self.session = session
        self.outbox = outbox
        self.clusterID = clusterID
        self.callerID = callerID
        self.bufferingLimit = bufferingLimit
    }

    func start() {
        let responses = session.responses(bufferingLimit: bufferingLimit)
        responseTask = Task { [weak self] in
            do {
                for try await response in responses {
                    try await self?.receive(response)
                }
                await self?.failSubscriptions(with: InferPeerNodeError.callerSessionUnavailable)
            } catch {
                await self?.failSubscriptions(with: error)
            }
        }
    }

    func stop() {
        responseTask?.cancel()
        responseTask = nil
        subscriptions.values.forEach { $0.finish() }
        subscriptions.removeAll()
    }

    func submit(
        _ request: TextGenerationRequest,
        requestID suppliedRequestID: RequestID?
    ) async throws -> InferPeerRequestHandle {
        let requestID = try suppliedRequestID ?? Self.makeRequestID()
        var lifecycle = lifecycles[requestID] ?? CallerRequestLifecycle(requestID: requestID)
        guard lifecycle.phase == .pendingOutbox else {
            throw InferPeerNodeError.requestNotTracked
        }
        let submission = try Self.submission(
            requestID: requestID,
            callerID: callerID,
            request: request
        )
        _ = try await outbox.enqueue(submission)
        try lifecycle.markSubmitted()
        lifecycles[requestID] = lifecycle
        do {
            try await sendSubmit(submission)
        } catch {
            lifecycles[requestID] = CallerRequestLifecycle(requestID: requestID)
            throw error
        }
        return InferPeerRequestHandle(requestID: requestID)
    }

    func events(requestID: RequestID, after cursor: UInt64?) async throws
        -> InferPeerRequestEventStream
    {
        guard subscriptions[requestID] == nil else {
            throw InferPeerNodeError.requestAlreadySubscribed
        }
        let pair = InferPeerRequestEventStream.makeStream(
            bufferingPolicy: .bufferingNewest(bufferingLimit)
        )
        subscriptions[requestID] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscription(requestID: requestID) }
        }
        do {
            try await sendResume(requestID: requestID, after: cursor)
            return pair.stream
        } catch {
            subscriptions[requestID] = nil
            pair.continuation.finish(throwing: error)
            throw error
        }
    }

    func acknowledge(requestID: RequestID, through cursor: UInt64) async throws {
        guard let latest = latestCursors[requestID], cursor <= latest else {
            throw InferPeerNodeError.requestNotTracked
        }
        if let acknowledged = acknowledgedCursors[requestID], cursor < acknowledged {
            throw CallerRequestTransitionError.acknowledgedCursorRegressed
        }
        try await sendAcknowledgement(requestID: requestID, through: cursor)
        acknowledgedCursors[requestID] = cursor
    }

    func cancel(requestID: RequestID) async throws -> CancellationState {
        guard var lifecycle = lifecycles[requestID] else {
            throw InferPeerNodeError.requestNotTracked
        }
        let cancellation = lifecycle.requestCancellation()
        lifecycles[requestID] = lifecycle
        if cancellation == .confirmed {
            try await outbox.remove(requestID: requestID, callerID: callerID)
        } else if cancellation == .pending {
            try await sendCancellation(requestID: requestID)
        }
        return cancellation
    }

    func status(requestID: RequestID) throws -> InferPeerCallerRequestStatus {
        guard let lifecycle = lifecycles[requestID] else {
            throw InferPeerNodeError.requestNotTracked
        }
        return InferPeerCallerRequestStatus(
            requestID: requestID,
            phase: lifecycle.phase,
            cancellationState: lifecycle.cancellationState,
            latestEventCursor: latestCursors[requestID],
            acknowledgedEventCursor: acknowledgedCursors[requestID]
        )
    }
}

extension CallerRequestService {
    private func receive(_ response: InferPeer_V1_ClientSessionResponse) async throws {
        let context = try responseContext(response.metadata)
        if let latest = latestCursors[context.requestID], context.cursor <= latest { return }
        let payload = try eventPayload(response.payload)
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

    private func responseContext(_ metadata: InferPeer_V1_MessageMetadata) throws
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

    private func optionalAttemptID(_ metadata: InferPeer_V1_MessageMetadata) throws -> AttemptID? {
        guard metadata.hasAttemptID else { return nil }
        guard let attemptID = AttemptID(rawValue: metadata.attemptID) else {
            throw InferPeerNodeError.invalidCoordinatorResponse
        }
        return attemptID
    }

    private func eventPayload(
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

    private func generationPayload(
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

    private func apply(
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

    private func accept(requestID: RequestID, state: RequestState) async throws {
        guard var lifecycle = lifecycles[requestID] else {
            throw InferPeerNodeError.requestNotTracked
        }
        try lifecycle.accept(coordinatorState: state)
        try await outbox.remove(requestID: requestID, callerID: callerID)
        lifecycles[requestID] = lifecycle
    }

    private func observe(state: RequestState, context: ResponseContext) throws {
        guard var lifecycle = lifecycles[context.requestID] else {
            throw InferPeerNodeError.requestNotTracked
        }
        _ = try lifecycle.observe(coordinatorState: state, eventCursor: context.cursor)
        lifecycles[context.requestID] = lifecycle
    }

    private func apply(cancellation: CancellationState, requestID: RequestID) throws {
        guard var lifecycle = lifecycles[requestID] else {
            throw InferPeerNodeError.requestNotTracked
        }
        try lifecycle.applyCancellation(cancellation)
        lifecycles[requestID] = lifecycle
    }

    private func publish(_ event: InferPeerRequestEvent) {
        guard let continuation = subscriptions[event.requestID] else { return }
        guard case .dropped = continuation.yield(event) else { return }
        subscriptions[event.requestID] = nil
        continuation.finish(throwing: InferPeerNodeError.eventStreamOverflow)
    }
}

extension CallerRequestService {
    private func sendSubmit(_ submission: RequestSubmission) async throws {
        let metadata = try makeMetadata(requestID: submission.requestID)
        let request = InferPeer_V1_ClientSessionRequest.with {
            $0.metadata = metadata
            $0.submit.request = submission.request.wireValue
            $0.submit.immutableInputSha256 = submission.contentDigest.bytes
        }
        try await session.send(request)
    }

    private func sendResume(requestID: RequestID, after cursor: UInt64?) async throws {
        let metadata = try makeMetadata(requestID: requestID)
        let request = InferPeer_V1_ClientSessionRequest.with {
            $0.metadata = metadata
            $0.resume.afterEventCursor = cursor ?? 0
        }
        try await session.send(request)
    }

    private func sendAcknowledgement(requestID: RequestID, through cursor: UInt64) async throws {
        let metadata = try makeMetadata(requestID: requestID)
        let request = InferPeer_V1_ClientSessionRequest.with {
            $0.metadata = metadata
            $0.acknowledgeEvents.throughEventCursor = cursor
        }
        try await session.send(request)
    }

    private func sendCancellation(requestID: RequestID) async throws {
        let metadata = try makeMetadata(requestID: requestID)
        let request = InferPeer_V1_ClientSessionRequest.with {
            $0.metadata = metadata
            $0.cancel = InferPeer_V1_CancelCommand()
        }
        try await session.send(request)
    }

    private func makeMetadata(requestID: RequestID) throws -> InferPeer_V1_MessageMetadata {
        guard nextSequence < .max else { throw InferPeerNodeError.sequenceExhausted }
        let sequence = nextSequence
        nextSequence += 1
        return InferPeer_V1_MessageMetadata.with {
            $0.protocolVersion = InferPeerProtocolVersion.current
            $0.clusterID = clusterID.rawValue
            $0.authenticatedSenderID = callerID.rawValue
            $0.messageID = UUID().uuidString.lowercased()
            $0.requestID = requestID.rawValue
            $0.sequence = sequence
        }
    }

    private func removeSubscription(requestID: RequestID) {
        subscriptions[requestID] = nil
    }

    private func failSubscriptions(with error: any Error) {
        subscriptions.values.forEach { $0.finish(throwing: error) }
        subscriptions.removeAll()
    }

    private static func makeRequestID() throws -> RequestID {
        guard let requestID = RequestID(rawValue: UUID().uuidString.lowercased()) else {
            throw InferPeerNodeError.invalidCoordinatorResponse
        }
        return requestID
    }

    private static func submission(
        requestID: RequestID,
        callerID: PeerID,
        request: TextGenerationRequest
    ) throws -> RequestSubmission {
        var options = BinaryEncodingOptions()
        options.useDeterministicOrdering = true
        let bytes = try request.wireValue.serializedData(options: options)
        let digest = try RequestContentDigest(bytes: Data(SHA256.hash(data: bytes)))
        return RequestSubmission(
            requestID: requestID,
            callerID: callerID,
            request: request,
            contentDigest: digest
        )
    }
}
