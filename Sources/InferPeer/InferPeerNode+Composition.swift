import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol

struct PendingJoinResources {
    var caller: (any CallerTransportSession)?
    var worker: (any WorkerTransportSession)?
    var callerRequests: CallerRequestService?
    var workerService: WorkerSessionService?
}

extension InferPeerNode {
    func installJoinedSessions(_ resources: PendingJoinResources) -> InferPeerJoinedSessions {
        let sessions = InferPeerJoinedSessions(
            caller: resources.caller,
            worker: resources.worker
        )
        callerRequests = resources.callerRequests
        workerService = resources.workerService
        joinedSessions = sessions
        return sessions
    }

    func cleanUpFailedJoin(_ resources: PendingJoinResources) async {
        await resources.callerRequests?.stop()
        await resources.workerService?.stop()
        await resources.caller?.close()
        await resources.worker?.close()
    }

    func makeCoordinatorListener() async throws -> any CoordinatorTransportListener {
        guard let endpoint = configuration.coordinatorEndpoint else {
            throw InferPeerNodeError.coordinatorEndpointRequired
        }
        let listener = try await dependencies.transport.listen(at: endpoint)
        do {
            guard let coordinator = dependencies.optional.coordinator else {
                throw InferPeerNodeError.coordinatorServiceUnavailable
            }
            try await coordinator.start(listener: listener)
            try await dependencies.optional.advertisement?.start()
            return listener
        } catch {
            await dependencies.optional.coordinator?.stop()
            await listener.close()
            throw error
        }
    }

    func cleanUpAbandonedStart(
        listener: (any CoordinatorTransportListener)?
    ) async {
        await dependencies.optional.advertisement?.stop()
        await dependencies.optional.coordinator?.stop()
        await listener?.close()
        await dependencies.transport.stop()
    }

    func requireActiveJoin(_ operationID: UUID) throws {
        guard nodeState == .started, joinOperationID == operationID else {
            throw CancellationError()
        }
    }

    func connectCaller(
        to endpoint: PeerEndpoint,
        invitation: PairingInvitation
    ) async throws
        -> (any CallerTransportSession)?
    {
        guard configuration.roles.contains(.caller) else { return nil }
        return try await dependencies.transport.connectCaller(
            to: endpoint,
            invitation: invitation
        )
    }

    func connectWorker(
        to endpoint: PeerEndpoint,
        invitation: PairingInvitation
    ) async throws
        -> (any WorkerTransportSession)?
    {
        guard configuration.roles.contains(.worker) else { return nil }
        return try await dependencies.transport.connectWorker(
            to: endpoint,
            invitation: invitation
        )
    }

    func makeCallerRequestService(
        session: (any CallerTransportSession)?,
        clusterID: ClusterID
    ) async throws -> CallerRequestService? {
        guard let session else { return nil }
        guard let outbox = dependencies.optional.callerOutbox else {
            throw InferPeerNodeError.callerOutboxUnavailable
        }
        let identity = try await dependencies.identity.localIdentity()
        let service = CallerRequestService(
            session: session,
            outbox: outbox,
            clusterID: clusterID,
            callerID: identity.peerID,
            bufferingLimit: configuration.streamBufferingLimit,
            recoveryLimit: configuration.callerOutboxRecoveryLimit
        )
        try await service.start()
        return service
    }

    func makeWorkerService(
        session: (any WorkerTransportSession)?,
        clusterID: ClusterID
    ) async throws -> WorkerSessionService? {
        guard let session else { return nil }
        guard let backend = dependencies.optional.inferenceBackend else {
            throw InferPeerNodeError.inferenceBackendUnavailable
        }
        let identity = try await dependencies.identity.localIdentity()
        let service = WorkerSessionService(
            configuration: try WorkerSessionConfiguration(
                clusterID: clusterID,
                workerID: identity.peerID,
                streamBufferLimit: configuration.streamBufferingLimit
            ),
            statusProvider: dependencies.status,
            backend: backend
        )
        try await service.start(session: session)
        return service
    }

    func modelServices() throws -> (
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

    func unloadTrackedModel() async {
        guard let loadedModel, let backend = dependencies.optional.inferenceBackend else { return }
        do {
            try await backend.unloadModel(loadedModel)
        } catch {
            // Stop remains best-effort so all network resources are still released.
        }
        self.loadedModel = nil
    }

    func requireStarted() throws {
        guard nodeState == .started else { throw InferPeerNodeError.notStarted }
    }

    func requireRole(_ role: NodeRole) throws {
        guard configuration.roles.contains(role) else {
            throw InferPeerNodeError.roleNotEnabled(role)
        }
    }

    func requireJoiningRole() throws {
        guard configuration.roles.contains(.caller) || configuration.roles.contains(.worker) else {
            throw InferPeerNodeError.roleNotEnabled(.caller)
        }
    }

    func requireCallerRequests() throws -> CallerRequestService {
        guard joinedSessions?.caller != nil else {
            throw InferPeerNodeError.callerSessionUnavailable
        }
        guard let callerRequests else { throw InferPeerNodeError.callerOutboxUnavailable }
        return callerRequests
    }
}
