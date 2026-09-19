import Foundation
import InferPeerCore
import InferPeerInference

/// Stable identity for a replaceable inference engine.
public struct RuntimeID: RawRepresentable, Codable, Hashable, Sendable {
    /// Stable textual identity such as `llama.cpp` or `whisperkit`.
    public let rawValue: String

    /// Creates a runtime identity without loading the runtime.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Adapter-neutral description of a verified installation.
public struct InstalledModel: Sendable {
    /// Exact verified artifact identity.
    public let key: ModelKey
    /// Canonical verified manifest.
    public let manifest: ModelManifest
    /// Package-managed immutable installation directory.
    public let directoryURL: URL
    /// Total declared model bytes.
    public let installedByteCount: UInt64

    /// Creates adapter input from one verified installation.
    public init(
        key: ModelKey,
        manifest: ModelManifest,
        directoryURL: URL,
        installedByteCount: UInt64
    ) {
        self.key = key
        self.manifest = manifest
        self.directoryURL = directoryURL
        self.installedByteCount = installedByteCount
    }
}

/// Host-selected model loading controls that do not expose an engine API.
public struct ModelLoadConfiguration: Hashable, Sendable {
    /// Optional caller-imposed memory ceiling.
    public let maximumWorkingMemoryBytes: UInt64?

    /// Creates bounded loading controls.
    public init(maximumWorkingMemoryBytes: UInt64? = nil) {
        self.maximumWorkingMemoryBytes = maximumWorkingMemoryBytes
    }
}

/// One loaded model session owned by its runtime adapter.
public protocol InferPeerModelSession: Sendable {
    var modelKey: ModelKey { get }
    var capabilities: Set<InferenceTask> { get }

    func run(_ request: InferenceQuery) -> DirectRuntimeEventStream
    func unload() async
}

/// Replaceable bridge from InferPeer requests to one inference runtime.
public protocol InferPeerRuntimeAdapter: Sendable {
    var runtimeID: RuntimeID { get }
    var runtimeVersion: String { get }

    func support(
        for model: ModelManifest,
        on device: ModelStoreDeviceProfile
    ) async -> ModelSupport

    func load(
        model: InstalledModel,
        configuration: ModelLoadConfiguration
    ) async throws -> any InferPeerModelSession
}

/// Unambiguous package-facing spelling for runtime compatibility results.
public typealias InferPeerRuntimeModelSupport = ModelSupport

/// Actor-isolated registry used by compatibility checks and model loading.
public actor RuntimeAdapterRegistry {
    private var adapters: [RuntimeID: any InferPeerRuntimeAdapter] = [:]

    /// Creates a registry and rejects duplicate runtime identities.
    public init(_ adapters: [any InferPeerRuntimeAdapter] = []) throws {
        for adapter in adapters {
            guard self.adapters[adapter.runtimeID] == nil else {
                throw RuntimeAdapterRegistryError.duplicateRuntime(adapter.runtimeID)
            }
            self.adapters[adapter.runtimeID] = adapter
        }
    }

    /// Adds one runtime adapter exactly once.
    public func register(_ adapter: any InferPeerRuntimeAdapter) throws {
        guard adapters[adapter.runtimeID] == nil else {
            throw RuntimeAdapterRegistryError.duplicateRuntime(adapter.runtimeID)
        }
        adapters[adapter.runtimeID] = adapter
    }

    /// Returns the adapter registered for one runtime identity.
    public func adapter(for runtimeID: RuntimeID) -> (any InferPeerRuntimeAdapter)? {
        adapters[runtimeID]
    }

    /// Returns immutable runtime version summaries.
    public func registeredRuntimes() -> [RuntimeID: String] {
        Dictionary(
            uniqueKeysWithValues: adapters.values.map {
                ($0.runtimeID, $0.runtimeVersion)
            })
    }
}

/// Invalid runtime registry mutations.
public enum RuntimeAdapterRegistryError: Error, Equatable, Sendable {
    case duplicateRuntime(RuntimeID)
}
