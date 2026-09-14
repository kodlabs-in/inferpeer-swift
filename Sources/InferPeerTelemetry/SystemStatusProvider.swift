import Foundation
import InferPeerCore

/// Invalid host-controlled status state rejected by the telemetry adapter.
public enum StatusProviderError: Error, Equatable, Sendable {
    /// Generation capacity was zero.
    case invalidGenerationCapacity

    /// Active work exceeded the configured generation capacity.
    case activeGenerationsExceedCapacity
}

/// Host-owned status controls used by the package facade.
public protocol WorkerStatusControlling: StatusProvider {
    /// Changes whether the host accepts new inference work.
    func setParticipation(_ participation: WorkerParticipationState) async

    /// Changes active generation count after validating it against capacity.
    func setActiveGenerations(_ count: UInt32) async throws

    /// Replaces registered model status.
    func setModels(_ models: [WorkerModelSnapshot]) async

    /// Publishes current platform state after lifecycle changes.
    func refresh() async
}

/// Host-controlled status provider backed by current Apple-platform measurements.
public actor SystemStatusProvider: WorkerStatusControlling {
    private let sampler: any WorkerStatusSampling
    private let generationCapacity: UInt32
    private var participation: WorkerParticipationState
    private var activeGenerations: UInt32
    private var models: [WorkerModelSnapshot]
    private let broadcaster = StreamBroadcaster<LocalWorkerStatus>()

    /// Creates a provider with explicit host participation and generation capacity.
    public init(
        participation: WorkerParticipationState = .unavailable,
        generationCapacity: UInt32 = 1,
        activeGenerations: UInt32 = 0,
        models: [WorkerModelSnapshot] = [],
        sampler: any WorkerStatusSampling = SystemWorkerStatusSampler()
    ) throws {
        guard generationCapacity > 0 else {
            throw StatusProviderError.invalidGenerationCapacity
        }
        guard activeGenerations <= generationCapacity else {
            throw StatusProviderError.activeGenerationsExceedCapacity
        }
        self.participation = participation
        self.generationCapacity = generationCapacity
        self.activeGenerations = activeGenerations
        self.models = models
        self.sampler = sampler
    }

    /// Samples the platform and combines it with the latest host-owned state.
    public func currentStatus() async -> LocalWorkerStatus {
        let measurements = await sampler.sample()
        return makeStatus(measurements: measurements)
    }

    /// Returns a bounded newest-first snapshot stream; invalid capacities finish immediately.
    nonisolated public func updates(bufferingLimit: Int) -> WorkerStatusStream {
        guard bufferingLimit > 0 else { return WorkerStatusStream { $0.finish() } }
        let identifier = UUID()
        let broadcaster = self.broadcaster
        let pair = WorkerStatusStream.makeStream(
            bufferingPolicy: .bufferingNewest(bufferingLimit)
        )
        broadcaster.add(pair.continuation, identifier: identifier)
        pair.continuation.onTermination = { _ in
            broadcaster.remove(identifier: identifier)
        }
        return pair.stream
    }

    /// Changes whether the host accepts work and publishes a fresh snapshot.
    public func setParticipation(_ participation: WorkerParticipationState) async {
        self.participation = participation
        await publishCurrentStatus()
    }

    /// Changes active generation count after validating it against capacity.
    public func setActiveGenerations(_ count: UInt32) async throws {
        guard count <= generationCapacity else {
            throw StatusProviderError.activeGenerationsExceedCapacity
        }
        activeGenerations = count
        await publishCurrentStatus()
    }

    /// Replaces registered model status and publishes a fresh snapshot.
    public func setModels(_ models: [WorkerModelSnapshot]) async {
        self.models = models
        await publishCurrentStatus()
    }

    /// Publishes current platform state after an app lifecycle or system notification.
    public func refresh() async {
        await publishCurrentStatus()
    }

    private func makeStatus(measurements: PlatformWorkerMeasurements) -> LocalWorkerStatus {
        let condition = WorkerCondition(
            participation: participation,
            thermalState: measurements.thermalState,
            lowPowerModeEnabled: measurements.lowPowerModeEnabled
        )
        let load = WorkerLoad(
            activeGenerations: activeGenerations,
            generationCapacity: generationCapacity,
            availableAppMemoryBytes: measurements.availableAppMemoryBytes
        )
        return LocalWorkerStatus(
            condition: condition,
            load: load,
            batteryPercentage: measurements.batteryPercentage,
            models: models
        )
    }

    private func publishCurrentStatus() async {
        guard !broadcaster.isEmpty else { return }
        let status = await currentStatus()
        broadcaster.yield(status)
    }
}
