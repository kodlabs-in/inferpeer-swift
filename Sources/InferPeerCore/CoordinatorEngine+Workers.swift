import Foundation
import InferPeerInference
import InferPeerProtocol

extension CoordinatorEngine {
    func installLocalWorker() async {
        guard let localWorker else { return }
        workers[localWorker.peerID] = WorkerRecord(
            connection: nil,
            status: await localWorker.status(),
            lastHeartbeat: clock.now(),
            activeAttemptID: nil
        )
    }

    func updateWorker(peerID: PeerID, status: LocalWorkerStatus) async throws {
        guard var worker = workers[peerID] else { return }
        worker.status = status
        worker.lastHeartbeat = clock.now()
        workers[peerID] = worker
        await scheduleQueuedRequests()
    }

    func scheduleQueuedRequests() async {
        let queued = requests.values
            .filter { $0.lifecycle.state == .queued }
            .sorted(by: queuedRequestOrder)
        for stored in queued {
            await schedule(stored.submission.requestID)
        }
    }

    func schedule(_ requestID: RequestID) async {
        guard isRunning else { return }
        guard schedulingRequests.insert(requestID).inserted else {
            rescheduleRequests.insert(requestID)
            return
        }
        defer {
            schedulingRequests.remove(requestID)
            if rescheduleRequests.remove(requestID) != nil {
                Task { [weak self] in await self?.schedule(requestID) }
            }
        }
        await expireIfNeeded(requestID)
        guard let stored = requests[requestID], stored.lifecycle.state == .queued else { return }
        let conversation = conversationKey(for: stored)
        guard !hasEarlierQueuedRevision(than: stored, in: conversation) else { return }
        guard
            activeConversations[conversation] == nil
                || activeConversations[conversation] == requestID
        else {
            return
        }
        let candidates = schedulingCandidates(for: stored.submission.request)
        guard
            let selected = scheduler.selectWorker(
                for: stored.submission.request,
                from: candidates,
                at: clock.now()
            )
        else {
            return
        }
        await assign(stored, to: selected)
    }

    private func assign(_ storedRequest: StoredRequest, to selected: ScheduledWorker) async {
        var stored = storedRequest
        let requestID = stored.submission.requestID
        guard let attemptID = AttemptID(rawValue: UUID().uuidString.lowercased()) else { return }
        var lifecycle = stored.lifecycle
        do {
            let attempt = try lifecycle.assign(
                attemptID: attemptID,
                workerID: selected.peerID,
                coordinatorIncarnationID: configuration.incarnationID,
                leaseDeadline: clock.now().advanced(by: configuration.attemptLease)
            )
            stored = try await store.commit(
                RequestMutation(
                    requestID: requestID,
                    callerID: stored.submission.callerID,
                    expectedRevision: stored.revision,
                    lifecycle: lifecycle,
                    events: [
                        PendingRequestEvent(
                            attemptID: attemptID,
                            payload: .stateChanged(
                                state: .assigned,
                                attemptNumber: lifecycle.attemptNumber
                            )
                        )
                    ]
                )
            )
            register(attempt: attempt, model: selected.model, request: stored)
            try await sendNewEvents(for: requestID)
            await dispatch(stored, attempt: attempt, model: selected.model)
        } catch {
            if attemptRequests[attemptID] != nil {
                await interrupt(
                    attemptID: attemptID,
                    error: InferPeerError(code: .workerUnavailable, isRetryable: true)
                )
            }
        }
    }

    private func hasEarlierQueuedRevision(
        than stored: StoredRequest,
        in conversation: ConversationKey
    ) -> Bool {
        requests.values.contains { candidate in
            candidate.lifecycle.state == .queued
                && candidate.submission.requestID != stored.submission.requestID
                && conversationKey(for: candidate) == conversation
                && candidate.submission.request.context.revision
                    < stored.submission.request.context.revision
        }
    }

    private func queuedRequestOrder(_ lhs: StoredRequest, _ rhs: StoredRequest) -> Bool {
        let lhsKey = conversationKey(for: lhs)
        let rhsKey = conversationKey(for: rhs)
        if lhsKey == rhsKey,
            lhs.submission.request.context.revision != rhs.submission.request.context.revision
        {
            return lhs.submission.request.context.revision
                < rhs.submission.request.context.revision
        }
        if lhs.acceptedAt != rhs.acceptedAt { return lhs.acceptedAt < rhs.acceptedAt }
        return lhs.submission.requestID.rawValue < rhs.submission.requestID.rawValue
    }

    func acceptAttempt(_ context: AttemptContext) async throws {
        guard var stored = requests[context.requestID] else {
            throw CoordinatorError.staleAttempt
        }
        var lifecycle = stored.lifecycle
        try lifecycle.accept(attemptID: context.attemptID)
        stored = try await store.commit(
            RequestMutation(
                requestID: context.requestID,
                callerID: stored.submission.callerID,
                expectedRevision: stored.revision,
                lifecycle: lifecycle,
                events: [
                    PendingRequestEvent(
                        attemptID: context.attemptID,
                        payload: .stateChanged(
                            state: .running,
                            attemptNumber: lifecycle.attemptNumber
                        )
                    )
                ]
            )
        )
        requests[context.requestID] = stored
        try await sendNewEvents(for: context.requestID)
    }

    func renewLease(_ context: AttemptContext) async throws {
        guard var stored = requests[context.requestID] else {
            throw CoordinatorError.staleAttempt
        }
        let deadline = clock.now().advanced(by: configuration.attemptLease)
        var lifecycle = stored.lifecycle
        try lifecycle.renewLease(
            attemptID: context.attemptID,
            coordinatorIncarnationID: configuration.incarnationID,
            until: deadline
        )
        stored = try await store.commit(
            RequestMutation(
                requestID: context.requestID,
                callerID: stored.submission.callerID,
                expectedRevision: stored.revision,
                lifecycle: lifecycle,
                events: []
            )
        )
        requests[context.requestID] = stored
        try await workers[context.workerID]?.connection?.extendLease(
            requestID: context.requestID,
            attemptID: context.attemptID
        )
    }

    func receiveGeneration(
        _ event: InferPeer_V1_GenerationEvent,
        context: AttemptContext
    ) async throws {
        switch event.payload {
        case .textDelta(let delta):
            try await persistGeneration(
                .textDelta(try TextDelta(wireValue: delta)),
                context: context
            )
        case .completed(let completed):
            try await complete(
                try GenerationResult(wireValue: completed),
                context: context
            )
        case .interrupted(let interrupted):
            await interrupt(
                attemptID: context.attemptID,
                error: InferPeerError(wireValue: interrupted.error)
            )
        case nil:
            throw CoordinatorError.invalidMessage
        }
    }

    func persistGeneration(
        _ event: GenerationEvent,
        context: AttemptContext
    ) async throws {
        guard InferPeerProtocolLimits.permits(event.wireValue) else {
            throw InferenceBackendError.resourceExhausted
        }
        guard var stored = requests[context.requestID], stored.lifecycle.state == .running else {
            throw CoordinatorError.staleAttempt
        }
        stored = try await store.commit(
            RequestMutation(
                requestID: context.requestID,
                callerID: stored.submission.callerID,
                expectedRevision: stored.revision,
                lifecycle: stored.lifecycle,
                events: [
                    PendingRequestEvent(
                        attemptID: context.attemptID,
                        payload: .generation(event)
                    )
                ]
            )
        )
        requests[context.requestID] = stored
        try await sendNewEvents(for: context.requestID)
    }

    func complete(_ result: GenerationResult, context: AttemptContext) async throws {
        guard attemptModels[context.attemptID] == result.modelUsed,
            var stored = requests[context.requestID]
        else {
            throw CoordinatorError.staleAttempt
        }
        var lifecycle = stored.lifecycle
        guard try lifecycle.complete(attemptID: context.attemptID) == .committed else { return }
        stored = try await store.commit(
            RequestMutation(
                requestID: context.requestID,
                callerID: stored.submission.callerID,
                expectedRevision: stored.revision,
                lifecycle: lifecycle,
                events: [
                    PendingRequestEvent(
                        attemptID: context.attemptID,
                        payload: .generation(.completed(result))
                    ),
                    PendingRequestEvent(
                        attemptID: context.attemptID,
                        payload: .stateChanged(
                            state: .completed,
                            attemptNumber: lifecycle.attemptNumber
                        )
                    ),
                ]
            )
        )
        requests[context.requestID] = stored
        releaseAttempt(context.attemptID, workerID: context.workerID)
        try await sendNewEvents(for: context.requestID)
        await releaseTerminal(stored)
    }

    func interrupt(attemptID: AttemptID, error: InferPeerError) async {
        guard let requestID = attemptRequests[attemptID], var stored = requests[requestID] else {
            return
        }
        let workerID = stored.lifecycle.activeAttempt?.workerID
        let willRetry =
            error.isRetryable
            && stored.lifecycle.attemptNumber < configuration.maximumAttempts
        var lifecycle = stored.lifecycle
        do {
            try lifecycle.interrupt(attemptID: attemptID, willRetry: willRetry)
            let events = interruptionEvents(
                error: error,
                willRetry: lifecycle.state == .queued,
                lifecycle: lifecycle,
                attemptID: attemptID
            )
            stored = try await store.commit(
                RequestMutation(
                    requestID: requestID,
                    callerID: stored.submission.callerID,
                    expectedRevision: stored.revision,
                    lifecycle: lifecycle,
                    events: events
                )
            )
            requests[requestID] = stored
            if localWorker?.peerID == workerID {
                await localWorker?.cancel(attemptID: attemptID)
            }
            if let workerID { releaseAttempt(attemptID, workerID: workerID) }
            try await sendNewEvents(for: requestID)
            if lifecycle.state == .queued {
                await schedule(requestID)
            } else {
                await releaseTerminal(stored)
            }
        } catch {
            // Stale competing terminal commits are intentionally ignored.
        }
    }
}
