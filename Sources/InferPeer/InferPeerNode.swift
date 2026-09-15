import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage

/// Authenticated caller and worker sessions opened by one pairing operation.
public struct InferPeerJoinedSessions: Sendable {
    /// Caller session when the caller role is enabled.
    public let caller: (any CallerTransportSession)?

    /// Worker session when the worker role is enabled.
    public let worker: (any WorkerTransportSession)?
}

/// Thin, dependency-injected lifecycle facade over InferPeer's focused modules.
public actor InferPeerNode {
    private enum StartOperation: Equatable {
        case active(UUID)
        case cancelled(UUID)
    }

    let configuration: InferPeerNodeConfiguration
    let dependencies: InferPeerDependencies
    var nodeState = InferPeerNodeState.stopped
    private var listener: (any CoordinatorTransportListener)?
    var joinedSessions: InferPeerJoinedSessions?
    var callerRequests: CallerRequestService?
    var workerService: WorkerSessionService?
    var loadedModel: ModelReference?
    private var startOperation: StartOperation?
    var joinOperationID: UUID?
    private var isStopping = false

    /// Creates a stopped node without opening sockets or loading models.
    public init(
        configuration: InferPeerNodeConfiguration,
        dependencies: InferPeerDependencies
    ) {
        self.configuration = configuration
        self.dependencies = dependencies
    }

    /// Returns the current facade lifecycle state.
    public func state() -> InferPeerNodeState {
        nodeState
    }

    /// Starts configured coordinator resources; caller and worker connections remain explicit.
    public func start() async throws {
        guard nodeState == .stopped, startOperation == nil, !isStopping else {
            throw InferPeerNodeError.alreadyStarted
        }
        let operationID = UUID()
        startOperation = .active(operationID)
        var startedListener: (any CoordinatorTransportListener)?
        do {
            if configuration.roles.contains(.coordinator) {
                startedListener = try await makeCoordinatorListener()
            }
            guard startOperation == .active(operationID) else {
                throw CancellationError()
            }
            listener = startedListener
            nodeState = .started
            startOperation = nil
        } catch {
            await cleanUpAbandonedStart(listener: startedListener)
            if startOperation == .active(operationID)
                || startOperation == .cancelled(operationID)
            {
                startOperation = nil
            }
            throw error
        }
    }

    /// Stops every network resource owned by the facade and unloads its tracked model.
    public func stop() async {
        guard !isStopping else { return }
        if case .active(let operationID) = startOperation {
            startOperation = .cancelled(operationID)
        } else if nodeState == .stopped {
            return
        }
        isStopping = true
        joinOperationID = nil
        nodeState = .stopped
        let callerRequests = callerRequests
        let workerService = workerService
        let sessions = joinedSessions
        let listener = listener
        self.callerRequests = nil
        self.workerService = nil
        joinedSessions = nil
        self.listener = nil
        await dependencies.optional.advertisement?.stop()
        await dependencies.optional.coordinator?.stop()
        await callerRequests?.stop()
        await workerService?.stop()
        await sessions?.caller?.close()
        await sessions?.worker?.close()
        await listener?.close()
        await unloadTrackedModel()
        await dependencies.discovery.stop()
        await dependencies.transport.stop()
        isStopping = false
    }

    /// Starts bounded discovery for untrusted coordinator candidates.
    public func discoverCoordinators() async throws -> DiscoveryUpdateStream {
        try requireStarted()
        try requireJoiningRole()
        return try await dependencies.discovery.discover(
            bufferingLimit: configuration.streamBufferingLimit
        )
    }

    /// Validates a manually entered numeric LAN endpoint as an untrusted candidate.
    public func coordinatorCandidate(for endpoint: PeerEndpoint) async throws -> DiscoveredPeer {
        try requireStarted()
        try requireJoiningRole()
        return try await dependencies.discovery.candidate(for: endpoint)
    }

    /// Sends a pairing invitation and opens every explicitly enabled joining role.
    public func join(_ invitation: PairingInvitation) async throws -> InferPeerJoinedSessions {
        try requireStarted()
        try requireJoiningRole()
        guard joinedSessions == nil, joinOperationID == nil else {
            throw InferPeerNodeError.alreadyJoined
        }
        let operationID = UUID()
        joinOperationID = operationID
        let endpoint = invitation.coordinator.endpoint
        var resources = PendingJoinResources()
        do {
            resources.caller = try await connectCaller(to: endpoint, invitation: invitation)
            try requireActiveJoin(operationID)
            resources.worker = try await connectWorker(to: endpoint, invitation: invitation)
            try requireActiveJoin(operationID)
            resources.callerRequests = try await makeCallerRequestService(
                session: resources.caller,
                clusterID: invitation.coordinator.clusterID
            )
            try requireActiveJoin(operationID)
            resources.workerService = try await makeWorkerService(
                session: resources.worker,
                clusterID: invitation.coordinator.clusterID
            )
            try requireActiveJoin(operationID)
            let sessions = installJoinedSessions(resources)
            joinOperationID = nil
            return sessions
        } catch {
            await cleanUpFailedJoin(resources)
            if joinOperationID == operationID {
                joinOperationID = nil
            }
            throw error
        }
    }

    /// Closes joined caller and worker roles while leaving this node started for a clean rejoin.
    public func leaveCoordinator() async {
        joinOperationID = nil
        let callerRequests = callerRequests
        let workerService = workerService
        let sessions = joinedSessions
        self.callerRequests = nil
        self.workerService = nil
        joinedSessions = nil
        await callerRequests?.stop()
        await workerService?.stop()
        await sessions?.caller?.close()
        await sessions?.worker?.close()
    }

    /// Durably stores and sends one caller request under a stable identifier.
    public func submit(
        _ request: TextGenerationRequest,
        requestID: RequestID? = nil
    ) async throws -> InferPeerRequestHandle {
        try requireStarted()
        try requireRole(.caller)
        let callerRequests = try requireCallerRequests()
        return try await callerRequests.submit(request, requestID: requestID)
    }

    /// Subscribes to bounded coordinator replay after an optional durable cursor.
    public func events(requestID: RequestID, after cursor: UInt64? = nil) async throws
        -> InferPeerRequestEventStream
    {
        try requireStarted()
        try requireRole(.caller)
        let callerRequests = try requireCallerRequests()
        return try await callerRequests.events(requestID: requestID, after: cursor)
    }

    /// Acknowledges a coordinator cursor only after the host has consumed it durably.
    public func acknowledge(requestID: RequestID, through cursor: UInt64) async throws {
        try requireStarted()
        try requireRole(.caller)
        let callerRequests = try requireCallerRequests()
        try await callerRequests.acknowledge(requestID: requestID, through: cursor)
    }

    /// Durably requests cancellation or confirms an unsent local cancellation.
    @discardableResult
    public func cancel(requestID: RequestID) async throws -> CancellationState {
        try requireStarted()
        try requireRole(.caller)
        let callerRequests = try requireCallerRequests()
        return try await callerRequests.cancel(requestID: requestID)
    }

    /// Returns caller-local outbox, replay, and cancellation state.
    public func requestStatus(_ requestID: RequestID) async throws
        -> InferPeerCallerRequestStatus
    {
        try requireStarted()
        try requireRole(.caller)
        let callerRequests = try requireCallerRequests()
        return try await callerRequests.status(requestID: requestID)
    }

    /// Returns the current host and platform worker status.
    public func status() async -> LocalWorkerStatus {
        await dependencies.status.currentStatus()
    }

    /// Updates host-controlled worker participation.
    public func setParticipation(_ participation: WorkerParticipationState) async throws {
        try requireRole(.worker)
        await dependencies.status.setParticipation(participation)
        try await workerService?.refreshStatus()
    }

    /// Samples and publishes worker state after a host lifecycle or platform-state change.
    public func refreshWorkerStatus() async throws {
        try requireRole(.worker)
        await dependencies.status.refresh()
        try await workerService?.refreshStatus()
    }

    /// Persists a verified local model registration idempotently.
    public func registerModel(_ artifact: LocalModelArtifact) async throws
        -> ModelRegistrationResult
    {
        try requireRole(.worker)
        guard let registry = dependencies.optional.modelRegistry else {
            throw InferPeerNodeError.modelRegistryUnavailable
        }
        return try await registry.register(artifact)
    }

    /// Loads one exact registered model through the explicitly injected backend.
    public func loadModel(_ reference: ModelReference) async throws {
        try requireRole(.worker)
        let services = try modelServices()
        guard let registration = try await services.registry.model(reference: reference) else {
            throw InferPeerNodeError.modelNotRegistered
        }
        try await services.backend.loadModel(registration.artifact)
        loadedModel = reference
    }

    /// Executes one worker assignment through the injected backend.
    public func generate(_ execution: InferenceExecution) async throws -> GenerationEventStream {
        try requireStarted()
        try requireRole(.worker)
        guard let backend = dependencies.optional.inferenceBackend else {
            throw InferPeerNodeError.inferenceBackendUnavailable
        }
        return try await backend.generate(execution)
    }

    /// Cancels one locally active worker attempt.
    public func cancel(attemptID: AttemptID) async throws {
        try requireRole(.worker)
        guard let backend = dependencies.optional.inferenceBackend else {
            throw InferPeerNodeError.inferenceBackendUnavailable
        }
        await backend.cancel(attemptID: attemptID)
    }

    /// Revokes a peer's future access using the injected identity provider.
    public func forgetPeer(_ peerID: PeerID) async throws {
        try await dependencies.identity.revoke(peerID: peerID)
        await dependencies.optional.coordinator?.revoke(peerID: peerID)
    }

    /// Returns the certificate-bound local identity.
    public func localIdentity() async throws -> LocalPeerIdentity {
        try await dependencies.identity.localIdentity()
    }
}
