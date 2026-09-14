import Darwin
import Foundation
import InferPeerCore
#if canImport(UIKit)
    import UIKit
#endif

/// Platform-owned worker signals captured at one point in time.
public struct PlatformWorkerMeasurements: Equatable, Sendable {
    /// The current portable thermal classification.
    public let thermalState: WorkerThermalState

    /// Whether the platform reports low-power mode, or `nil` when unavailable.
    public let lowPowerModeEnabled: Bool?

    /// Memory currently available to this process, or `nil` when unavailable.
    public let availableAppMemoryBytes: UInt64?

    /// Whole-number battery charge, or `nil` when unavailable.
    public let batteryPercentage: BatteryPercentage?

    /// Creates a complete set of optional platform measurements.
    public init(
        thermalState: WorkerThermalState,
        lowPowerModeEnabled: Bool?,
        availableAppMemoryBytes: UInt64?,
        batteryPercentage: BatteryPercentage?
    ) {
        self.thermalState = thermalState
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.availableAppMemoryBytes = availableAppMemoryBytes
        self.batteryPercentage = batteryPercentage
    }
}

/// Supplies replaceable platform measurements without observing inference content.
public protocol WorkerStatusSampling: Sendable {
    /// Captures the latest available platform signals.
    func sample() async -> PlatformWorkerMeasurements
}

/// Default Apple-platform thermal, power, memory, and battery sampler.
public struct SystemWorkerStatusSampler: WorkerStatusSampling {
    /// Creates a stateless platform sampler.
    public init() {}

    /// Captures current platform signals and preserves unavailable values as `nil`.
    public func sample() async -> PlatformWorkerMeasurements {
        let processInfo = ProcessInfo.processInfo
        return PlatformWorkerMeasurements(
            thermalState: Self.thermalState(processInfo.thermalState),
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            availableAppMemoryBytes: availableMemory(),
            batteryPercentage: await batteryPercentage()
        )
    }

    private static func thermalState(_ state: ProcessInfo.ThermalState) -> WorkerThermalState {
        switch state {
        case .nominal:
            .nominal
        case .fair:
            .fair
        case .serious:
            .serious
        case .critical:
            .critical
        @unknown default:
            .unknown
        }
    }

    private func batteryPercentage() async -> BatteryPercentage? {
        #if canImport(UIKit)
            return await MainActor.run {
                UIDevice.current.isBatteryMonitoringEnabled = true
                let level = UIDevice.current.batteryLevel
                guard level >= 0 else { return nil }
                let percentage = UInt32((level * 100).rounded())
                return try? BatteryPercentage(min(percentage, BatteryPercentage.maximum))
            }
        #else
            return nil
        #endif
    }

    private func availableMemory() -> UInt64? {
        #if os(iOS)
            UInt64(os_proc_available_memory())
        #else
            nil
        #endif
    }
}
