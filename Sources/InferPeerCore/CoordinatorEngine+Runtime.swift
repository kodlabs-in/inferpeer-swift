import Foundation
import InferPeerInference
import InferPeerProtocol

extension CoordinatorEngine {
    func recoverRequests() async throws {
        let recovered = try await store.nonterminalRequests(limit: configuration.recoveryLimit)
        for var stored in recovered {
            requestDeadlines[stored.submission.requestID] = deadline(for: stored)
            if let attempt = stored.lifecycle.activeAttempt {
                stored = try await reconcile(stored, interruptedAttempt: attempt)
            }
            requests[stored.submission.requestID] = stored
        }
    }

    func reconcile(
        _ stored: StoredRequest,
        interruptedAttempt: ActiveAttempt
    ) async throws -> StoredRequest {
        var lifecycle = stored.lifecycle
        let willRetry = lifecycle.attemptNumber < configuration.maximumAttempts
        try lifecycle.interrupt(attemptID: interruptedAttempt.attemptID, willRetry: willRetry)
        let error = InferPeerError(code: .workerUnavailable, isRetryable: true)
        return try await store.commit(
            RequestMutation(
                requestID: stored.submission.requestID,
                callerID: stored.submission.callerID,
                expectedRevision: stored.revision,
                lifecycle: lifecycle,
                events: interruptionEvents(
                    error: error,
                    willRetry: lifecycle.state == .queued,
                    lifecycle: lifecycle,
                    attemptID: interruptedAttempt.attemptID
                )
            )
        )
    }

    func schedulingCandidates(
        for request: TextGenerationRequest
    ) -> [SchedulingCandidate] {
        workers.flatMap { peerID, worker -> [SchedulingCandidate] in
            guard worker.activeAttemptID == nil else { return [] }
            let snapshot = WorkerSnapshot(
                peerID: peerID,
                isAuthorized: true,
                lastHeartbeat: worker.lastHeartbeat,
                condition: worker.status.condition,
                load: worker.status.load
            )
            return worker.status.models.compactMap { model in
                guard model.isLoaded else { return nil }
                guard
                    let estimate = try? InferenceResourceEstimate(
                        peakMemoryBytes: model.measuredMemoryBytes,
                        modelLoadDuration: model.estimatedLoadDuration
                    )
                else {
                    return nil
                }
                return SchedulingCandidate(
                    worker: snapshot,
                    model: model.model,
                    isModelLoaded: model.isLoaded,
                    estimate: estimate,
                    timings: SchedulingTimings(queueDelay: .zero, inputTransferDuration: nil)
                )
            }
        }
    }

    func register(
        attempt: ActiveAttempt,
        model: ModelReference,
        request: StoredRequest
    ) {
        requests[request.submission.requestID] = request
        attemptRequests[attempt.attemptID] = request.submission.requestID
        attemptModels[attempt.attemptID] = model
        workers[attempt.workerID]?.activeAttemptID = attempt.attemptID
        activeConversations[conversationKey(for: request)] = request.submission.requestID
    }

    func dispatch(
        _ stored: StoredRequest,
        attempt: ActiveAttempt,
        model: ModelReference
    ) async {
        if localWorker?.peerID == attempt.workerID {
            startLocalExecution(stored, attempt: attempt, model: model)
            return
        }
        guard let connection = workers[attempt.workerID]?.connection else {
            await interrupt(
                attemptID: attempt.attemptID,
                error: InferPeerError(code: .workerUnavailable, isRetryable: true)
            )
            return
        }
        do {
            try await connection.assign(stored, attempt: attempt, model: model)
        } catch {
            await interrupt(
                attemptID: attempt.attemptID,
                error: InferPeerError(code: .workerUnavailable, isRetryable: true)
            )
        }
    }

    func startLocalExecution(
        _ stored: StoredRequest,
        attempt: ActiveAttempt,
        model: ModelReference
    ) {
        guard localWorker != nil else { return }
        let assignment = makeLocalAssignment(stored, attempt: attempt, model: model)
        localExecutionTasks[attempt.attemptID] = Task { [weak self] in
            await self?.runLocalExecution(stored, attempt: attempt, assignment: assignment)
        }
    }

    private func makeLocalAssignment(
        _ stored: StoredRequest,
        attempt: ActiveAttempt,
        model: ModelReference
    ) -> WorkerExecutionAssignment {
        WorkerExecutionAssignment(
            execution: InferenceExecution(
                requestID: stored.submission.requestID,
                attemptID: attempt.attemptID,
                model: model,
                request: stored.submission.request
            ),
            coordinatorIncarnationID: configuration.incarnationID,
            leaseDeadline: attempt.leaseDeadline
        )
    }

    private func runLocalExecution(
        _ stored: StoredRequest,
        attempt: ActiveAttempt,
        assignment: WorkerExecutionAssignment
    ) async {
        do {
            guard let localWorker else { return }
            let stream = try await localWorker.start(assignment)
            try await acceptAttempt(
                AttemptContext(
                    requestID: stored.submission.requestID,
                    attemptID: attempt.attemptID,
                    workerID: attempt.workerID
                )
            )
            var completed = false
            for try await event in stream {
                if case .completed = event { completed = true }
                try await receiveLocalGeneration(
                    event,
                    requestID: stored.submission.requestID,
                    attemptID: attempt.attemptID,
                    workerID: attempt.workerID
                )
            }
            if !completed {
                await interrupt(
                    attemptID: attempt.attemptID,
                    error: InferPeerError(code: .internal, isRetryable: true)
                )
            }
        } catch {
            await interrupt(
                attemptID: attempt.attemptID,
                error: Self.publicInferenceError(error)
            )
        }
    }

    func receiveLocalGeneration(
        _ event: GenerationEvent,
        requestID: RequestID,
        attemptID: AttemptID,
        workerID: PeerID
    ) async throws {
        let context = AttemptContext(
            requestID: requestID,
            attemptID: attemptID,
            workerID: workerID
        )
        switch event {
        case .textDelta:
            try await persistGeneration(event, context: context)
        case .completed(let result):
            try await localWorker?.complete(attemptID: attemptID)
            try await complete(result, context: context)
        }
    }

    func cancel(attempt: ActiveAttempt, requestID: RequestID) async {
        if localWorker?.peerID == attempt.workerID {
            await localWorker?.cancel(attemptID: attempt.attemptID)
            return
        }
        try? await workers[attempt.workerID]?.connection?.cancel(
            requestID: requestID,
            attemptID: attempt.attemptID
        )
    }

    func releaseAttempt(_ attemptID: AttemptID, workerID: PeerID) {
        attemptRequests[attemptID] = nil
        attemptModels[attemptID] = nil
        localExecutionTasks[attemptID] = nil
        if workers[workerID]?.activeAttemptID == attemptID {
            workers[workerID]?.activeAttemptID = nil
        }
    }

    func interruptionEvents(
        error: InferPeerError,
        willRetry: Bool,
        lifecycle: RequestLifecycle,
        attemptID: AttemptID
    ) -> [PendingRequestEvent] {
        var events = [
            PendingRequestEvent(
                attemptID: attemptID,
                payload: .interrupted(error: error, willRetry: willRetry)
            )
        ]
        if lifecycle.state == .cancelled {
            events.append(PendingRequestEvent(payload: .cancellation(.confirmed)))
        } else if lifecycle.state == .failed {
            events.append(PendingRequestEvent(attemptID: attemptID, payload: .failed(error)))
        }
        return events
    }

    func conversationKey(for stored: StoredRequest) -> ConversationKey {
        ConversationKey(
            callerID: stored.submission.callerID,
            conversationID: stored.submission.request.context.conversationID
        )
    }

    func performMaintenance() async {
        guard isRunning else { return }
        await sweepRetentionIfNeeded()
        await refreshLocalWorker()
        await removeStaleWorkers()
        await expireLeases()
        for requestID in Array(requests.keys) {
            await expireIfNeeded(requestID)
        }
        await renewLocalLeaseIfNeeded()
        await scheduleQueuedRequests()
    }

    func pruneTerminalRequests() async throws {
        let cutoff = wallClock.now().addingTimeInterval(
            -configuration.terminalRetentionTimeInterval
        )
        try await store.pruneTerminalRequests(before: cutoff)
        lastRetentionSweep = clock.now()
    }

    func sweepRetentionIfNeeded() async {
        guard let lastRetentionSweep else {
            try? await pruneTerminalRequests()
            return
        }
        guard
            clock.now().elapsed(since: lastRetentionSweep)
                >= configuration.retentionSweepInterval
        else {
            return
        }
        try? await pruneTerminalRequests()
    }

    func refreshLocalWorker() async {
        guard let localWorker, var record = workers[localWorker.peerID] else { return }
        record.status = await localWorker.status()
        record.lastHeartbeat = clock.now()
        workers[localWorker.peerID] = record
    }

    func removeStaleWorkers() async {
        let now = clock.now()
        let stale = workers.compactMap { peerID, worker -> PeerID? in
            guard worker.connection != nil,
                now.elapsed(since: worker.lastHeartbeat) > configuration.heartbeatTimeout
            else {
                return nil
            }
            return peerID
        }
        for peerID in stale {
            guard let worker = workers.removeValue(forKey: peerID) else { continue }
            await worker.connection?.close()
            if let attemptID = worker.activeAttemptID {
                await interrupt(
                    attemptID: attemptID,
                    error: InferPeerError(code: .workerUnavailable, isRetryable: true)
                )
            }
        }
    }

    func expireLeases() async {
        let now = clock.now()
        let expired = requests.values.compactMap { stored -> AttemptID? in
            guard let attempt = stored.lifecycle.activeAttempt,
                attempt.leaseDeadline <= now,
                localWorker?.peerID != attempt.workerID
            else {
                return nil
            }
            return attempt.attemptID
        }
        for attemptID in expired {
            await interrupt(
                attemptID: attemptID,
                error: InferPeerError(code: .workerUnavailable, isRetryable: true)
            )
        }
    }

    func renewLocalLeaseIfNeeded() async {
        guard let localWorker,
            let attemptID = workers[localWorker.peerID]?.activeAttemptID,
            let requestID = attemptRequests[attemptID],
            let stored = requests[requestID],
            let attempt = stored.lifecycle.activeAttempt
        else {
            return
        }
        let now = clock.now()
        guard attempt.leaseDeadline.elapsed(since: now) <= configuration.heartbeatInterval else {
            return
        }
        do {
            let deadline = now.advanced(by: configuration.attemptLease)
            try await localWorker.renewLease(
                attemptID: attemptID,
                until: deadline,
                coordinatorIncarnationID: configuration.incarnationID
            )
            try await renewLocalLifecycle(stored, attemptID: attemptID, deadline: deadline)
        } catch {
            await interrupt(
                attemptID: attemptID,
                error: InferPeerError(code: .workerUnavailable, isRetryable: true)
            )
        }
    }

    func renewLocalLifecycle(
        _ stored: StoredRequest,
        attemptID: AttemptID,
        deadline: MonotonicInstant
    ) async throws {
        var lifecycle = stored.lifecycle
        try lifecycle.renewLease(
            attemptID: attemptID,
            coordinatorIncarnationID: configuration.incarnationID,
            until: deadline
        )
        requests[stored.submission.requestID] = try await store.commit(
            RequestMutation(
                requestID: stored.submission.requestID,
                callerID: stored.submission.callerID,
                expectedRevision: stored.revision,
                lifecycle: lifecycle,
                events: []
            )
        )
    }

    static func publicInferenceError(_ error: any Error) -> InferPeerError {
        if let backendError = error as? InferenceBackendError {
            return InferPeerError(backendError: backendError)
        }
        if error is CancellationError {
            return InferPeerError(code: .cancelled, isRetryable: false)
        }
        return InferPeerError(code: .internal, isRetryable: true)
    }
}
