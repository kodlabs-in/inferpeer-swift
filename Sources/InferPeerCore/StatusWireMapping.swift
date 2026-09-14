import InferPeerInference
import InferPeerProtocol

extension LocalWorkerStatus {
    /// Creates validated local worker status from its protocol representation.
    public init(wireValue: InferPeer_V1_WorkerStatus) throws {
        let condition = try WorkerCondition(wireValue: wireValue)
        let load = WorkerLoad(wireValue: wireValue)
        let batteryPercentage =
            try wireValue.hasBatteryPercent
            ? BatteryPercentage(wireValue.batteryPercent)
            : nil
        self.init(
            condition: condition,
            load: load,
            batteryPercentage: batteryPercentage,
            models: try wireValue.models.map(WorkerModelSnapshot.init(wireValue:))
        )
    }

    /// The protocol representation of this local worker status.
    public var wireValue: InferPeer_V1_WorkerStatus {
        InferPeer_V1_WorkerStatus.with {
            $0.participation = condition.participation.wireValue
            $0.thermalState = condition.thermalState.wireValue
            if let lowPowerModeEnabled = condition.lowPowerModeEnabled {
                $0.lowPowerModeEnabled = lowPowerModeEnabled
            }
            $0.activeGenerations = load.activeGenerations
            $0.generationCapacity = load.generationCapacity
            if let availableAppMemoryBytes = load.availableAppMemoryBytes {
                $0.availableAppMemoryBytes = availableAppMemoryBytes
            }
            if let batteryPercentage {
                $0.batteryPercent = batteryPercentage.value
            }
            $0.models = models.map(\.wireValue)
        }
    }
}

private extension WorkerCondition {
    init(wireValue: InferPeer_V1_WorkerStatus) throws {
        self.init(
            participation: try WorkerParticipationState(wireValue: wireValue.participation),
            thermalState: try WorkerThermalState(wireValue: wireValue.thermalState),
            lowPowerModeEnabled: wireValue.hasLowPowerModeEnabled
                ? wireValue.lowPowerModeEnabled
                : nil
        )
    }
}

private extension WorkerLoad {
    init(wireValue: InferPeer_V1_WorkerStatus) {
        self.init(
            activeGenerations: wireValue.activeGenerations,
            generationCapacity: wireValue.generationCapacity,
            availableAppMemoryBytes: wireValue.hasAvailableAppMemoryBytes
                ? wireValue.availableAppMemoryBytes
                : nil
        )
    }
}

private extension WorkerModelSnapshot {
    init(wireValue: InferPeer_V1_ModelStatus) throws {
        guard wireValue.hasModel else {
            throw CoreWireMappingError.missingModelReference
        }
        try self.init(
            model: try ModelReference(wireValue: wireValue.model),
            isLoaded: wireValue.loaded,
            measuredMemoryBytes: wireValue.hasMeasuredMemoryBytes
                ? wireValue.measuredMemoryBytes
                : nil,
            estimatedLoadDuration: try wireValue.hasEstimatedLoadMilliseconds
                ? Duration(wireMilliseconds: wireValue.estimatedLoadMilliseconds)
                : nil
        )
    }

    var wireValue: InferPeer_V1_ModelStatus {
        InferPeer_V1_ModelStatus.with {
            $0.model = model.wireValue
            $0.loaded = isLoaded
            if let measuredMemoryBytes {
                $0.measuredMemoryBytes = measuredMemoryBytes
            }
            if let estimatedLoadDuration {
                $0.estimatedLoadMilliseconds = estimatedLoadDuration.wireMilliseconds
            }
        }
    }
}

private extension WorkerParticipationState {
    init(wireValue: InferPeer_V1_ParticipationState) throws {
        switch wireValue {
        case .available: self = .available
        case .draining: self = .draining
        case .unavailable: self = .unavailable
        case .unspecified, .UNRECOGNIZED:
            throw CoreWireMappingError.invalidParticipationState
        }
    }

    var wireValue: InferPeer_V1_ParticipationState {
        switch self {
        case .available: .available
        case .draining: .draining
        case .unavailable: .unavailable
        }
    }
}

private extension WorkerThermalState {
    init(wireValue: InferPeer_V1_ThermalState) throws {
        switch wireValue {
        case .unknown: self = .unknown
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        case .unspecified, .UNRECOGNIZED:
            throw CoreWireMappingError.invalidThermalState
        }
    }

    var wireValue: InferPeer_V1_ThermalState {
        switch self {
        case .unknown: .unknown
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        }
    }
}

private extension Duration {
    init(wireMilliseconds: UInt64) throws {
        guard wireMilliseconds <= UInt64(Int64.max) else {
            throw CoreWireMappingError.invalidDuration
        }
        self = .milliseconds(Int64(wireMilliseconds))
    }

    var wireMilliseconds: UInt64 {
        let parts = components
        let seconds = UInt64(clamping: parts.seconds)
        let secondsResult = seconds.multipliedReportingOverflow(by: 1_000)
        guard !secondsResult.overflow else { return .max }
        let fractional = UInt64(clamping: parts.attoseconds / 1_000_000_000_000_000)
        let total = secondsResult.partialValue.addingReportingOverflow(fractional)
        return total.overflow ? .max : total.partialValue
    }
}
