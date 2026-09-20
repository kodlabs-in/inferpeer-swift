import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerModelStore
import InferPeerProtocol

/// Namespace marker retained for package topology compatibility.
enum InferPeerModule {}

/// Direct-resource facade. Every run stays on the resource selected by the host.
public actor InferPeer {
    struct RunSpecification: Hashable, Sendable {
        let query: InferenceQuery
        let resourceID: ResourceID
        let queuePolicy: RunQueuePolicy
        let missingModelPolicy: MissingModelPolicy
        let disconnectPolicy: RunDisconnectPolicy
    }

    struct AcceptedRun: Sendable {
        let specification: RunSpecification
        let handle: RunHandle
    }

    struct PendingAcceptedRun {
        let id: UUID
        let specification: RunSpecification
        let task: Task<RunHandle, any Error>
    }

    struct PendingStop {
        let id: UUID
        let task: Task<Void, Never>
    }

    let configuration: InferPeerConfiguration
    let resourcesRegistry: ResourceRegistry
    let localExecutor: LocalResourceExecutor?
    private let discoveryController: DiscoveryController?
    private let exposure: (any ResourceExposure)?
    let sessionManager: (any ResourceSessionManaging)?
    /// Package-owned model catalog and lifecycle when configured by the host.
    nonisolated public let modelStore: InferPeerModelStore?
    private var activeExposure: ExposureHandle?
    private var exposureTask: Task<ExposureHandle, any Error>?
    private var exposureGeneration = UUID()
    private var pendingStop: PendingStop?
    var acceptedRuns: [RequestID: AcceptedRun] = [:]
    var pendingAcceptedRuns: [RequestID: PendingAcceptedRun] = [:]

    /// Creates a stopped facade without opening sockets or loading models.
    public init(configuration: InferPeerConfiguration) throws {
        try Self.validate(configuration)
        self.configuration = configuration
        let models = LocalExecutionModel.inventory(configuration)
        let registry = ResourceRegistry(
            initialSnapshots: [Self.localSnapshot(configuration, models: models)]
        )
        resourcesRegistry = registry
        discoveryController = configuration.discovery.map(DiscoveryController.init(provider:))
        exposure = configuration.exposure
        sessionManager = configuration.sessionManager
        modelStore = configuration.modelStore
        let runtime = LocalExecutionRuntimeFactory.make(configuration)
        localExecutor = runtime.map {
            LocalResourceExecutor(
                runtime: $0,
                models: models,
                defaultModels: configuration.defaultModels,
                maximumPendingRuns: configuration.maximumPendingLocalRuns,
                modelIdleTimeout: configuration.localModelIdleTimeout,
                memoryAvailability: configuration.memoryAvailability,
                resourceStateChanged: { execution, model, readiness in
                    await registry.updateLocal(
                        execution: execution,
                        model: model,
                        readiness: readiness
                    )
                }
            )
        }
    }

    /// Returns `.local` plus authenticated remote resource snapshots matching the filter.
    public func resources(_ filter: ResourceFilter = .connected) async -> [ResourceSnapshot] {
        await resourcesRegistry.snapshots(filter)
    }

    /// Observes complete resource snapshots, starting with the current state.
    public func watchResources(_ filter: ResourceFilter = .known) async -> ResourceUpdates {
        await resourcesRegistry.updates(filter)
    }

    /// Refreshes verified package-managed models after an install or removal.
    @discardableResult
    public func reloadInstalledModels() async throws -> [InstalledModel] {
        guard let store = modelStore, let localExecutor else {
            throw InferPeerError(code: .modelUnavailable, isRetryable: false)
        }
        let installed = try await store.installedModels()
        let models = LocalExecutionModel.inventory(
            installed,
            profile: configuration.modelStoreDeviceProfile
        )
        try await localExecutor.replaceModels(
            models,
            defaultModels: configuration.defaultModels
        )
        await resourcesRegistry.replaceLocalModels(
            models.values
                .map {
                    ModelSummary(
                        key: $0.key,
                        readiness: .registered,
                        supportedTasks: $0.tasks
                    )
                }
                .sorted { $0.key.modelID.rawValue < $1.key.modelID.rawValue }
        )
        return installed
    }

    /// Starts or joins the configured direct-resource browser.
    public func discovery(options: DiscoveryOptions = .default) async throws -> DiscoveryHandle {
        guard let discoveryController else {
            throw InferPeerError(
                code: .workerUnavailable,
                message: "Direct-resource discovery is not configured",
                isRetryable: false
            )
        }
        return try await discoveryController.subscribe(options: options)
    }

    /// Binds and optionally advertises this process as a direct resource.
    public func expose(
        _ configuration: ExposureConfiguration = .default
    ) async throws -> ExposureHandle {
        await pendingStop?.task.value
        guard configuration.maximumPairings > 0 else {
            throw InferPeerError(
                code: .invalidRequest,
                message: "Exposure must allow at least one pairing",
                isRetryable: false
            )
        }
        if let activeExposure {
            if await !activeExposure.isStopped() {
                return activeExposure
            }
            self.activeExposure = nil
        }
        guard let exposure else {
            throw InferPeerError(
                code: .resourceUnavailable,
                message: "Direct-resource exposure is not configured",
                isRetryable: false
            )
        }
        if let exposureTask {
            return try await finishExposureStart(
                exposureTask,
                generation: exposureGeneration
            )
        }
        let generation = UUID()
        exposureGeneration = generation
        let task = Task { try await exposure.start(configuration: configuration) }
        exposureTask = task
        return try await finishExposureStart(task, generation: generation)
    }

    /// Pairs one exact remote resource after its session manager authenticates the invitation.
    public func pair(_ invitation: ResourcePairingInvitation) async throws -> ResourceID {
        guard invitation.expiresAt > Date() else {
            throw InferPeerError(
                code: .unauthenticated,
                message: "The pairing invitation has expired",
                isRetryable: false
            )
        }
        guard let sessionManager else {
            throw InferPeerError(
                code: .discoveryUnavailable,
                message: "Direct-resource sessions are not configured",
                isRetryable: false
            )
        }
        let snapshot = try await sessionManager.pair(invitation)
        guard snapshot.id == invitation.resourceID,
            snapshot.id != .local,
            snapshot.connection == .connected
        else {
            throw InferPeerError(
                code: .protocolMismatch,
                message: "The authenticated resource did not match its invitation",
                isRetryable: false
            )
        }
        await resourcesRegistry.apply(snapshot)
        return snapshot.id
    }

    /// Reconnects durable pairings and refreshes their exact model/resource snapshots.
    @discardableResult
    public func reconnectPairedResources() async -> [ResourceSnapshot] {
        guard let sessionManager else { return [] }
        let snapshots = await sessionManager.reconnectPairedResources()
        for snapshot in snapshots { await resourcesRegistry.apply(snapshot) }
        return snapshots
    }

    /// Closes one remote session while retaining the resource as disconnected.
    public func disconnect(_ resourceID: ResourceID) async {
        guard resourceID != .local else { return }
        await sessionManager?.disconnect(resourceID)
        await resourcesRegistry.updateRemoteConnection(.disconnected, resourceID: resourceID)
    }

    /// Revokes and removes one remembered remote resource.
    public func forget(_ resourceID: ResourceID) async throws {
        guard resourceID != .local else {
            throw InferPeerError(
                code: .invalidRequest,
                message: "The local resource cannot be forgotten",
                isRetryable: false
            )
        }
        guard let sessionManager else {
            throw InferPeerError(code: .notPaired, isRetryable: false)
        }
        try await sessionManager.forget(resourceID)
        await resourcesRegistry.remove(resourceID)
    }

    /// Stops local execution and releases a loaded model when no run is active.
    public func stop() async {
        if let pendingStop {
            await pendingStop.task.value
            return
        }
        pendingAcceptedRuns.values.forEach { $0.task.cancel() }
        pendingAcceptedRuns.removeAll(keepingCapacity: false)
        exposureGeneration = UUID()
        let pendingExposure = exposureTask
        exposureTask = nil
        pendingExposure?.cancel()
        let activeExposure = self.activeExposure
        self.activeExposure = nil
        let stopID = UUID()
        let task = Task {
            await discoveryController?.stop()
            if let pendingHandle = try? await pendingExposure?.value {
                await pendingHandle.stop()
            }
            await activeExposure?.stop()
            await sessionManager?.stop()
            await localExecutor?.stop()
        }
        pendingStop = PendingStop(id: stopID, task: task)
        await task.value
        if pendingStop?.id == stopID { pendingStop = nil }
    }

    private func finishExposureStart(
        _ task: Task<ExposureHandle, any Error>,
        generation: UUID
    ) async throws -> ExposureHandle {
        do {
            let handle = try await task.value
            guard exposureGeneration == generation else {
                await handle.stop()
                throw CancellationError()
            }
            exposureTask = nil
            activeExposure = handle
            return handle
        } catch {
            if exposureGeneration == generation {
                exposureTask = nil
            }
            throw error
        }
    }

}
