import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerStorage

extension InferPeerModelStore {
    /// Lists verified installed models in stable order.
    public func installedModels() async throws -> [InstalledModel] {
        try await registry.installedModels()
    }

    /// Returns durable and process-local lifecycle state for an exact model.
    public func status(of key: ModelKey) async throws -> InstalledModelStatus? {
        guard let state = try await registry.installationState(for: key) else { return nil }
        let loaded = sessions[key] != nil
        let removableState = state == .installed || state == .ready
        return InstalledModelStatus(
            key: key,
            state: state,
            isLoaded: loaded,
            isSafeToRemove: removableState && !loaded
        )
    }

    /// Loads an installed artifact through its registered adapter after a fresh compatibility check.
    public func load(
        _ key: ModelKey,
        on device: ModelStoreDeviceProfile,
        configuration: ModelLoadConfiguration = .init()
    ) async throws {
        guard sessions[key] == nil else {
            throw InferPeerModelStoreError.modelAlreadyLoaded(key)
        }
        try reserveLifecycleOperation(for: key)
        defer { activeModelLifecycleOperations.remove(key) }
        guard let model = try await installedModel(key) else {
            throw InferPeerModelStoreError.modelNotInstalled(key)
        }
        let runtimeID = RuntimeID(rawValue: model.manifest.runtime.runtimeIdentifier)
        guard let adapter = await adapters.adapter(for: runtimeID) else {
            throw InferPeerModelStoreError.incompatible(
                .unsupported(reasons: [.adapterUnavailable(runtimeID)])
            )
        }
        let support = try await supportForLoad(model, adapter: adapter, device: device)
        guard support.isInstallable else {
            throw InferPeerModelStoreError.incompatible(support)
        }
        try await load(model, with: adapter, configuration: configuration)
    }

    /// Runs a request through an explicitly loaded model session.
    public func run(_ request: InferenceQuery, using key: ModelKey) throws
        -> DirectRuntimeEventStream
    {
        guard !activeModelLifecycleOperations.contains(key) else {
            throw InferPeerModelStoreError.modelInUse(key)
        }
        guard let session = sessions[key] else {
            throw InferPeerModelStoreError.modelNotLoaded(key)
        }
        guard session.capabilities.contains(request.task) else {
            throw InferPeerModelStoreError.taskUnsupportedForLoadedSession(request.task)
        }
        if case .exact(let requested) = request.modelSelection, requested != key {
            throw InferPeerModelStoreError.requestModelMismatch
        }
        return session.run(request)
    }

    /// Unloads one active model session.
    public func unload(_ key: ModelKey) async throws {
        try reserveLifecycleOperation(for: key)
        defer { activeModelLifecycleOperations.remove(key) }
        guard let session = sessions[key] else {
            throw InferPeerModelStoreError.modelNotLoaded(key)
        }
        await session.unload()
        sessions.removeValue(forKey: key)
        try await registry.updateInstallationState(.installed, key: key)
    }

    /// Removes only package-managed bytes and refuses active sessions by default.
    public func remove(
        _ key: ModelKey,
        policy: ModelRemovalPolicy = .refuseIfLoaded
    ) async throws {
        try reserveLifecycleOperation(for: key)
        defer { activeModelLifecycleOperations.remove(key) }
        try await unloadForRemoval(key, policy: policy)
        guard let installed = try await installedModel(key) else {
            throw InferPeerModelStoreError.modelNotInstalled(key)
        }
        try await registry.updateInstallationState(.removing, key: key)
        do {
            try Self.removeManagedDirectory(
                installed.directoryURL,
                inside: layout.installedDirectory
            )
            try await manifestStore.remove(key: key)
            try await registry.removeInstallation(key: key)
        } catch {
            try? await registry.updateInstallationState(.corrupt, key: key)
            throw error
        }
    }

    func reconcileInstallations() async throws {
        let verifier = ModelManifestVerifier()
        for model in try await registry.reconcilableModels() {
            do {
                let verified = try verifier.verify(model.manifest, in: model.directoryURL)
                guard verified.key == model.key else {
                    try await registry.updateInstallationState(.corrupt, key: model.key)
                    continue
                }
                try await registry.updateInstallationState(.installed, key: model.key)
            } catch {
                try await registry.updateInstallationState(.corrupt, key: model.key)
            }
        }
    }

    private func load(
        _ model: InstalledModel,
        with adapter: any InferPeerRuntimeAdapter,
        configuration: ModelLoadConfiguration
    ) async throws {
        try await registry.updateInstallationState(.loading, key: model.key)
        do {
            let session = try await adapter.load(model: model, configuration: configuration)
            guard session.modelKey == model.key else {
                await session.unload()
                throw InferPeerModelStoreError.adapterReturnedWrongModel(
                    expected: model.key,
                    actual: session.modelKey
                )
            }
            try await registry.updateInstallationState(.ready, key: model.key)
            sessions[model.key] = session
        } catch {
            try? await registry.updateInstallationState(.installed, key: model.key)
            throw error
        }
    }

    private func supportForLoad(
        _ model: InstalledModel,
        adapter: any InferPeerRuntimeAdapter,
        device: ModelStoreDeviceProfile
    ) async throws -> ModelSupport {
        guard let entry = try await registry.catalogEntry(for: model.key),
            let task = entry.manifest.capabilities.first?.task
        else {
            return await adapter.support(for: model.manifest, on: device)
        }
        let support = await evaluator.support(for: entry, task: task, on: device)
        try await recordCompatibility(entry: entry, support: support)
        return support
    }

    private func installedModel(_ key: ModelKey) async throws -> InstalledModel? {
        try await registry.installedModels().first(where: { $0.key == key })
    }

    private func unloadForRemoval(_ key: ModelKey, policy: ModelRemovalPolicy) async throws {
        guard let session = sessions[key] else { return }
        guard policy == .unloadAndRemove else {
            throw InferPeerModelStoreError.modelInUse(key)
        }
        await session.unload()
        sessions.removeValue(forKey: key)
    }

    private func reserveLifecycleOperation(for key: ModelKey) throws {
        guard activeModelLifecycleOperations.insert(key).inserted else {
            throw InferPeerModelStoreError.modelInUse(key)
        }
    }

    private static func removeManagedDirectory(_ url: URL, inside root: URL) throws {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path + "/"
        guard path.hasPrefix(rootPath), path != root.standardizedFileURL.path else {
            throw InferPeerModelStoreError.fileSystemFailure
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw InferPeerModelStoreError.fileSystemFailure
        }
    }
}
