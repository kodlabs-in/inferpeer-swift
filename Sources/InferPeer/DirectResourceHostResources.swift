import InferPeerCore
import InferPeerGRPC
import InferPeerProtocol

extension DirectResourceHostHandler {
    func currentSnapshot() async throws -> ResourceSnapshot {
        let models = try await modelSummaries()
        updateResourceRevision(for: models)
        let tasks = Set(models.flatMap(\.supportedTasks))
        return ResourceSnapshot(
            id: resourceID,
            displayName: displayName,
            platform: platform,
            connection: .connected,
            execution: tasks.isEmpty ? .unavailable : .available,
            capabilities: CapabilitySnapshot(supportedTasks: tasks),
            models: models,
            telemetry: telemetry,
            revision: resourceRevision
        )
    }

    func publishResourceUpdates(
        after knownRevision: UInt64,
        to continuation: DirectRPCStream<InferPeer_V2_WatchResourceResponse>.Continuation
    ) async {
        var deliveredRevision = knownRevision
        do {
            while !Task.isCancelled {
                let snapshot = try await currentSnapshot()
                deliveredRevision = publish(snapshot, after: deliveredRevision, to: continuation)
                try await Task.sleep(for: resourceHeartbeatInterval)
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.publicError(error))
        }
    }

    private func modelSummaries() async throws -> [ModelSummary] {
        var summaries: [ModelSummary] = []
        for model in try await store.installedModels() {
            let tasks = Set(model.manifest.capabilities.map(\.task))
                .intersection(Self.supportedTasks)
            guard !tasks.isEmpty else { continue }
            let status = try await store.status(of: model.key)
            summaries.append(
                ModelSummary(
                    key: model.key,
                    readiness: status?.isLoaded == true ? .ready : .registered,
                    supportedTasks: tasks
                )
            )
        }
        return summaries.sorted { $0.key.modelID.rawValue < $1.key.modelID.rawValue }
    }

    private func updateResourceRevision(for models: [ModelSummary]) {
        defer { advertisedModels = models }
        guard let advertisedModels, advertisedModels != models else { return }
        resourceRevision &+= 1
    }

    private func publish(
        _ snapshot: ResourceSnapshot,
        after deliveredRevision: UInt64,
        to continuation: DirectRPCStream<InferPeer_V2_WatchResourceResponse>.Continuation
    ) -> UInt64 {
        guard deliveredRevision < snapshot.revision else {
            continuation.yield(Self.resourceHeartbeat(snapshot.revision))
            return deliveredRevision
        }
        continuation.yield(Self.resourceUpdate(snapshot))
        return snapshot.revision
    }

    private static func resourceUpdate(
        _ snapshot: ResourceSnapshot
    ) -> InferPeer_V2_WatchResourceResponse {
        InferPeer_V2_WatchResourceResponse.with {
            $0.snapshot = DirectWireMapper.wireResource(snapshot)
        }
    }

    private static func resourceHeartbeat(
        _ revision: UInt64
    ) -> InferPeer_V2_WatchResourceResponse {
        InferPeer_V2_WatchResourceResponse.with { $0.heartbeatRevision = revision }
    }
}
