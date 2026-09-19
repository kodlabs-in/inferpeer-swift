import InferPeerCore
import InferPeerInference

extension InferPeer {
    static func validate(_ configuration: InferPeerConfiguration) throws {
        try validateDisplayName(configuration.localResource.displayName)
        try validateLimits(configuration)
        let models =
            configuration.localModels.map(\.descriptor.reference)
            + configuration.modelStoreModels.map(\.key)
        try validateUniqueModels(models)
        try validateRuntime(configuration)
        try validateModelStore(configuration)
        try validateModelTasks(configuration.localModelTasks, models: models)
        try validateDefaults(
            configuration.defaultModels,
            modelTasks: configuration.localModelTasks
        )
    }

    private static func validateDisplayName(_ displayName: String) throws {
        guard !displayName.isEmpty else {
            throw InferPeerError(
                code: .invalidRequest,
                message: "The local resource display name cannot be empty",
                isRetryable: false
            )
        }
    }

    private static func validateLimits(_ configuration: InferPeerConfiguration) throws {
        guard configuration.maximumPendingLocalRuns >= 0,
            configuration.runEventBufferLimit > 0,
            configuration.localModelIdleTimeout > .zero,
            configuration.modelPreparationTimeout > .zero
        else {
            throw InferPeerError(
                code: .invalidRequest,
                message: "Run queue and event buffer limits are invalid",
                isRetryable: false
            )
        }
    }

    private static func validateUniqueModels(_ models: [ModelKey]) throws {
        guard Set(models).count == models.count else {
            throw InferPeerError(
                code: .invalidRequest,
                message: "Each local model artifact must have a unique key",
                isRetryable: false
            )
        }
    }

    private static func validateRuntime(_ configuration: InferPeerConfiguration) throws {
        let configuredRuntimeCount = [
            configuration.localRuntime != nil,
            configuration.directRuntime != nil,
            configuration.modelStore != nil
                && configuration.modelStoreDeviceProfile != nil,
        ].filter { $0 }.count
        guard configuredRuntimeCount <= 1 else {
            throw InferPeerError(
                code: .invalidRequest,
                message: "Configure either the legacy text backend or the v2 direct runtime",
                isRetryable: false
            )
        }
    }

    private static func validateModelStore(_ configuration: InferPeerConfiguration) throws {
        guard
            configuration.modelStoreModels.isEmpty
                || (configuration.modelStore != nil
                    && configuration.modelStoreDeviceProfile != nil)
        else {
            throw InferPeerError(
                code: .invalidRequest,
                message: "Package-managed models require a model store and device profile",
                isRetryable: false
            )
        }
    }

    private static func validateModelTasks(
        _ modelTasks: [ModelKey: Set<InferenceTask>],
        models: [ModelKey]
    ) throws {
        let registered = Set(models)
        guard modelTasks.keys.allSatisfy(registered.contains),
            modelTasks.values.allSatisfy({ !$0.isEmpty })
        else {
            throw InferPeerError(
                code: .invalidRequest,
                message: "Local task capabilities must identify registered models",
                isRetryable: false
            )
        }
    }

    private static func validateDefaults(
        _ defaults: [InferenceTask: ModelKey],
        modelTasks: [ModelKey: Set<InferenceTask>]
    ) throws {
        guard defaults.allSatisfy({ task, model in modelTasks[model]?.contains(task) == true })
        else {
            throw InferPeerError(
                code: .invalidRequest,
                message: "Each task default must be supported by its registered model",
                isRetryable: false
            )
        }
    }

    static func localSnapshot(
        _ configuration: InferPeerConfiguration,
        models: [ModelKey: LocalExecutionModel]
    ) -> ResourceSnapshot {
        let runtimeConfigured =
            configuration.directRuntime != nil || configuration.localRuntime != nil
            || (configuration.modelStore != nil
                && configuration.modelStoreDeviceProfile != nil)
        let tasks =
            runtimeConfigured
            ? Set(configuration.localModelTasks.values.flatMap { $0 }) : []
        let executionAvailable = runtimeConfigured && !tasks.isEmpty
        let summaries = models.keys
            .map { key in
                ModelSummary(
                    key: key,
                    readiness: .registered,
                    supportedTasks: runtimeConfigured
                        ? configuration.localModelTasks[key] ?? [] : []
                )
            }
            .sorted { $0.key.modelID.rawValue < $1.key.modelID.rawValue }
        return ResourceSnapshot(
            id: .local,
            displayName: configuration.localResource.displayName,
            platform: configuration.localResource.platform,
            connection: .connected,
            execution: executionAvailable ? .available : .unavailable,
            capabilities: CapabilitySnapshot(supportedTasks: tasks),
            models: summaries,
            telemetry: configuration.localResource.telemetry,
            revision: 1
        )
    }
}
