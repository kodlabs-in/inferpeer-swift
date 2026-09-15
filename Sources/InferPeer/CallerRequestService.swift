import Crypto
import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage
import SwiftProtobuf

actor CallerRequestService {
    struct ResponseContext {
        let requestID: RequestID
        let attemptID: AttemptID?
        let cursor: UInt64
    }

    struct Subscription {
        let id: UUID
        let continuation: InferPeerRequestEventStream.Continuation
    }

    let session: any CallerTransportSession
    let outbox: any InferPeerCallerOutbox
    let clusterID: ClusterID
    let callerID: PeerID
    let bufferingLimit: Int
    let recoveryLimit: Int
    var nextSequence: UInt64 = 2
    var responseTask: Task<Void, Never>?
    var sendTail: Task<Void, any Error>?
    var lifecycles: [RequestID: CallerRequestLifecycle] = [:]
    var latestCursors: [RequestID: UInt64] = [:]
    var acknowledgedCursors: [RequestID: UInt64] = [:]
    var commandRejections: [RequestID: InferPeerCommandRejection] = [:]
    var subscriptions: [RequestID: Subscription] = [:]

    init(
        session: any CallerTransportSession,
        outbox: any InferPeerCallerOutbox,
        clusterID: ClusterID,
        callerID: PeerID,
        bufferingLimit: Int,
        recoveryLimit: Int
    ) {
        self.session = session
        self.outbox = outbox
        self.clusterID = clusterID
        self.callerID = callerID
        self.bufferingLimit = bufferingLimit
        self.recoveryLimit = recoveryLimit
    }

    func start() async throws {
        startResponseHandling()
        do {
            try await restorePendingRequests()
        } catch {
            stop()
            throw error
        }
    }

    func startResponseHandling() {
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

    func restorePendingRequests() async throws {
        let pending = try await outbox.pending(callerID: callerID, limit: recoveryLimit)
        for stored in pending {
            var lifecycle = CallerRequestLifecycle(requestID: stored.submission.requestID)
            try lifecycle.markSubmitted()
            lifecycles[stored.submission.requestID] = lifecycle
            try await sendSubmit(stored.submission)
        }
    }

    func stop() {
        responseTask?.cancel()
        responseTask = nil
        sendTail?.cancel()
        sendTail = nil
        subscriptions.values.forEach { $0.continuation.finish() }
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
        if let error = commandRejections.removeValue(forKey: requestID) {
            throw error
        }
        guard subscriptions[requestID] == nil else {
            throw InferPeerNodeError.requestAlreadySubscribed
        }
        try prepareLifecycleForReplay(requestID)
        let replayState = try await outbox.replayState(
            requestID: requestID,
            callerID: callerID
        )
        restoreReplayState(replayState, requestID: requestID)
        let pair = InferPeerRequestEventStream.makeStream(
            bufferingPolicy: .bufferingNewest(bufferingLimit)
        )
        let subscriptionID = UUID()
        subscriptions[requestID] = Subscription(
            id: subscriptionID,
            continuation: pair.continuation
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSubscription(
                    requestID: requestID,
                    subscriptionID: subscriptionID
                )
            }
        }
        do {
            try await sendResume(
                requestID: requestID,
                after: cursor ?? replayState?.acknowledgedCursor
            )
            return pair.stream
        } catch {
            removeSubscription(requestID: requestID, subscriptionID: subscriptionID)
            pair.continuation.finish(throwing: error)
            throw error
        }
    }

    private func restoreReplayState(_ state: CallerReplayState?, requestID: RequestID) {
        guard let acknowledged = state?.acknowledgedCursor else { return }
        latestCursors[requestID] = acknowledged
        acknowledgedCursors[requestID] = acknowledged
    }

    func acknowledge(requestID: RequestID, through cursor: UInt64) async throws {
        guard let latest = latestCursors[requestID], cursor <= latest else {
            throw InferPeerNodeError.requestNotTracked
        }
        if let acknowledged = acknowledgedCursors[requestID], cursor < acknowledged {
            throw CallerRequestTransitionError.acknowledgedCursorRegressed
        }
        try await sendAcknowledgement(requestID: requestID, through: cursor)
        try await outbox.recordAcknowledged(
            requestID: requestID,
            callerID: callerID,
            cursor: cursor
        )
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
