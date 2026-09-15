import Foundation
import InferPeerInference
import InferPeerProtocol

extension CoordinatorEngine {
    func acceptCaller(_ session: any CoordinatorCallerSession) async {
        let connection = CoordinatorCallerConnection(
            session: session,
            configuration: configuration
        )
        let previous = callers.updateValue(connection, forKey: connection.peerID)
        if let previous { await previous.close() }
        let taskID = connection.id
        let requests = session.requests(bufferingLimit: configuration.streamBufferLimit)
        sessionTasks[taskID] = Task { [weak self] in
            do {
                for try await request in requests {
                    do {
                        try await self?.receiveCallerRequest(
                            request,
                            from: connection.peerID,
                            connectionID: connection.id
                        )
                    } catch {
                        guard let requestID = RequestID(rawValue: request.metadata.requestID) else {
                            throw error
                        }
                        try await connection.reject(
                            requestID: requestID,
                            error: Self.publicCommandError(error),
                            retained: Self.retainedTerminalResult(error)
                        )
                    }
                }
            } catch {
                await connection.close()
            }
            await self?.callerEnded(peerID: connection.peerID, connectionID: connection.id)
        }
    }

    func acceptWorker(_ session: any CoordinatorWorkerSession) async {
        let connection = CoordinatorWorkerConnection(
            session: session,
            configuration: configuration
        )
        let placeholder = unavailableWorker(connection.peerID, connection: connection)
        let previous = workers.updateValue(placeholder, forKey: connection.peerID)
        if let previous { await previous.connection?.close() }
        if let attemptID = previous?.activeAttemptID {
            await interrupt(
                attemptID: attemptID,
                error: InferPeerError(code: .workerUnavailable, isRetryable: true)
            )
        }
        let taskID = connection.id
        let requests = session.requests(bufferingLimit: configuration.streamBufferLimit)
        sessionTasks[taskID] = Task { [weak self] in
            do {
                for try await request in requests {
                    try await self?.receiveWorkerRequest(
                        request,
                        from: connection.peerID,
                        connectionID: connection.id
                    )
                }
            } catch {
                await connection.close()
            }
            await self?.workerEnded(peerID: connection.peerID, connectionID: connection.id)
        }
    }

    func receiveCallerRequest(
        _ message: InferPeer_V1_ClientSessionRequest,
        from peerID: PeerID,
        connectionID: UUID
    ) async throws {
        guard callers[peerID]?.id == connectionID else { return }
        let requestID = try requiredRequestID(message.metadata)
        switch message.payload {
        case .submit(let command):
            try await submit(command, requestID: requestID, callerID: peerID)
        case .cancel:
            try await cancel(requestID: requestID, callerID: peerID)
        case .resume(let command):
            try await replay(
                requestID: requestID,
                callerID: peerID,
                after: command.afterEventCursor
            )
        case .acknowledgeEvents(let command):
            try await store.acknowledge(
                requestID: requestID,
                callerID: peerID,
                through: command.throughEventCursor
            )
        default:
            throw CoordinatorError.invalidMessage
        }
    }

    func receiveWorkerRequest(
        _ message: InferPeer_V1_WorkerSessionRequest,
        from peerID: PeerID,
        connectionID: UUID
    ) async throws {
        guard workers[peerID]?.connection?.id == connectionID else { return }
        switch message.payload {
        case .status(let status):
            try await updateWorker(peerID: peerID, status: LocalWorkerStatus(wireValue: status))
        case .attemptAccepted:
            try await acceptAttempt(try attemptContext(message.metadata, workerID: peerID))
        case .attemptRejected(let rejection):
            let context = try attemptContext(message.metadata, workerID: peerID)
            await interrupt(
                attemptID: context.attemptID,
                error: InferPeerError(wireValue: rejection.error)
            )
        case .leaseRenewal:
            try await renewLease(try attemptContext(message.metadata, workerID: peerID))
        case .generationEvent(let event):
            try await receiveGeneration(
                event,
                context: try attemptContext(message.metadata, workerID: peerID)
            )
        default:
            throw CoordinatorError.invalidMessage
        }
    }

    func callerEnded(peerID: PeerID, connectionID: UUID) {
        sessionTasks[connectionID] = nil
        guard callers[peerID]?.id == connectionID else { return }
        callers[peerID] = nil
    }

    func workerEnded(peerID: PeerID, connectionID: UUID) async {
        sessionTasks[connectionID] = nil
        guard workers[peerID]?.connection?.id == connectionID else { return }
        let attemptID = workers.removeValue(forKey: peerID)?.activeAttemptID
        if let attemptID {
            await interrupt(
                attemptID: attemptID,
                error: InferPeerError(code: .workerUnavailable, isRetryable: true)
            )
        }
        await scheduleQueuedRequests()
    }

    func requiredRequestID(_ metadata: InferPeer_V1_MessageMetadata) throws -> RequestID {
        guard metadata.hasRequestID, let requestID = RequestID(rawValue: metadata.requestID) else {
            throw CoordinatorError.invalidMessage
        }
        return requestID
    }

    func attemptContext(
        _ metadata: InferPeer_V1_MessageMetadata,
        workerID: PeerID
    ) throws -> AttemptContext {
        let metadataRequestID = try requiredRequestID(metadata)
        guard metadata.hasAttemptID,
            let attemptID = AttemptID(rawValue: metadata.attemptID),
            let requestID = attemptRequests[attemptID],
            requestID == metadataRequestID,
            requests[requestID]?.lifecycle.activeAttempt?.workerID == workerID
        else {
            throw CoordinatorError.staleAttempt
        }
        return AttemptContext(requestID: requestID, attemptID: attemptID, workerID: workerID)
    }

    func unavailableWorker(
        _ peerID: PeerID,
        connection: CoordinatorWorkerConnection
    ) -> WorkerRecord {
        WorkerRecord(
            connection: connection,
            status: LocalWorkerStatus(
                condition: WorkerCondition(
                    participation: .unavailable,
                    thermalState: .unknown,
                    lowPowerModeEnabled: nil
                ),
                load: WorkerLoad(
                    activeGenerations: 0,
                    generationCapacity: 1,
                    availableAppMemoryBytes: nil
                ),
                models: []
            ),
            lastHeartbeat: clock.now(),
            activeAttemptID: nil
        )
    }

    static func publicCommandError(_ error: any Error) -> InferPeerError {
        switch error {
        case RequestPersistenceError.resourceExhausted:
            InferPeerError(code: .resourceExhausted, isRetryable: true)
        case RequestPersistenceError.replayExpired(_):
            InferPeerError(code: .replayExpired, isRetryable: false)
        case RequestPersistenceError.accessDenied:
            InferPeerError(code: .permissionDenied, isRetryable: false)
        case RequestPersistenceError.requestConflict,
            RequestPersistenceError.requestNotFound,
            RequestPersistenceError.conversationRevisionNotIncreasing,
            CoordinatorError.invalidMessage:
            InferPeerError(code: .invalidRequest, isRetryable: false)
        case is InferenceValidationError:
            InferPeerError(code: .invalidRequest, isRetryable: false)
        case CoordinatorError.requestDeadlineElapsed:
            InferPeerError(code: .deadlineExceeded, isRetryable: false)
        case is CancellationError:
            InferPeerError(code: .cancelled, isRetryable: true)
        default:
            InferPeerError(code: .internal, isRetryable: true)
        }
    }

    static func retainedTerminalResult(_ error: any Error) -> RetainedTerminalResult? {
        guard case RequestPersistenceError.replayExpired(let retained) = error else { return nil }
        return retained
    }
}

struct AttemptContext: Sendable {
    let requestID: RequestID
    let attemptID: AttemptID
    let workerID: PeerID
}
