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
    private let configuration: InferPeerNodeConfiguration
    private let dependencies: InferPeerDependencies
    private var nodeState = InferPeerNodeState.stopped
    private var listener: (any CoordinatorTransportListener)?
    private var joinedSessions: InferPeerJoinedSessions?
    private var callerRequests: CallerRequestService?
    private var loadedModel: ModelReference?

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
        guard nodeState == .stopped else { throw InferPeerNodeError.alreadyStarted }
        if configuration.roles.contains(.coordinator) {
            try await startCoordinator()
        }
        nodeState = .started
    }

    /// Stops every network resource owned by the facade and unloads its tracked model.
    public func stop() async {
        guard nodeState == .started else { return }
        nodeState = .stopped
        await dependencies.optional.advertisement?.stop()
        await callerRequests?.stop()
        callerRequests = nil
        await joinedSessions?.caller?.close()
        await joinedSessions?.worker?.close()
        joinedSessions = nil
        await listener?.close()
        listener = nil
        await unloadTrackedModel()
        await dependencies.discovery.stop()
        await dependencies.transport.stop()
    }

    /// Returns authenticated inbound coordinator sessions without consuming them.
    public func inboundSessions() throws -> InboundPeerSessionStream {
        try requireStarted()
        try requireRole(.coordinator)
        guard let listener else { throw InferPeerNodeError.notStarted }
        return listener.sessions(bufferingLimit: configuration.streamBufferingLimit)
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

    /// Consumes a pairing invitation and opens every explicitly enabled joining role.
    public func join(_ invitation: PairingInvitation) async throws -> InferPeerJoinedSessions {
        try requireStarted()
        try requireJoiningRole()
        guard joinedSessions == nil else { throw InferPeerNodeError.alreadyJoined }
        try await dependencies.identity.consume(invitation)

        let endpoint = invitation.coordinator.endpoint
        let caller = try await connectCaller(to: endpoint)
        var worker: (any WorkerTransportSession)?
        do {
            worker = try await connectWorker(to: endpoint)
            callerRequests = try await makeCallerRequestService(
                session: caller,
                clusterID: invitation.coordinator.clusterID
            )
            let sessions = InferPeerJoinedSessions(caller: caller, worker: worker)
            joinedSessions = sessions
            return sessions
        } catch {
            await caller?.close()
            await worker?.close()
            throw error
        }
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
        try requireRole(.caller)
        let callerRequests = try requireCallerRequests()
        return try await callerRequests.cancel(requestID: requestID)
    }

    /// Returns caller-local outbox, replay, and cancellation state.
    public func requestStatus(_ requestID: RequestID) async throws
        -> InferPeerCallerRequestStatus
    {
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
    }

    /// Returns the certificate-bound local identity.
    public func localIdentity() async throws -> LocalPeerIdentity {
        try await dependencies.identity.localIdentity()
    }

    private func startCoordinator() async throws {
        guard let endpoint = configuration.coordinatorEndpoint else {
            throw InferPeerNodeError.coordinatorEndpointRequired
        }
        let listener = try await dependencies.transport.listen(at: endpoint)
        do {
            try await dependencies.optional.advertisement?.start()
            self.listener = listener
        } catch {
            await listener.close()
            throw error
        }
    }

    private func connectCaller(to endpoint: PeerEndpoint) async throws
        -> (any CallerTransportSession)?
    {
        guard configuration.roles.contains(.caller) else { return nil }
        return try await dependencies.transport.connectCaller(to: endpoint)
    }

    private func connectWorker(to endpoint: PeerEndpoint) async throws
        -> (any WorkerTransportSession)?
    {
        guard configuration.roles.contains(.worker) else { return nil }
        return try await dependencies.transport.connectWorker(to: endpoint)
    }

    private func makeCallerRequestService(
        session: (any CallerTransportSession)?,
        clusterID: ClusterID
    ) async throws -> CallerRequestService? {
        guard let session else { return nil }
        guard let outbox = dependencies.optional.callerOutbox else { return nil }
        let identity = try await dependencies.identity.localIdentity()
        let service = CallerRequestService(
            session: session,
            outbox: outbox,
            clusterID: clusterID,
            callerID: identity.peerID,
            bufferingLimit: configuration.streamBufferingLimit
        )
        await service.start()
        return service
    }

    private func modelServices() throws -> (
        registry: any InferPeerModelRegistry,
        backend: any InferenceBackend
    ) {
        guard let registry = dependencies.optional.modelRegistry else {
            throw InferPeerNodeError.modelRegistryUnavailable
        }
        guard let backend = dependencies.optional.inferenceBackend else {
            throw InferPeerNodeError.inferenceBackendUnavailable
        }
        return (registry, backend)
    }

    private func unloadTrackedModel() async {
        guard let loadedModel, let backend = dependencies.optional.inferenceBackend else { return }
        do {
            try await backend.unloadModel(loadedModel)
        } catch {
            // Stop remains best-effort so all network resources are still released.
        }
        self.loadedModel = nil
    }

    private func requireStarted() throws {
        guard nodeState == .started else { throw InferPeerNodeError.notStarted }
    }

    private func requireRole(_ role: NodeRole) throws {
        guard configuration.roles.contains(role) else {
            throw InferPeerNodeError.roleNotEnabled(role)
        }
    }

    private func requireJoiningRole() throws {
        guard configuration.roles.contains(.caller) || configuration.roles.contains(.worker) else {
            throw InferPeerNodeError.roleNotEnabled(.caller)
        }
    }

    private func requireCallerRequests() throws -> CallerRequestService {
        guard joinedSessions?.caller != nil else {
            throw InferPeerNodeError.callerSessionUnavailable
        }
        guard let callerRequests else { throw InferPeerNodeError.callerOutboxUnavailable }
        return callerRequests
    }
}
