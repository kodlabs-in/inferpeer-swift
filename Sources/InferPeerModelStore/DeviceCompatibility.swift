import Foundation
import InferPeerCore
import InferPeerInference

/// Coarse form factor used only for recommendation ranking.
public enum ModelDeviceTier: String, Codable, CaseIterable, Hashable, Sendable {
    case iPhone
    case iPad
    case mac
}

/// Actual resource facts used to evaluate models before install and load.
public struct ModelStoreDeviceProfile: Hashable, Sendable {
    /// Telemetry key for installed physical memory in bytes.
    public static let physicalMemoryMeasurement = "physicalMemoryBytes"
    /// Telemetry key for memory currently safe for an additional operation.
    public static let availableMemoryMeasurement = "availableMemoryBytes"
    /// Telemetry key for currently available model storage.
    public static let freeStorageMeasurement = "freeStorageBytes"

    /// Selected local or connected resource.
    public let resourceID: ResourceID
    /// Actual platform facts reported by that resource.
    public let platform: PlatformDescriptor
    /// Form factor used only as a recommendation preference.
    public let tier: ModelDeviceTier
    /// Installed physical memory when measured.
    public let physicalMemoryBytes: UInt64?
    /// Memory currently safe for a new operation when measured.
    public let availableMemoryBytes: UInt64?
    /// Free package storage when measured.
    public let freeStorageBytes: UInt64?
    /// Runtime-relevant chip features reported by the resource.
    public let chipFeatures: Set<String>

    /// Creates a profile from explicit resource measurements.
    public init(
        resourceID: ResourceID,
        platform: PlatformDescriptor,
        tier: ModelDeviceTier,
        physicalMemoryBytes: UInt64? = nil,
        availableMemoryBytes: UInt64? = nil,
        freeStorageBytes: UInt64? = nil,
        chipFeatures: Set<String> = []
    ) {
        self.resourceID = resourceID
        self.platform = platform
        self.tier = tier
        self.physicalMemoryBytes = physicalMemoryBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.freeStorageBytes = freeStorageBytes
        self.chipFeatures = chipFeatures
    }

    /// Builds a profile from a connected resource without fabricating absent telemetry.
    public init(snapshot: ResourceSnapshot, chipFeatures: Set<String> = []) {
        resourceID = snapshot.id
        platform = snapshot.platform
        tier = Self.tier(for: snapshot.platform)
        physicalMemoryBytes = Self.bytes(
            snapshot.telemetry.measurements[Self.physicalMemoryMeasurement]
        )
        availableMemoryBytes = Self.bytes(
            snapshot.telemetry.measurements[Self.availableMemoryMeasurement]
        )
        freeStorageBytes = Self.bytes(
            snapshot.telemetry.measurements[Self.freeStorageMeasurement]
        )
        self.chipFeatures = chipFeatures
    }

    private static func bytes(_ measurement: TelemetryMeasurement?) -> UInt64? {
        guard measurement?.unit == "bytes", let value = measurement?.value,
            value >= 0, value <= Double(UInt64.max)
        else {
            return nil
        }
        return UInt64(value)
    }

    private static func tier(for platform: PlatformDescriptor) -> ModelDeviceTier {
        switch platform.operatingSystem {
        case .iOS:
            return .iPhone
        case .iPadOS:
            return .iPad
        case .macOS:
            return .mac
        }
    }
}

/// Explicit reason why a candidate is not fully supported.
public enum ModelCompatibilityReason: Hashable, Sendable {
    case catalogBlocked
    case catalogNotStable(ModelCatalogStatus)
    case taskUnsupported(InferenceTask)
    case adapterUnavailable(RuntimeID)
    case adapterVersionTooOld(required: String, installed: String)
    case operatingSystemUnsupported(PlatformDescriptor.OperatingSystem)
    case operatingSystemTooOld(required: String, installed: String)
    case deviceFamilyUnsupported(String)
    case chipFeatureMissing(String)
    case physicalMemoryUnknown(required: UInt64)
    case physicalMemoryInsufficient(required: UInt64, available: UInt64)
    case availableMemoryUnknown(required: UInt64)
    case availableMemoryInsufficient(required: UInt64, available: UInt64)
    case storageUnknown(required: UInt64)
    case storageInsufficient(required: UInt64, available: UInt64)
    case notValidatedOnDevice(String?)
    case adapterRejected(String)
}

/// Compatibility is deliberately richer than a Boolean.
public enum ModelSupport: Hashable, Sendable {
    case supported
    case experimental(reasons: [ModelCompatibilityReason])
    case unsupported(reasons: [ModelCompatibilityReason])

    /// Whether installation may proceed without hiding experimental status.
    public var isInstallable: Bool {
        switch self {
        case .supported, .experimental:
            true
        case .unsupported:
            false
        }
    }
}
