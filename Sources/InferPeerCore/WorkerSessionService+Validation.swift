import Foundation
import InferPeerInference
import InferPeerProtocol

extension WorkerSessionService {
    func prepare(
        _ assignment: InferPeer_V1_AttemptAssignment,
        metadata: InferPeer_V1_MessageMetadata
    ) throws -> PreparedWorkerAssignment {
        let context = try assignmentContext(metadata)
        guard assignment.hasRequest,
            assignment.hasSelectedModel,
            assignment.leaseDurationMilliseconds > 0,
            let incarnationID = CoordinatorIncarnationID(
                rawValue: assignment.coordinatorIncarnationID
            )
        else {
            throw CoordinatorError.invalidMessage
        }
        let execution = InferenceExecution(
            requestID: context.requestID,
            attemptID: context.attemptID,
            model: try ModelReference(wireValue: assignment.selectedModel),
            request: try TextGenerationRequest(wireValue: assignment.request)
        )
        let active = ActiveAssignment(
            requestID: context.requestID,
            attemptID: context.attemptID,
            coordinatorIncarnationID: incarnationID
        )
        return PreparedWorkerAssignment(
            context: context,
            execution: execution,
            workerAssignment: WorkerExecutionAssignment(
                execution: execution,
                coordinatorIncarnationID: incarnationID,
                leaseDeadline: clock.now().advanced(
                    by: .milliseconds(Int64(clamping: assignment.leaseDurationMilliseconds))
                )
            ),
            activeAssignment: active
        )
    }

    func admissionError(
        for execution: InferenceExecution,
        status: LocalWorkerStatus
    ) -> InferPeerError? {
        let allowed = execution.request.allowedWorkerIDs
        guard allowed.isEmpty || allowed.contains(configuration.workerID) else {
            return InferPeerError(code: .permissionDenied, isRetryable: false)
        }
        guard Self.permits(execution.model, requirement: execution.request.options.modelRequirement)
        else {
            return InferPeerError(code: .invalidRequest, isRetryable: false)
        }
        guard status.condition.participation == .available,
            status.condition.thermalState.permitsAdmission,
            status.load.hasAvailableSlot
        else {
            return InferPeerError(code: .workerUnavailable, isRetryable: true)
        }
        guard let model = status.models.first(where: { $0.model == execution.model }),
            model.isLoaded
        else {
            return InferPeerError(code: .modelUnavailable, isRetryable: true)
        }
        if let required = model.measuredMemoryBytes,
            let available = status.load.availableAppMemoryBytes,
            required > available
        {
            return InferPeerError(code: .resourceExhausted, isRetryable: true)
        }
        return nil
    }

    static func permits(
        _ model: ModelReference,
        requirement: ModelRequirement
    ) -> Bool {
        switch requirement.selection {
        case .exact(let expected): model == expected
        case .permittedModels(let permitted): permitted.contains(model)
        }
    }

    func cancel(metadata: InferPeer_V1_MessageMetadata) async throws {
        let context = try assignmentContext(metadata)
        guard active?.attemptID == context.attemptID else {
            throw CoordinatorError.staleAttempt
        }
        try await controller.requestCancellation(for: context.attemptID)
    }

    func renewLease(
        _ lease: InferPeer_V1_LeaseExtended,
        metadata: InferPeer_V1_MessageMetadata
    ) async throws {
        let context = try assignmentContext(metadata)
        guard let active, active.attemptID == context.attemptID,
            lease.leaseDurationMilliseconds > 0
        else {
            throw CoordinatorError.staleAttempt
        }
        try await controller.renewLease(
            for: context.attemptID,
            until: clock.now().advanced(
                by: .milliseconds(Int64(clamping: lease.leaseDurationMilliseconds))
            ),
            coordinatorIncarnationID: active.coordinatorIncarnationID
        )
    }

    func sendAttemptAccepted(_ context: WorkerAssignmentContext) async throws {
        let request = InferPeer_V1_WorkerSessionRequest.with {
            $0.metadata = metadata(requestID: context.requestID, attemptID: context.attemptID)
            $0.attemptAccepted = InferPeer_V1_AttemptAccepted()
        }
        try await enqueue(request)
    }

    func sendAttemptRejected(
        _ context: WorkerAssignmentContext,
        error: InferPeerError
    ) async throws {
        let request = InferPeer_V1_WorkerSessionRequest.with {
            $0.metadata = metadata(requestID: context.requestID, attemptID: context.attemptID)
            $0.attemptRejected.error = error.wireValue
        }
        try await enqueue(request)
    }

    func assignmentContext(
        _ metadata: InferPeer_V1_MessageMetadata
    ) throws -> WorkerAssignmentContext {
        guard metadata.hasRequestID, metadata.hasAttemptID,
            let requestID = RequestID(rawValue: metadata.requestID),
            let attemptID = AttemptID(rawValue: metadata.attemptID)
        else {
            throw CoordinatorError.invalidMessage
        }
        return WorkerAssignmentContext(requestID: requestID, attemptID: attemptID)
    }

    func enqueue(_ request: InferPeer_V1_WorkerSessionRequest) async throws {
        guard let session else { throw CoordinatorError.invalidMessage }
        let previous = sendTail
        let task = Task {
            if let previous { try await previous.value }
            try await session.send(request)
        }
        sendTail = task
        try await task.value
    }

    func metadata(
        requestID: RequestID? = nil,
        attemptID: AttemptID? = nil
    ) -> InferPeer_V1_MessageMetadata {
        let sequence = nextSequence
        nextSequence = nextSequence == .max ? .max : nextSequence + 1
        return InferPeer_V1_MessageMetadata.with {
            $0.protocolVersion = InferPeerProtocolVersion.current
            $0.clusterID = configuration.clusterID.rawValue
            $0.authenticatedSenderID = configuration.workerID.rawValue
            $0.messageID = UUID().uuidString.lowercased()
            if let requestID { $0.requestID = requestID.rawValue }
            if let attemptID { $0.attemptID = attemptID.rawValue }
            $0.sequence = sequence
        }
    }

    static func publicError(_ error: any Error) -> InferPeerError {
        CoordinatorEngine.publicInferenceError(error)
    }
}
