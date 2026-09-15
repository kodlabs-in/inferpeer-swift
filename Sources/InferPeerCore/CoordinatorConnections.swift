import Foundation
import InferPeerInference
import InferPeerProtocol

actor CoordinatorCallerConnection {
    nonisolated let id = UUID()
    nonisolated let peerID: PeerID

    private let session: any CoordinatorCallerSession
    private let configuration: CoordinatorConfiguration
    private var nextSequence: UInt64 = 2
    private var lastCursors: [RequestID: UInt64] = [:]
    private var sendTail: Task<Void, any Error>?

    init(
        session: any CoordinatorCallerSession,
        configuration: CoordinatorConfiguration
    ) {
        self.session = session
        peerID = session.authenticatedPeerID
        self.configuration = configuration
    }

    func send(_ events: [PersistedRequestEvent]) async throws {
        for event in events {
            if let cursor = lastCursors[event.requestID], event.cursor <= cursor { continue }
            try await enqueue(response(for: event))
            lastCursors[event.requestID] = event.cursor
        }
    }

    func lastCursor(for requestID: RequestID) -> UInt64? {
        lastCursors[requestID]
    }

    func reject(
        requestID: RequestID,
        error: InferPeerError,
        retained: RetainedTerminalResult?
    ) async throws {
        let sequence = try takeSequence()
        let response = InferPeer_V1_ClientSessionResponse.with {
            $0.metadata.protocolVersion = InferPeerProtocolVersion.current
            $0.metadata.clusterID = configuration.clusterID.rawValue
            $0.metadata.authenticatedSenderID = configuration.coordinatorID.rawValue
            $0.metadata.messageID = UUID().uuidString.lowercased()
            $0.metadata.requestID = requestID.rawValue
            if let attemptID = retained?.attemptID {
                $0.metadata.attemptID = attemptID.rawValue
            }
            $0.metadata.sequence = sequence
            $0.commandRejected.error = error.wireValue
            if let result = retained?.result {
                $0.commandRejected.retainedTerminalResult = result.wireValue
            }
        }
        try await enqueue(response)
    }

    func close() async {
        await session.close()
    }

    private func response(
        for event: PersistedRequestEvent
    ) throws -> InferPeer_V1_ClientSessionResponse {
        let metadata = try makeMetadata(
            requestID: event.requestID,
            attemptID: event.attemptID,
            eventCursor: event.cursor
        )
        return InferPeer_V1_ClientSessionResponse.with {
            $0.metadata = metadata
            apply(event.payload, to: &$0)
        }
    }

    private func apply(
        _ payload: RequestEventPayload,
        to response: inout InferPeer_V1_ClientSessionResponse
    ) {
        switch payload {
        case .accepted(let state):
            response.requestAccepted.state = state.wireValue
        case .stateChanged(let state, let attemptNumber):
            response.requestStateChanged.state = state.wireValue
            response.requestStateChanged.attemptNumber = attemptNumber
        case .generation(let event):
            response.generationEvent = event.wireValue
        case .interrupted(let error, let willRetry):
            response.generationEvent.interrupted.error = error.wireValue
            response.generationEvent.interrupted.willRetry = willRetry
        case .cancellation(let cancellation):
            response.cancellationUpdated.state = cancellation.wireValue
        case .failed(let error):
            response.requestFailed.error = error.wireValue
        }
    }

    private func enqueue(_ response: InferPeer_V1_ClientSessionResponse) async throws {
        let previous = sendTail
        let session = session
        let task = Task {
            if let previous { try await previous.value }
            try await session.send(response)
        }
        sendTail = task
        try await task.value
    }

    private func makeMetadata(
        requestID: RequestID,
        attemptID: AttemptID?,
        eventCursor: UInt64
    ) throws -> InferPeer_V1_MessageMetadata {
        let sequence = try takeSequence()
        return InferPeer_V1_MessageMetadata.with {
            $0.protocolVersion = InferPeerProtocolVersion.current
            $0.clusterID = configuration.clusterID.rawValue
            $0.authenticatedSenderID = configuration.coordinatorID.rawValue
            $0.messageID = UUID().uuidString.lowercased()
            $0.requestID = requestID.rawValue
            if let attemptID { $0.attemptID = attemptID.rawValue }
            $0.sequence = sequence
            $0.eventCursor = eventCursor
        }
    }

    private func takeSequence() throws -> UInt64 {
        guard nextSequence < .max else { throw CoordinatorError.invalidMessage }
        defer { nextSequence += 1 }
        return nextSequence
    }
}

actor CoordinatorWorkerConnection {
    nonisolated let id = UUID()
    nonisolated let peerID: PeerID

    private let session: any CoordinatorWorkerSession
    private let configuration: CoordinatorConfiguration
    private var nextSequence: UInt64 = 2
    private var sendTail: Task<Void, any Error>?

    init(
        session: any CoordinatorWorkerSession,
        configuration: CoordinatorConfiguration
    ) {
        self.session = session
        peerID = session.authenticatedPeerID
        self.configuration = configuration
    }

    func assign(
        _ stored: StoredRequest,
        attempt: ActiveAttempt,
        model: ModelReference
    ) async throws {
        let leaseMilliseconds = configuration.attemptLease.coordinatorWireMilliseconds
        let response = InferPeer_V1_WorkerSessionResponse.with {
            $0.metadata = metadata(
                requestID: stored.submission.requestID,
                attemptID: attempt.attemptID
            )
            $0.assignment.request = stored.submission.request.wireValue
            $0.assignment.attemptNumber = attempt.number
            $0.assignment.leaseDurationMilliseconds = leaseMilliseconds
            $0.assignment.coordinatorIncarnationID = configuration.incarnationID.rawValue
            $0.assignment.selectedModel = model.wireValue
        }
        try await enqueue(response)
    }

    func cancel(requestID: RequestID, attemptID: AttemptID) async throws {
        let response = InferPeer_V1_WorkerSessionResponse.with {
            $0.metadata = metadata(requestID: requestID, attemptID: attemptID)
            $0.cancelAttempt = InferPeer_V1_CancelAttemptCommand()
        }
        try await enqueue(response)
    }

    func extendLease(requestID: RequestID, attemptID: AttemptID) async throws {
        let response = InferPeer_V1_WorkerSessionResponse.with {
            $0.metadata = metadata(requestID: requestID, attemptID: attemptID)
            $0.leaseExtended.leaseDurationMilliseconds =
                configuration.attemptLease.coordinatorWireMilliseconds
        }
        try await enqueue(response)
    }

    func close() async {
        await session.close()
    }

    private func enqueue(_ response: InferPeer_V1_WorkerSessionResponse) async throws {
        let previous = sendTail
        let session = session
        let task = Task {
            if let previous { try await previous.value }
            try await session.send(response)
        }
        sendTail = task
        try await task.value
    }

    private func metadata(
        requestID: RequestID,
        attemptID: AttemptID
    ) -> InferPeer_V1_MessageMetadata {
        let sequence = nextSequence
        nextSequence = nextSequence == .max ? .max : nextSequence + 1
        return InferPeer_V1_MessageMetadata.with {
            $0.protocolVersion = InferPeerProtocolVersion.current
            $0.clusterID = configuration.clusterID.rawValue
            $0.authenticatedSenderID = configuration.coordinatorID.rawValue
            $0.messageID = UUID().uuidString.lowercased()
            $0.requestID = requestID.rawValue
            $0.attemptID = attemptID.rawValue
            $0.sequence = sequence
        }
    }
}

extension GenerationEvent {
    var wireValue: InferPeer_V1_GenerationEvent {
        InferPeer_V1_GenerationEvent.with {
            switch self {
            case .textDelta(let delta): $0.textDelta = delta.wireValue
            case .completed(let result): $0.completed = result.wireValue
            }
        }
    }
}

extension Duration {
    var coordinatorWireMilliseconds: UInt64 {
        let parts = components
        let seconds = UInt64(clamping: parts.seconds)
        let milliseconds = seconds.multipliedReportingOverflow(by: 1_000)
        guard !milliseconds.overflow else { return .max }
        let fractional = UInt64(clamping: parts.attoseconds / 1_000_000_000_000_000)
        let total = milliseconds.partialValue.addingReportingOverflow(fractional)
        return total.overflow ? .max : total.partialValue
    }
}
