import Foundation
import InferPeerInference
import InferPeerProtocol

extension CoordinatorEngine {
    func submit(
        _ command: InferPeer_V1_SubmitCommand,
        requestID: RequestID,
        callerID: PeerID
    ) async throws {
        guard command.hasRequest,
            command.immutableInputSha256.count == RequestContentDigest.byteCount,
            InferPeerProtocolLimits.permits(command.request)
        else {
            throw CoordinatorError.invalidMessage
        }
        if command.request.hasDeadlineUnixMilliseconds,
            Date(
                timeIntervalSince1970: TimeInterval(command.request.deadlineUnixMilliseconds)
                    / 1_000)
                <= wallClock.now()
        {
            throw CoordinatorError.requestDeadlineElapsed
        }
        let submission = RequestSubmission(
            requestID: requestID,
            callerID: callerID,
            request: try TextGenerationRequest(wireValue: command.request),
            contentDigest: try RequestContentDigest(bytes: command.immutableInputSha256)
        )
        let acceptance = try await store.accept(submission)
        let stored =
            switch acceptance {
            case .accepted(let stored), .duplicate(let stored): stored
            }
        requests[requestID] = stored
        requestDeadlines[requestID] = deadline(for: stored)
        try await replay(requestID: requestID, callerID: callerID, after: 0)
        await expireIfNeeded(requestID)
        await schedule(requestID)
    }

    func cancel(requestID: RequestID, callerID: PeerID) async throws {
        guard var stored = try await loadRequest(requestID, callerID: callerID) else {
            throw RequestPersistenceError.requestNotFound
        }
        let previousAttempt = stored.lifecycle.activeAttempt
        var lifecycle = stored.lifecycle
        let cancellation = lifecycle.requestCancellation()
        guard lifecycle != stored.lifecycle else {
            try await sendNewEvents(for: requestID)
            return
        }
        stored = try await store.commit(
            RequestMutation(
                requestID: requestID,
                callerID: callerID,
                expectedRevision: stored.revision,
                lifecycle: lifecycle,
                events: [PendingRequestEvent(payload: .cancellation(cancellation))]
            )
        )
        requests[requestID] = stored
        try await sendNewEvents(for: requestID)
        if cancellation == .pending, let previousAttempt {
            await cancel(attempt: previousAttempt, requestID: requestID)
        } else if lifecycle.state.isTerminal {
            await releaseTerminal(stored)
        }
    }

    func replay(
        requestID: RequestID,
        callerID: PeerID,
        after cursor: UInt64
    ) async throws {
        guard let connection = callers[callerID] else { return }
        var nextCursor: UInt64? = cursor
        while true {
            let events = try await store.replay(
                requestID: requestID,
                callerID: callerID,
                after: nextCursor,
                limit: configuration.replayPageLimit
            )
            try await connection.send(events)
            guard events.count == configuration.replayPageLimit,
                let lastCursor = events.last?.cursor
            else {
                return
            }
            nextCursor = lastCursor
        }
    }

    func sendNewEvents(for requestID: RequestID) async throws {
        guard let stored = requests[requestID],
            let connection = callers[stored.submission.callerID]
        else {
            return
        }
        let cursor = await connection.lastCursor(for: requestID) ?? 0
        try await replay(
            requestID: requestID,
            callerID: stored.submission.callerID,
            after: cursor
        )
    }

    func loadRequest(
        _ requestID: RequestID,
        callerID: PeerID
    ) async throws -> StoredRequest? {
        if let stored = requests[requestID] {
            guard stored.submission.callerID == callerID else {
                throw RequestPersistenceError.accessDenied
            }
            return stored
        }
        let stored = try await store.request(requestID: requestID, callerID: callerID)
        if let stored { requests[requestID] = stored }
        return stored
    }

    func deadline(for stored: StoredRequest) -> MonotonicInstant {
        let wallDeadline =
            stored.submission.request.options.deadline
            ?? stored.acceptedAt.addingTimeInterval(configuration.requestTimeout.timeInterval)
        let remaining = max(0, wallDeadline.timeIntervalSince(wallClock.now()))
        return clock.now().advanced(by: .seconds(remaining))
    }

    func expireIfNeeded(_ requestID: RequestID) async {
        guard let deadline = requestDeadlines[requestID], clock.now() >= deadline,
            var stored = requests[requestID], !stored.lifecycle.state.isTerminal
        else {
            return
        }
        let attempt = stored.lifecycle.activeAttempt
        var lifecycle = stored.lifecycle
        guard lifecycle.expire() == .committed else { return }
        let error = InferPeerError(code: .deadlineExceeded, isRetryable: false)
        do {
            stored = try await store.commit(
                RequestMutation(
                    requestID: requestID,
                    callerID: stored.submission.callerID,
                    expectedRevision: stored.revision,
                    lifecycle: lifecycle,
                    events: [
                        PendingRequestEvent(
                            attemptID: attempt?.attemptID,
                            payload: .stateChanged(
                                state: .expired,
                                attemptNumber: lifecycle.attemptNumber
                            )
                        ),
                        PendingRequestEvent(attemptID: attempt?.attemptID, payload: .failed(error)),
                    ]
                )
            )
            requests[requestID] = stored
            if let attempt { await cancel(attempt: attempt, requestID: requestID) }
            try await sendNewEvents(for: requestID)
            await releaseTerminal(stored)
        } catch {
            // The next maintenance pass retries from durable state.
        }
    }

    func releaseTerminal(_ stored: StoredRequest) async {
        let requestID = stored.submission.requestID
        requestDeadlines[requestID] = nil
        if let attempt = stored.lifecycle.activeAttempt {
            attemptRequests[attempt.attemptID] = nil
        }
        let key = ConversationKey(
            callerID: stored.submission.callerID,
            conversationID: stored.submission.request.context.conversationID
        )
        if activeConversations[key] == requestID {
            activeConversations[key] = nil
        }
        requests[requestID] = nil
        await scheduleQueuedRequests()
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
