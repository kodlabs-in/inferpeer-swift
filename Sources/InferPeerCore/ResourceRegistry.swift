import Foundation
import InferPeerInference

/// Actor that owns resource revisions and immutable snapshots.
public actor ResourceRegistry {
    private struct Observer {
        let filter: ResourceFilter
        let continuation: ResourceUpdates.Continuation
    }

    private var snapshotsByID: [ResourceID: ResourceSnapshot]
    private var observers: [UUID: Observer] = [:]

    /// Creates a registry from initial immutable snapshots.
    public init(initialSnapshots: [ResourceSnapshot] = []) {
        snapshotsByID = Dictionary(
            initialSnapshots.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    /// Applies only a newer snapshot for a resource.
    public func apply(_ snapshot: ResourceSnapshot) {
        guard snapshot.revision > (snapshotsByID[snapshot.id]?.revision ?? 0) else { return }
        snapshotsByID[snapshot.id] = snapshot
        publishUpdates()
    }

    /// Removes a remembered remote resource. The local resource is permanent.
    public func remove(_ resourceID: ResourceID) {
        guard resourceID != .local else { return }
        guard snapshotsByID.removeValue(forKey: resourceID) != nil else { return }
        publishUpdates()
    }

    /// Returns a deterministic current snapshot list.
    public func snapshots(_ filter: ResourceFilter) -> [ResourceSnapshot] {
        snapshotsByID.values
            .filter { filter.includes($0) }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// Observes the current list immediately and the latest list after each accepted change.
    public func updates(_ filter: ResourceFilter) -> ResourceUpdates {
        let observerID = UUID()
        let pair = ResourceUpdates.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[observerID] = Observer(filter: filter, continuation: pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(observerID) }
        }
        pair.continuation.yield(snapshots(filter))
        return pair.stream
    }

    /// Updates the permanent local resource while preserving its immutable identity fields.
    package func updateLocal(
        execution: ExecutionAvailability,
        model: ModelKey? = nil,
        readiness: ModelReadiness? = nil
    ) {
        guard let current = snapshotsByID[.local] else { return }
        let models = current.models.map { summary in
            guard summary.key == model, let readiness else { return summary }
            return ModelSummary(
                key: summary.key,
                readiness: readiness,
                supportedTasks: summary.supportedTasks
            )
        }
        apply(replacing(current, execution: execution, models: models))
    }

    /// Replaces the package-managed local inventory after a verified install or removal.
    package func replaceLocalModels(_ models: [ModelSummary]) {
        guard let current = snapshotsByID[.local] else { return }
        let tasks = Set(models.flatMap(\.supportedTasks))
        let execution: ExecutionAvailability = tasks.isEmpty ? .unavailable : .available
        apply(
            replacing(
                current,
                execution: execution,
                capabilities: CapabilitySnapshot(supportedTasks: tasks),
                models: models
            )
        )
    }

    /// Changes only the connection and admission state of one remembered remote resource.
    package func updateRemoteConnection(
        _ connection: ConnectionState,
        resourceID: ResourceID
    ) {
        guard resourceID != .local, let current = snapshotsByID[resourceID] else { return }
        let execution = connection == .connected ? current.execution : .unavailable
        apply(replacing(current, connection: connection, execution: execution))
    }

    private func replacing(
        _ current: ResourceSnapshot,
        connection: ConnectionState? = nil,
        execution: ExecutionAvailability,
        capabilities: CapabilitySnapshot? = nil,
        models: [ModelSummary]? = nil
    ) -> ResourceSnapshot {
        ResourceSnapshot(
            id: current.id,
            displayName: current.displayName,
            platform: current.platform,
            connection: connection ?? current.connection,
            execution: execution,
            capabilities: capabilities ?? current.capabilities,
            models: models ?? current.models,
            telemetry: current.telemetry,
            revision: current.revision + 1
        )
    }

    private func publishUpdates() {
        for observer in observers.values {
            observer.continuation.yield(snapshots(observer.filter))
        }
    }

    private func removeObserver(_ observerID: UUID) {
        observers.removeValue(forKey: observerID)
    }
}

private extension ResourceFilter {
    func includes(_ snapshot: ResourceSnapshot) -> Bool {
        switch self {
        case .connected:
            snapshot.id == .local || snapshot.connection == .connected
        case .known:
            true
        }
    }
}
