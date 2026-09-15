import Foundation
import InferPeerInference
import InferPeerProtocol

/// Executes coordinator assignments through one serialized backend slot.
public actor WorkerSessionService: WorkerSessionServing {
    struct ActiveAssignment: Sendable {
        let requestID: RequestID
        let attemptID: AttemptID
        let coordinatorIncarnationID: CoordinatorIncarnationID
    }

    let configuration: WorkerSessionConfiguration
    let statusProvider: any StatusProvider
    let controller: WorkerController
    let clock: any CoreClock
    var session: (any WorkerTransportSession)?
    var nextSequence: UInt64 = 2
    var active: ActiveAssignment?
    var responseTask: Task<Void, Never>?
    var heartbeatTask: Task<Void, Never>?
    var statusTask: Task<Void, Never>?
    var generationTask: Task<Void, Never>?
    var sendTail: Task<Void, any Error>?
    var isRunning = false

    /// Creates a stopped worker client around one backend and status provider.
    public init(
        configuration: WorkerSessionConfiguration,
        statusProvider: any StatusProvider,
        backend: any InferenceBackend,
        clock: any CoreClock = SystemCoreClock()
    ) {
        self.configuration = configuration
        self.statusProvider = statusProvider
        controller = WorkerController(backend: backend, clock: clock)
        self.clock = clock
    }

    /// Sends initial status before accepting assignments and starts bounded loops.
    public func start(session: any WorkerTransportSession) async throws {
        guard !isRunning else { throw CoordinatorError.alreadyStarted }
        isRunning = true
        self.session = session
        nextSequence = 2
        sendTail = nil
        do {
            try await sendStatus()
            startResponseLoop(session)
            startHeartbeatLoop()
            startStatusLoop()
        } catch {
            isRunning = false
            self.session = nil
            await session.close()
            throw error
        }
    }

    /// Cancels execution before closing its transport session.
    public func stop() async {
        guard isRunning || session != nil else { return }
        isRunning = false
        responseTask?.cancel()
        heartbeatTask?.cancel()
        statusTask?.cancel()
        generationTask?.cancel()
        responseTask = nil
        heartbeatTask = nil
        statusTask = nil
        generationTask = nil
        let active = active
        self.active = nil
        if let active { try? await controller.cancelAndConfirm(for: active.attemptID) }
        sendTail?.cancel()
        sendTail = nil
        let session = session
        self.session = nil
        await session?.close()
    }

    func start(
        _ assignment: InferPeer_V1_AttemptAssignment,
        metadata: InferPeer_V1_MessageMetadata
    ) async throws {
        let prepared = try prepare(assignment, metadata: metadata)
        let status = await statusProvider.currentStatus()
        if let error = admissionError(for: prepared.execution, status: status) {
            try await sendAttemptRejected(prepared.context, error: error)
            return
        }
        let stream: GenerationEventStream
        do {
            stream = try await controller.start(prepared.workerAssignment)
        } catch {
            try await sendAttemptRejected(prepared.context, error: Self.publicError(error))
            return
        }
        active = prepared.activeAssignment
        do {
            try await sendAttemptAccepted(prepared.context)
            consume(stream, assignment: prepared.activeAssignment)
        } catch {
            active = nil
            try? await controller.cancelAndConfirm(for: prepared.context.attemptID)
            try await sendAttemptRejected(prepared.context, error: Self.publicError(error))
        }
    }

    func consume(
        _ stream: GenerationEventStream,
        assignment: ActiveAssignment
    ) {
        generationTask = Task { [weak self] in
            var completed = false
            do {
                for try await event in stream {
                    if case .completed = event { completed = true }
                    try await self?.send(event, assignment: assignment)
                }
                if !completed {
                    await self?.interruptIfActive(
                        assignment,
                        error: InferPeerError(code: .internal, isRetryable: true)
                    )
                }
            } catch {
                await self?.interruptIfActive(assignment, error: Self.publicError(error))
            }
            await self?.generationEnded(assignment)
        }
    }

    func interruptIfActive(
        _ assignment: ActiveAssignment,
        error: InferPeerError
    ) async {
        guard active?.attemptID == assignment.attemptID else { return }
        active = nil
        generationTask = nil
        try? await cancelControllerAttempt(assignment.attemptID)
        try? await sendInterruption(assignment: assignment, error: error)
    }

    func cancelControllerAttempt(_ attemptID: AttemptID) async throws {
        try await controller.cancelAndConfirm(for: attemptID)
    }

    func send(
        _ event: GenerationEvent,
        assignment: ActiveAssignment
    ) async throws {
        let request = InferPeer_V1_WorkerSessionRequest.with {
            $0.metadata = metadata(
                requestID: assignment.requestID,
                attemptID: assignment.attemptID
            )
            $0.generationEvent = event.wireValue
        }
        try await enqueue(request)
        if case .completed = event {
            try await controller.complete(assignment.attemptID)
        }
    }

    func sendInterruption(
        assignment: ActiveAssignment,
        error: InferPeerError
    ) async throws {
        let request = InferPeer_V1_WorkerSessionRequest.with {
            $0.metadata = metadata(
                requestID: assignment.requestID,
                attemptID: assignment.attemptID
            )
            $0.generationEvent.interrupted.error = error.wireValue
            $0.generationEvent.interrupted.willRetry = error.isRetryable
        }
        try await enqueue(request)
    }

    func generationEnded(_ assignment: ActiveAssignment) {
        guard active?.attemptID == assignment.attemptID else { return }
        active = nil
        generationTask = nil
    }

}
