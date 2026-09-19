import Foundation
import InferPeerCore

/// Injectable acquisition boundary for one complete local resource snapshot.
public protocol DirectResourceSnapshotSampling: Sendable {
    /// Captures current resource metadata and telemetry without starting its own timer.
    func sampleResourceSnapshot() async throws -> ResourceSnapshot
}

/// Publication failures which cannot be represented as a revisioned delta.
public enum DirectResourceTelemetryPublisherError: Error, Equatable, Sendable {
    case revisionExhausted
}

/// Idempotent ownership handle for one bounded resource-publication stream.
public struct DirectResourceTelemetrySubscription: Sendable {
    /// Complete initial snapshot followed by revisioned deltas and heartbeats.
    public let updates: AsyncStream<DirectResourcePublication>

    private let lease: DirectTelemetrySubscriptionLease

    fileprivate init(
        updates: AsyncStream<DirectResourcePublication>,
        cancel: @escaping @Sendable () async -> Void
    ) {
        self.updates = updates
        lease = DirectTelemetrySubscriptionLease(cancel: cancel)
    }

    /// Stops this subscription at most once.
    public func cancel() async {
        await lease.cancel()
    }
}

/// Subscriber-aware resource sampler and revisioned publication owner.
public actor DirectResourceTelemetryPublisher {
    private let sampler: any DirectResourceSnapshotSampling
    private let schedule: DirectPublicationSchedule
    private var activity: DirectResourceActivity
    private var currentSnapshot: ResourceSnapshot?
    private var continuations: [UUID: AsyncStream<DirectResourcePublication>.Continuation] = [:]

    /// Creates a publisher with no polling or background task until a host drives it.
    public init(
        sampler: any DirectResourceSnapshotSampling,
        schedule: DirectPublicationSchedule = .standard,
        activity: DirectResourceActivity = .idle
    ) {
        self.sampler = sampler
        self.schedule = schedule
        self.activity = activity
    }

    /// Registers a bounded observer and immediately replays a complete current snapshot.
    public func subscribe(bufferingLimit: Int) -> DirectResourceTelemetrySubscription {
        guard bufferingLimit > 0 else { return Self.finishedSubscription() }
        let identifier = UUID()
        let pair = AsyncStream.makeStream(
            of: DirectResourcePublication.self,
            bufferingPolicy: .bufferingNewest(bufferingLimit)
        )
        continuations[identifier] = pair.continuation
        if let currentSnapshot {
            pair.continuation.yield(.snapshot(currentSnapshot))
        }
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(identifier) }
        }
        return DirectResourceTelemetrySubscription(updates: pair.stream) { [weak self] in
            await self?.cancelSubscriber(identifier)
        }
    }

    /// Changes the schedule hint without creating a timer.
    public func setActivity(_ activity: DirectResourceActivity) {
        self.activity = activity
    }

    /// Returns `nil` when optional polling must stop because nobody is observing.
    public func nextOptionalSamplingInterval() -> Duration? {
        continuations.isEmpty ? nil : schedule.samplingInterval(for: activity)
    }

    /// Returns `nil` when there is no observer requiring a heartbeat.
    public func nextHeartbeatInterval() -> Duration? {
        continuations.isEmpty ? nil : schedule.heartbeatInterval(for: activity)
    }

    /// Samples only while observed and publishes only a complete initial state or changed state.
    @discardableResult
    public func poll() async throws -> Bool {
        guard !continuations.isEmpty else { return false }
        let candidate = try await sampler.sampleResourceSnapshot()
        return try publish(candidate)
    }

    /// Publishes liveness for the current revision without fabricating new measurements.
    public func publishHeartbeat() {
        guard !continuations.isEmpty, let currentSnapshot else { return }
        broadcast(.heartbeat(resourceID: currentSnapshot.id, revision: currentSnapshot.revision))
    }

    /// Returns the latest complete publication state, if any.
    public func snapshot() -> ResourceSnapshot? {
        currentSnapshot
    }
}

extension DirectResourceTelemetryPublisher {
    private func publish(_ candidate: ResourceSnapshot) throws -> Bool {
        guard let currentSnapshot else {
            let initial = normalized(candidate, revision: max(1, candidate.revision))
            self.currentSnapshot = initial
            broadcast(.snapshot(initial))
            return true
        }
        guard !sameContent(currentSnapshot, candidate) else { return false }
        guard currentSnapshot.revision < .max else {
            throw DirectResourceTelemetryPublisherError.revisionExhausted
        }
        let next = normalized(candidate, revision: currentSnapshot.revision + 1)
        self.currentSnapshot = next
        if next.id == currentSnapshot.id {
            broadcast(
                .delta(
                    DirectResourceDelta(
                        resourceID: next.id,
                        baseRevision: currentSnapshot.revision,
                        revision: next.revision,
                        changedSnapshot: next
                    )))
        } else {
            broadcast(.snapshot(next))
        }
        return true
    }

    private func normalized(_ value: ResourceSnapshot, revision: UInt64) -> ResourceSnapshot {
        ResourceSnapshot(
            id: value.id,
            displayName: value.displayName,
            platform: value.platform,
            connection: value.connection,
            execution: value.execution,
            capabilities: value.capabilities,
            models: value.models,
            telemetry: value.telemetry,
            revision: revision
        )
    }

    private func sameContent(_ lhs: ResourceSnapshot, _ rhs: ResourceSnapshot) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.platform == rhs.platform
            && lhs.connection == rhs.connection
            && lhs.execution == rhs.execution
            && lhs.capabilities == rhs.capabilities
            && lhs.models == rhs.models
            && lhs.telemetry == rhs.telemetry
    }

    private func broadcast(_ publication: DirectResourcePublication) {
        continuations.values.forEach { $0.yield(publication) }
    }

    private func cancelSubscriber(_ identifier: UUID) {
        let continuation = continuations.removeValue(forKey: identifier)
        continuation?.finish()
    }

    private func removeSubscriber(_ identifier: UUID) {
        continuations[identifier] = nil
    }

    private static func finishedSubscription() -> DirectResourceTelemetrySubscription {
        let pair = AsyncStream.makeStream(of: DirectResourcePublication.self)
        pair.continuation.finish()
        return DirectResourceTelemetrySubscription(updates: pair.stream) {}
    }
}

private actor DirectTelemetrySubscriptionLease {
    private var cancelOperation: (@Sendable () async -> Void)?

    init(cancel: @escaping @Sendable () async -> Void) {
        cancelOperation = cancel
    }

    func cancel() async {
        guard let cancelOperation else { return }
        self.cancelOperation = nil
        await cancelOperation()
    }
}
