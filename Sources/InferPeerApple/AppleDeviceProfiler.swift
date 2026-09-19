import Darwin
import Foundation
import InferPeerCore
import InferPeerModelStore

/// One truthful Apple-device sample used for local resources and model selection.
public struct AppleDeviceProfileSnapshot: Sendable {
    /// Exact platform facts available to the current process.
    public let platform: PlatformDescriptor
    /// Resource metrics whose unavailable values remain absent.
    public let telemetry: TelemetrySnapshot
    /// Runtime-relevant features measured from the current process architecture.
    public let chipFeatures: Set<String>
    /// Compatibility facts consumed by `InferPeerModelStore`.
    public let modelStoreProfile: ModelStoreDeviceProfile

    /// Creates a complete immutable device sample.
    public init(
        platform: PlatformDescriptor,
        telemetry: TelemetrySnapshot,
        chipFeatures: Set<String>,
        modelStoreProfile: ModelStoreDeviceProfile
    ) {
        self.platform = platform
        self.telemetry = telemetry
        self.chipFeatures = chipFeatures
        self.modelStoreProfile = modelStoreProfile
    }
}

/// Native device profiler that does not infer missing values from product names.
public struct AppleDeviceProfiler: Sendable {
    private let storageURL: URL

    /// Creates a profiler using the package model-store volume for storage headroom.
    public init(storageURL: URL) {
        self.storageURL = storageURL
    }

    /// Captures the local device without opening a network connection or loading a model.
    public func snapshot(resourceID: ResourceID = .local) throws -> AppleDeviceProfileSnapshot {
        let platform = Self.platform()
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let availableMemory = Self.availableProcessMemory()
        let freeStorage = try availableStorage()
        let features = Self.chipFeatures()
        let telemetry = try Self.telemetry(
            physicalMemory: physicalMemory,
            availableMemory: availableMemory,
            freeStorage: freeStorage
        )
        let profile = ModelStoreDeviceProfile(
            resourceID: resourceID,
            platform: platform,
            tier: Self.tier(for: platform),
            physicalMemoryBytes: physicalMemory,
            availableMemoryBytes: availableMemory,
            freeStorageBytes: freeStorage,
            chipFeatures: features
        )
        return AppleDeviceProfileSnapshot(
            platform: platform,
            telemetry: telemetry,
            chipFeatures: features,
            modelStoreProfile: profile
        )
    }
}

extension AppleDeviceProfiler: MemoryAvailabilityProvider {
    // Protocol requirement is async to support providers that query external telemetry.
    // swiftlint:disable async_without_await
    /// Reports the latest OS process-memory headroom without fabricating a fallback.
    public func safeAdditionalMemoryBytes() async -> UInt64? {
        Self.availableProcessMemory()
    }
    // swiftlint:enable async_without_await
}

private extension AppleDeviceProfiler {
    static func platform() -> PlatformDescriptor {
        let identifier = hardwareIdentifier()
        return PlatformDescriptor(
            operatingSystem: operatingSystem(for: identifier),
            operatingSystemVersion: operatingSystemVersion(),
            hardwareIdentifier: identifier
        )
    }

    static func operatingSystemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static func operatingSystem(for identifier: String?) -> PlatformDescriptor.OperatingSystem {
        #if os(macOS)
            return .macOS
        #else
            return identifier?.hasPrefix("iPad") == true ? .iPadOS : .iOS
        #endif
    }

    static func tier(for platform: PlatformDescriptor) -> ModelDeviceTier {
        switch platform.operatingSystem {
        case .iOS: .iPhone
        case .iPadOS: .iPad
        case .macOS: .mac
        }
    }

    static func chipFeatures() -> Set<String> {
        #if arch(arm64)
            ["apple-silicon", "metal"]
        #else
            []
        #endif
    }

    static func availableProcessMemory() -> UInt64? {
        #if os(iOS)
            let value = os_proc_available_memory()
            return value > 0 ? UInt64(value) : nil
        #else
            return availableSystemMemory()
        #endif
    }

    func availableStorage() throws -> UInt64? {
        let values = try storageURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        guard let value = values.volumeAvailableCapacityForImportantUsage, value >= 0 else {
            return nil
        }
        return UInt64(value)
    }

    static func hardwareIdentifier() -> String? {
        #if os(macOS)
            sysctlString(named: "hw.model")
        #else
            sysctlString(named: "hw.machine")
        #endif
    }

    static func sysctlString(named name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        let utf8 = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: utf8, encoding: .utf8)
    }

    #if os(macOS)
        static func availableSystemMemory() -> UInt64? {
            var statistics = vm_statistics64()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
            )
            let result = withUnsafeMutablePointer(to: &statistics) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            var pageSize: vm_size_t = 0
            guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
            let pages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count)
            let (bytes, overflow) = pages.multipliedReportingOverflow(
                by: UInt64(pageSize)
            )
            return overflow ? nil : bytes
        }
    #endif

    static func telemetry(
        physicalMemory: UInt64,
        availableMemory: UInt64?,
        freeStorage: UInt64?
    ) throws -> TelemetrySnapshot {
        var measurements = [
            ModelStoreDeviceProfile.physicalMemoryMeasurement: try measuredBytes(
                physicalMemory,
                scope: .resource
            )
        ]
        measurements[ModelStoreDeviceProfile.availableMemoryMeasurement] = try memoryMeasurement(
            availableMemory,
            unavailableReason: "Process memory headroom is unavailable"
        )
        measurements[ModelStoreDeviceProfile.freeStorageMeasurement] = try storageMeasurement(
            freeStorage
        )
        measurements["thermalState"] = try thermalMeasurement()
        measurements["lowPowerModeEnabled"] = try measuredNumber(
            ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0,
            unit: "boolean",
            scope: .resource
        )
        return TelemetrySnapshot(measurements: measurements)
    }

    static func memoryMeasurement(
        _ value: UInt64?,
        unavailableReason: String
    ) throws -> TelemetryMeasurement {
        guard let value else {
            return try unavailableBytes(reason: unavailableReason, scope: .process)
        }
        return try measuredBytes(value, scope: .process)
    }

    static func storageMeasurement(_ value: UInt64?) throws -> TelemetryMeasurement {
        guard let value else {
            return try unavailableBytes(
                reason: "Model-store volume capacity is unavailable",
                scope: .resource
            )
        }
        return try measuredBytes(value, scope: .resource)
    }

    static func thermalMeasurement() throws -> TelemetryMeasurement {
        let value: Double
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: value = 0
        case .fair: value = 1
        case .serious: value = 2
        case .critical: value = 3
        @unknown default:
            return try TelemetryMeasurement(
                value: nil,
                unit: "level",
                scope: .resource,
                quality: .unavailable,
                unavailableReason: "Thermal state is unavailable"
            )
        }
        return try measuredNumber(value, unit: "level", scope: .resource)
    }

    static func measuredBytes(
        _ value: UInt64,
        scope: TelemetryScope
    ) throws -> TelemetryMeasurement {
        try measuredNumber(Double(value), unit: "bytes", scope: scope)
    }

    static func unavailableBytes(
        reason: String,
        scope: TelemetryScope
    ) throws -> TelemetryMeasurement {
        try TelemetryMeasurement(
            value: nil,
            unit: "bytes",
            scope: scope,
            quality: .unavailable,
            unavailableReason: reason
        )
    }

    static func measuredNumber(
        _ value: Double,
        unit: String,
        scope: TelemetryScope
    ) throws -> TelemetryMeasurement {
        try TelemetryMeasurement(
            value: value,
            unit: unit,
            scope: scope,
            quality: .measured,
            sampleAge: .zero
        )
    }
}
