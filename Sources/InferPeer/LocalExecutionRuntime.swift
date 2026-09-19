import InferPeerCore
import InferPeerInference
import InferPeerModelStore
import InferPeerProtocol

struct LocalExecutionModel: Sendable {
    let key: ModelKey
    let tasks: Set<InferenceTask>
    let measuredMemoryBytes: UInt64?

    static func inventory(_ configuration: InferPeerConfiguration) -> [ModelKey: Self] {
        let local = configuration.localModels.map { artifact in
            (
                artifact.descriptor.reference,
                Self(
                    key: artifact.descriptor.reference,
                    tasks: configuration.localModelTasks[artifact.descriptor.reference] ?? [],
                    measuredMemoryBytes: artifact.descriptor.measuredMemoryBytes
                )
            )
        }
        let managed = configuration.modelStoreModels.map { model in
            (
                model.key,
                Self(
                    key: model.key,
                    tasks: Set(model.manifest.capabilities.map(\.task)),
                    measuredMemoryBytes: Self.measuredMemory(
                        for: model,
                        profile: configuration.modelStoreDeviceProfile
                    )
                )
            )
        }
        return Dictionary(local + managed, uniquingKeysWith: { first, _ in first })
    }

    static func inventory(
        _ installedModels: [InstalledModel],
        profile: ModelStoreDeviceProfile?
    ) -> [ModelKey: Self] {
        Dictionary(
            uniqueKeysWithValues: installedModels.map { model in
                (
                    model.key,
                    Self(
                        key: model.key,
                        tasks: Set(model.manifest.capabilities.map(\.task)),
                        measuredMemoryBytes: measuredMemory(for: model, profile: profile)
                    )
                )
            }
        )
    }

    private static func measuredMemory(
        for model: InstalledModel,
        profile: ModelStoreDeviceProfile?
    ) -> UInt64? {
        guard let hardware = profile?.platform.hardwareIdentifier else { return nil }
        return model.manifest.deviceProfiles.first {
            $0.deviceClass == hardware
        }?.peakMemoryBytes
    }
}

protocol LocalExecutionRuntime: Sendable {
    func estimateResources(
        for query: InferenceQuery,
        using model: ModelKey
    ) async throws -> InferenceResourceEstimate
    func loadModel(_ model: ModelKey) async throws
    func unloadModel(_ model: ModelKey) async throws
    func execute(_ execution: DirectRuntimeExecution) async throws -> DirectRuntimeEventStream
    func cancel(attemptID: AttemptID) async
}

enum LocalExecutionRuntimeFactory {
    static func make(_ configuration: InferPeerConfiguration) -> (any LocalExecutionRuntime)? {
        if let store = configuration.modelStore,
            let profile = configuration.modelStoreDeviceProfile
        {
            return ModelStoreExecutionRuntime(store: store, profile: profile)
        }
        if let runtime = configuration.directRuntime {
            return DirectLocalExecutionRuntime(
                runtime: runtime,
                artifacts: configuration.localModels
            )
        }
        if let backend = configuration.localRuntime {
            return DirectLocalExecutionRuntime(
                runtime: InferenceBackendDirectRuntime(backend: backend),
                artifacts: configuration.localModels
            )
        }
        return nil
    }
}

private actor DirectLocalExecutionRuntime: LocalExecutionRuntime {
    private let runtime: any DirectInferenceRuntime
    private let artifacts: [ModelKey: LocalModelArtifact]

    init(runtime: any DirectInferenceRuntime, artifacts: [LocalModelArtifact]) {
        self.runtime = runtime
        self.artifacts = Dictionary(
            artifacts.map { ($0.descriptor.reference, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func estimateResources(
        for query: InferenceQuery,
        using model: ModelKey
    ) async throws -> InferenceResourceEstimate {
        guard let artifact = artifacts[model] else {
            throw InferPeerError(code: .modelUnavailable, isRetryable: false)
        }
        return try await runtime.estimateResources(for: query, using: artifact.descriptor)
    }

    func loadModel(_ model: ModelKey) async throws {
        guard let artifact = artifacts[model] else {
            throw InferPeerError(code: .modelUnavailable, isRetryable: false)
        }
        try await runtime.loadModel(artifact)
    }

    func unloadModel(_ model: ModelKey) async throws {
        try await runtime.unloadModel(model)
    }

    func execute(_ execution: DirectRuntimeExecution) async throws -> DirectRuntimeEventStream {
        try await runtime.execute(execution)
    }

    func cancel(attemptID: AttemptID) async {
        await runtime.cancel(attemptID: attemptID)
    }
}

private actor ModelStoreExecutionRuntime: LocalExecutionRuntime {
    private let store: InferPeerModelStore
    private let profile: ModelStoreDeviceProfile

    init(store: InferPeerModelStore, profile: ModelStoreDeviceProfile) {
        self.store = store
        self.profile = profile
    }

    // Async is required by the runtime protocol; this adapter has no estimate I/O.
    // swiftlint:disable async_without_await
    func estimateResources(
        for _: InferenceQuery,
        using _: ModelKey
    ) async throws -> InferenceResourceEstimate {
        try InferenceResourceEstimate()
    }

    func loadModel(_ model: ModelKey) async throws {
        if try await store.status(of: model)?.isLoaded != true {
            try await store.load(model, on: profile)
        }
    }

    func unloadModel(_ model: ModelKey) async throws {
        if try await store.status(of: model)?.isLoaded == true {
            try await store.unload(model)
        }
    }

    func execute(_ execution: DirectRuntimeExecution) async throws -> DirectRuntimeEventStream {
        try await store.run(execution.query, using: execution.model)
    }

    // Cancellation is stream-driven for model-store adapters.
    func cancel(attemptID _: AttemptID) async {}
    // swiftlint:enable async_without_await
}
