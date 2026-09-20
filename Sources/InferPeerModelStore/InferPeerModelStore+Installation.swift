import Foundation
import InferPeerCore
import InferPeerInference

typealias ModelInstallationContinuation =
    AsyncThrowingStream<ModelInstallationEvent, any Error>.Continuation

extension InferPeerModelStore {
    /// Starts or resumes package-owned installation and returns byte/file progress.
    public func install(
        _ key: ModelCatalogKey,
        task: InferenceTask,
        on device: ModelStoreDeviceProfile,
        authorization: ModelDownloadAuthorization
    ) async throws -> ModelInstallation {
        let entry = try entry(for: key)
        try authorize(entry, device: device, authorization: authorization)
        let support = await evaluator.support(for: entry, task: task, on: device)
        try await recordCompatibility(entry: entry, support: support)
        guard support.isInstallable else {
            throw InferPeerModelStoreError.incompatible(support)
        }
        if let installed = try await exactInstallation(for: entry) {
            return Self.completedInstallation(installed)
        }
        guard !activeEntries.contains(key) else {
            throw InferPeerModelStoreError.downloadAlreadyRunning(key)
        }
        return startInstallation(entry)
    }

    /// Pauses one active job. Durable partial files are retained for the next install call.
    public func pause(jobID: UUID) {
        activeJobs[jobID]?.cancel()
    }

    private func startInstallation(_ entry: ModelCatalogEntry) -> ModelInstallation {
        let jobID = UUID()
        let pair = AsyncThrowingStream<ModelInstallationEvent, any Error>.makeStream()
        activeEntries.insert(entry.metadata.key)
        let worker = Task {
            await self.runInstallation(
                jobID: jobID,
                entry: entry,
                continuation: pair.continuation
            )
        }
        activeJobs[jobID] = worker
        return ModelInstallation(jobID: jobID, events: pair.stream)
    }

    func recordCompatibility(
        entry: ModelCatalogEntry,
        support: ModelSupport
    ) async throws {
        let runtimeID = RuntimeID(rawValue: entry.manifest.runtime.runtimeIdentifier)
        let versions = await adapters.registeredRuntimes()
        guard let adapterVersion = versions[runtimeID] else { return }
        try await registry.recordCompatibility(
            entry: entry,
            adapterVersion: adapterVersion,
            support: support
        )
    }

    private func runInstallation(
        jobID: UUID,
        entry: ModelCatalogEntry,
        continuation: ModelInstallationContinuation
    ) async {
        do {
            let installed = try await performInstallation(
                jobID: jobID,
                entry: entry,
                continuation: continuation
            )
            continuation.yield(.installed(installed))
            continuation.finish()
        } catch is CancellationError {
            try? await transition(.paused, jobID: jobID, entry: entry, completed: 0)
            continuation.yield(.state(.paused))
            continuation.finish()
        } catch {
            try? await transition(.failed, jobID: jobID, entry: entry, completed: 0)
            continuation.finish(throwing: error)
        }
        activeJobs.removeValue(forKey: jobID)
        activeEntries.remove(entry.metadata.key)
    }

    private func performInstallation(
        jobID: UUID,
        entry: ModelCatalogEntry,
        continuation: ModelInstallationContinuation
    ) async throws -> InstalledModel {
        try await transition(.queued, jobID: jobID, entry: entry, completed: 0)
        continuation.yield(.state(.queued))
        let versionRoot = try prepareVersionRoot(for: entry.metadata.key)
        let staging = try layout.downloadStaging(for: entry.metadata.key)
        try prepareDownloadStaging(staging)
        try await transition(.downloading, jobID: jobID, entry: entry, completed: 0)
        continuation.yield(.state(.downloading))
        try await download(entry, to: staging, jobID: jobID, continuation: continuation)
        try await transition(
            .verifying,
            jobID: jobID,
            entry: entry,
            completed: entry.approximateDownloadBytes
        )
        continuation.yield(.state(.verifying))
        let installed = try await register(entry, staging: staging, installRoot: versionRoot)
        try await registry.recordInstallation(installed, entry: entry)
        try await transition(
            .installed,
            jobID: jobID,
            entry: entry,
            completed: entry.approximateDownloadBytes
        )
        return installed
    }

    func transition(
        _ state: ModelInstallationState,
        jobID: UUID,
        entry: ModelCatalogEntry,
        completed: UInt64
    ) async throws {
        try await registry.recordJob(
            ModelDownloadJobRecord(
                id: jobID,
                key: entry.metadata.key,
                state: state,
                completedBytes: completed,
                totalBytes: entry.approximateDownloadBytes,
                updatedAt: Date()
            )
        )
    }
}
