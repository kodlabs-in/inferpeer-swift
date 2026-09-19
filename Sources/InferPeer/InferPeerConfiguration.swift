import InferPeerCore
import InferPeerInference
import InferPeerModelStore

/// Host-provided identity and inventory for the in-process resource.
public struct LocalResourceConfiguration: Sendable {
    /// User-facing name supplied by the host app.
    public let displayName: String

    /// Platform and hardware identity supplied by the host app.
    public let platform: PlatformDescriptor

    /// Initial truthful telemetry snapshot.
    public let telemetry: TelemetrySnapshot

    /// Creates the local resource's host-owned description.
    public init(
        displayName: String,
        platform: PlatformDescriptor,
        telemetry: TelemetrySnapshot = .init()
    ) {
        self.displayName = displayName
        self.platform = platform
        self.telemetry = telemetry
    }
}

/// Explicit dependencies for one direct-resource facade instance.
public struct InferPeerConfiguration: Sendable {
    #if os(macOS)
        /// Default five-minute Mac warm-model retention.
        public static let defaultLocalModelIdleTimeout: Duration = .seconds(300)
    #else
        /// Default two-minute mobile warm-model retention.
        public static let defaultLocalModelIdleTimeout: Duration = .seconds(120)
    #endif

    /// Host-owned local resource description.
    public let localResource: LocalResourceConfiguration

    /// Optional in-process runtime. `nil` keeps local execution unavailable.
    public let localRuntime: (any InferenceBackend)?

    /// Optional v2 runtime supporting one or more explicitly registered task modalities.
    public let directRuntime: (any DirectInferenceRuntime)?

    /// Verified model artifacts registered for in-process execution.
    public let localModels: [LocalModelArtifact]

    /// Exact model resolved for text queries that request the task default.
    public let defaultTextModel: ModelKey?

    /// Truthful task support for each registered local model.
    public let localModelTasks: [ModelKey: Set<InferenceTask>]

    /// Exact per-task defaults resolved before admission.
    public let defaultModels: [InferenceTask: ModelKey]

    /// Maximum local runs waiting behind the active heavy operation.
    public let maximumPendingLocalRuns: Int

    /// Maximum unconsumed events retained for each run.
    public let runEventBufferLimit: Int

    /// Bounded interval for retaining an idle local heavyweight model.
    public let localModelIdleTimeout: Duration

    /// Optional current OS/process memory admission input supplied by the host integration.
    public let memoryAvailability: (any MemoryAvailabilityProvider)?

    /// Independent upper bound for explicit model preparation.
    public let modelPreparationTimeout: Duration

    /// Optional stopped direct-resource browser supplied by the host.
    public let discovery: (any ResourceDiscovery)?

    /// Optional stopped authenticated listener and advertiser supplied by the host.
    public let exposure: (any ResourceExposure)?

    /// Optional authenticated remote-session manager supplied by the host.
    public let sessionManager: (any ResourceSessionManaging)?

    /// Optional package-owned catalog, installation, and adapter lifecycle.
    public let modelStore: InferPeerModelStore?

    /// Verified package-managed artifacts exposed by this facade instance.
    public let modelStoreModels: [InstalledModel]

    /// Actual device facts used when loading package-managed artifacts.
    public let modelStoreDeviceProfile: ModelStoreDeviceProfile?

    /// Creates an explicit dependency graph without opening sockets or loading models.
    public init(
        localResource: LocalResourceConfiguration,
        localRuntime: (any InferenceBackend)? = nil,
        directRuntime: (any DirectInferenceRuntime)? = nil,
        localModels: [LocalModelArtifact] = [],
        defaultTextModel: ModelKey? = nil,
        localModelTasks: [ModelKey: Set<InferenceTask>] = [:],
        defaultModels: [InferenceTask: ModelKey] = [:],
        maximumPendingLocalRuns: Int = 4,
        runEventBufferLimit: Int = 64,
        localModelIdleTimeout: Duration = InferPeerConfiguration.defaultLocalModelIdleTimeout,
        memoryAvailability: (any MemoryAvailabilityProvider)? = nil,
        modelPreparationTimeout: Duration = .seconds(120),
        discovery: (any ResourceDiscovery)? = nil,
        exposure: (any ResourceExposure)? = nil,
        sessionManager: (any ResourceSessionManaging)? = nil,
        modelStore: InferPeerModelStore? = nil,
        modelStoreModels: [InstalledModel] = [],
        modelStoreDeviceProfile: ModelStoreDeviceProfile? = nil
    ) {
        self.localResource = localResource
        self.localRuntime = localRuntime
        self.directRuntime = directRuntime
        self.localModels = localModels
        self.defaultTextModel = defaultTextModel
        let configuredTasks = Self.resolvedModelTasks(
            localModelTasks,
            models: localModels,
            hasLegacyTextRuntime: localRuntime != nil
        )
        self.localModelTasks = Self.merging(
            configuredTasks,
            with: modelStoreModels
        )
        self.defaultModels = Self.resolvedDefaults(
            defaultModels,
            defaultTextModel: defaultTextModel
        )
        self.maximumPendingLocalRuns = maximumPendingLocalRuns
        self.runEventBufferLimit = runEventBufferLimit
        self.localModelIdleTimeout = localModelIdleTimeout
        self.memoryAvailability = memoryAvailability
        self.modelPreparationTimeout = modelPreparationTimeout
        self.discovery = discovery
        self.exposure = exposure
        self.sessionManager = sessionManager
        self.modelStore = modelStore
        self.modelStoreModels = modelStoreModels
        self.modelStoreDeviceProfile = modelStoreDeviceProfile
    }

    private static func resolvedModelTasks(
        _ configured: [ModelKey: Set<InferenceTask>],
        models: [LocalModelArtifact],
        hasLegacyTextRuntime: Bool
    ) -> [ModelKey: Set<InferenceTask>] {
        guard configured.isEmpty, hasLegacyTextRuntime else { return configured }
        return Dictionary(
            uniqueKeysWithValues: models.map {
                ($0.descriptor.reference, Set([InferenceTask.textGeneration]))
            }
        )
    }

    private static func resolvedDefaults(
        _ configured: [InferenceTask: ModelKey],
        defaultTextModel: ModelKey?
    ) -> [InferenceTask: ModelKey] {
        var defaults = configured
        if let defaultTextModel {
            defaults[.textGeneration] = defaultTextModel
        }
        return defaults
    }

    private static func merging(
        _ configured: [ModelKey: Set<InferenceTask>],
        with installedModels: [InstalledModel]
    ) -> [ModelKey: Set<InferenceTask>] {
        var result = configured
        for model in installedModels {
            result[model.key] = Set(model.manifest.capabilities.map(\.task))
        }
        return result
    }
}
