import Foundation
import InferPeerInference

/// Stable identity for one directly addressable inference endpoint.
public struct ResourceID: RawRepresentable, Hashable, Sendable {
    /// Reserved identity for the current process's in-process executor.
    public static let local = Self(rawValue: "local")

    /// Stable endpoint identity. Network addresses and display names are not identities.
    public let rawValue: String

    /// Creates a resource identity.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Apple platform information reported by a resource.
public struct PlatformDescriptor: Hashable, Sendable {
    /// Operating-system family.
    public enum OperatingSystem: String, Hashable, Sendable {
        case iOS
        case iPadOS
        case macOS
    }

    /// Operating-system family.
    public let operatingSystem: OperatingSystem

    /// Host-reported operating-system version.
    public let operatingSystemVersion: String

    /// Exact hardware identifier when the host can provide it.
    public let hardwareIdentifier: String?

    /// Creates an immutable platform description.
    public init(
        operatingSystem: OperatingSystem,
        operatingSystemVersion: String,
        hardwareIdentifier: String? = nil
    ) {
        self.operatingSystem = operatingSystem
        self.operatingSystemVersion = operatingSystemVersion
        self.hardwareIdentifier = hardwareIdentifier
    }
}

/// Authentication and transport state for one resource.
public enum ConnectionState: String, Hashable, Sendable {
    case connecting
    case authenticating
    case connected
    case reconnecting
    case disconnected
    case blocked
}

/// Current eligibility to admit inference on one resource.
public enum ExecutionAvailability: String, Hashable, Sendable {
    case available
    case busy
    case pausedByHost
    case thermalLimited
    case memoryLimited
    case backgroundRestricted
    case unavailable
}

/// Current readiness of one exact model artifact.
public enum ModelReadiness: String, Hashable, Sendable {
    case registered
    case preparing
    case ready
    case unloading
    case failed
}

/// Public model information advertised by a resource.
public struct ModelSummary: Hashable, Sendable {
    /// Exact registered artifact identity.
    public let key: ModelKey

    /// Current preparation state.
    public let readiness: ModelReadiness

    /// Tasks this exact artifact supports.
    public let supportedTasks: Set<InferenceTask>

    /// Creates an immutable model summary.
    public init(
        key: ModelKey,
        readiness: ModelReadiness,
        supportedTasks: Set<InferenceTask>
    ) {
        self.key = key
        self.readiness = readiness
        self.supportedTasks = supportedTasks
    }
}

/// Task support advertised by a resource.
public struct CapabilitySnapshot: Hashable, Sendable {
    /// Tasks the resource can currently describe and validate.
    public let supportedTasks: Set<InferenceTask>

    /// Creates a capability snapshot.
    public init(supportedTasks: Set<InferenceTask>) {
        self.supportedTasks = supportedTasks
    }
}

/// Source scope for one telemetry measurement.
public enum TelemetryScope: String, Hashable, Sendable {
    case process
    case resource
    case network
    case runtime
}

/// Confidence and availability of one telemetry measurement.
public enum TelemetryQuality: String, Hashable, Sendable {
    case measured
    case estimated
    case unavailable
}

/// Invalid combinations in a telemetry measurement.
public enum TelemetryMeasurementError: Error, Equatable, Sendable {
    case emptyUnit
    case valueRequired
    case unavailableValuePresent
    case invalidValue
    case negativeSampleAge
}

/// One scoped telemetry value whose absence never becomes a fabricated zero.
public struct TelemetryMeasurement: Hashable, Sendable {
    /// Numeric value when available.
    public let value: Double?

    /// Explicit unit such as `bytes`, `seconds`, or `tokensPerSecond`.
    public let unit: String

    /// Source scope of the measurement.
    public let scope: TelemetryScope

    /// Whether the value is measured, estimated, or unavailable.
    public let quality: TelemetryQuality

    /// Age of the source sample when known.
    public let sampleAge: Duration?

    /// Safe reason for an unavailable value.
    public let unavailableReason: String?

    /// Creates a scoped measurement without substituting for missing data.
    public init(
        value: Double?,
        unit: String,
        scope: TelemetryScope,
        quality: TelemetryQuality,
        sampleAge: Duration? = nil,
        unavailableReason: String? = nil
    ) throws {
        try Self.validateUnit(unit)
        try Self.validateValue(value, quality: quality)
        try Self.validateSampleAge(sampleAge)
        self.value = value
        self.unit = unit
        self.scope = scope
        self.quality = quality
        self.sampleAge = sampleAge
        self.unavailableReason = unavailableReason
    }

    private static func validateUnit(_ unit: String) throws {
        guard !unit.isEmpty else { throw TelemetryMeasurementError.emptyUnit }
    }

    private static func validateValue(
        _ value: Double?,
        quality: TelemetryQuality
    ) throws {
        if quality == .unavailable {
            guard value == nil else {
                throw TelemetryMeasurementError.unavailableValuePresent
            }
            return
        }
        guard let value else { throw TelemetryMeasurementError.valueRequired }
        guard value.isFinite else { throw TelemetryMeasurementError.invalidValue }
    }

    private static func validateSampleAge(_ sampleAge: Duration?) throws {
        if let sampleAge, sampleAge < .zero {
            throw TelemetryMeasurementError.negativeSampleAge
        }
    }
}

/// Telemetry whose unavailable values remain absent rather than becoming zero.
public struct TelemetrySnapshot: Hashable, Sendable {
    /// Host-scoped, named measurements.
    public let measurements: [String: TelemetryMeasurement]

    /// Creates a bounded telemetry snapshot. An empty snapshot means no measurements are known.
    public init(measurements: [String: TelemetryMeasurement] = [:]) {
        self.measurements = measurements
    }
}

/// One immutable view of a directly addressable resource.
public struct ResourceSnapshot: Sendable {
    /// Stable direct-resource identity.
    public let id: ResourceID

    /// Host-provided user-facing name.
    public let displayName: String

    /// Host platform and hardware information.
    public let platform: PlatformDescriptor

    /// Authentication and transport state.
    public let connection: ConnectionState

    /// Current execution admission state.
    public let execution: ExecutionAvailability

    /// Advertised task support.
    public let capabilities: CapabilitySnapshot

    /// Exact registered model artifacts.
    public let models: [ModelSummary]

    /// Current host-scoped telemetry.
    public let telemetry: TelemetrySnapshot

    /// Monotonically increasing resource revision.
    public let revision: UInt64

    /// Receiver-local monotonic receipt time.
    public let receivedAt: ContinuousClock.Instant

    /// Creates one immutable resource snapshot.
    public init(
        id: ResourceID,
        displayName: String,
        platform: PlatformDescriptor,
        connection: ConnectionState,
        execution: ExecutionAvailability,
        capabilities: CapabilitySnapshot,
        models: [ModelSummary],
        telemetry: TelemetrySnapshot = .init(),
        revision: UInt64,
        receivedAt: ContinuousClock.Instant = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.platform = platform
        self.connection = connection
        self.execution = execution
        self.capabilities = capabilities
        self.models = models
        self.telemetry = telemetry
        self.revision = revision
        self.receivedAt = receivedAt
    }
}

/// Which resource snapshots should be returned by the facade.
public enum ResourceFilter: Hashable, Sendable {
    /// Local plus authenticated, connected remote resources.
    case connected

    /// Local, connected, and remembered disconnected resources.
    case known
}

/// A bounded stream of complete immutable resource snapshot lists.
public typealias ResourceUpdates = AsyncStream<[ResourceSnapshot]>

/// Host/OS memory admission input after process budget and safety reserve are applied.
public protocol MemoryAvailabilityProvider: Sendable {
    /// Additional bytes safe for one new operation, or `nil` when unavailable.
    func safeAdditionalMemoryBytes() async -> UInt64?
}
