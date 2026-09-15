import Foundation
import InferPeerInference
import InferPeerProtocol

/// Lifecycle contract used by the integration facade to own one coordinator engine.
public protocol CoordinatorServing: Sendable {
    /// Recovers durable work and begins consuming authenticated sessions.
    func start(listener: any CoordinatorTransportListener) async throws

    /// Stops admission, sessions, maintenance, and active local execution.
    func stop() async

    /// Immediately closes active sessions for a revoked peer.
    func revoke(peerID: PeerID) async
}

/// Durable coordinator orchestration for callers, workers, replay, leases, and retry.
public actor CoordinatorEngine: CoordinatorServing {
    struct WorkerRecord {
        let connection: CoordinatorWorkerConnection?
        var status: LocalWorkerStatus
        var lastHeartbeat: MonotonicInstant
        var activeAttemptID: AttemptID?
    }

    let configuration: CoordinatorConfiguration
    let store: any JobStore
    let scheduler: any SchedulerPolicy
    let clock: any CoreClock
    let wallClock: any CoreWallClock
    let localWorker: (any CoordinatorLocalWorker)?

    var callers: [PeerID: CoordinatorCallerConnection] = [:]
    var workers: [PeerID: WorkerRecord] = [:]
    var requests: [RequestID: StoredRequest] = [:]
    var requestDeadlines: [RequestID: MonotonicInstant] = [:]
    var attemptRequests: [AttemptID: RequestID] = [:]
    var attemptModels: [AttemptID: ModelReference] = [:]
    var activeConversations: [ConversationKey: RequestID] = [:]
    var schedulingRequests: Set<RequestID> = []
    var rescheduleRequests: Set<RequestID> = []
    var sessionTasks: [UUID: Task<Void, Never>] = [:]
    var localExecutionTasks: [AttemptID: Task<Void, Never>] = [:]
    var listenerTask: Task<Void, Never>?
    var maintenanceTask: Task<Void, Never>?
    var lastRetentionSweep: MonotonicInstant?
    var isRunning = false

    /// Creates a stopped engine with explicit durable and scheduling dependencies.
    public init(
        configuration: CoordinatorConfiguration,
        store: any JobStore,
        scheduler: any SchedulerPolicy,
        clock: any CoreClock = SystemCoreClock(),
        wallClock: any CoreWallClock = SystemCoreWallClock(),
        localWorker: (any CoordinatorLocalWorker)? = nil
    ) {
        self.configuration = configuration
        self.store = store
        self.scheduler = scheduler
        self.clock = clock
        self.wallClock = wallClock
        self.localWorker = localWorker
    }

    /// Reconciles uncertain old-incarnation attempts before accepting new sessions.
    public func start(listener: any CoordinatorTransportListener) async throws {
        guard !isRunning else { throw CoordinatorError.alreadyStarted }
        isRunning = true
        do {
            try await pruneTerminalRequests()
            try await recoverRequests()
            await installLocalWorker()
            startSessionAcceptance(listener)
            startMaintenance()
            await scheduleQueuedRequests()
        } catch {
            isRunning = false
            throw error
        }
    }

    /// Stops every task and connection owned by this engine.
    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        listenerTask?.cancel()
        maintenanceTask?.cancel()
        listenerTask = nil
        maintenanceTask = nil
        lastRetentionSweep = nil
        sessionTasks.values.forEach { $0.cancel() }
        sessionTasks.removeAll()
        localExecutionTasks.values.forEach { $0.cancel() }
        localExecutionTasks.removeAll()
        let callerConnections = Array(callers.values)
        let workerConnections = workers.values.compactMap(\.connection)
        let activeLocalAttempt = localWorker.flatMap { workers[$0.peerID]?.activeAttemptID }
        callers.removeAll()
        workers.removeAll()
        if let activeLocalAttempt {
            await localWorker?.cancel(attemptID: activeLocalAttempt)
        }
        for connection in callerConnections { await connection.close() }
        for connection in workerConnections { await connection.close() }
    }

    /// Removes and closes all connections authenticated as the revoked peer.
    public func revoke(peerID: PeerID) async {
        if let caller = callers.removeValue(forKey: peerID) {
            await caller.close()
        }
        if let worker = workers.removeValue(forKey: peerID) {
            await worker.connection?.close()
            if let attemptID = worker.activeAttemptID {
                await interrupt(
                    attemptID: attemptID,
                    error: InferPeerError(code: .permissionDenied, isRetryable: false)
                )
            }
        }
    }

    private func startSessionAcceptance(_ listener: any CoordinatorTransportListener) {
        let sessions = listener.sessions(bufferingLimit: configuration.streamBufferLimit)
        listenerTask = Task { [weak self] in
            do {
                for try await session in sessions {
                    await self?.accept(session)
                }
            } catch {
                await self?.listenerFailed()
            }
        }
    }

    private func startMaintenance() {
        let interval = configuration.maintenanceInterval
        maintenanceTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: interval)
                    await self?.performMaintenance()
                }
            } catch {
                // Cancellation is the normal shutdown path.
            }
        }
    }

    private func listenerFailed() async {
        guard isRunning else { return }
        await stop()
    }

    private func accept(_ session: InboundPeerSession) async {
        guard isRunning else {
            switch session {
            case .caller(let session): await session.close()
            case .worker(let session): await session.close()
            }
            return
        }
        switch session {
        case .caller(let session): await acceptCaller(session)
        case .worker(let session): await acceptWorker(session)
        }
    }
}
