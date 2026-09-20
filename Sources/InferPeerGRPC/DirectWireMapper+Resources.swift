import Foundation
import InferPeerCore
import InferPeerProtocol

extension DirectWireMapper {
    /// Converts a complete resource snapshot to its v2 representation.
    public static func wireResource(_ value: ResourceSnapshot) -> InferPeer_V2_ResourceSnapshot {
        InferPeer_V2_ResourceSnapshot.with {
            $0.resourceID = value.id.rawValue
            $0.displayName = value.displayName
            $0.operatingSystem = value.platform.operatingSystem.rawValue
            $0.operatingSystemVersion = value.platform.operatingSystemVersion
            if let hardwareIdentifier = value.platform.hardwareIdentifier {
                $0.hardwareIdentifier = hardwareIdentifier
            }
            $0.connection = wireConnection(value.connection)
            $0.execution = wireExecution(value.execution)
            $0.supportedTasks = value.capabilities.supportedTasks.map(wireTask).sorted {
                $0.rawValue < $1.rawValue
            }
            $0.models = value.models.map(wireModelSummary)
            $0.telemetry = value.telemetry.measurements.map(wireTelemetry)
                .sorted { $0.name < $1.name }
            $0.revision = value.revision
        }
    }

    /// Converts and validates a complete v2 resource snapshot.
    public static func resource(_ value: InferPeer_V2_ResourceSnapshot) throws -> ResourceSnapshot {
        guard validResourceID(value.resourceID), !value.displayName.isEmpty else {
            throw DirectWireMappingError.invalidResource
        }
        guard
            let operatingSystem = PlatformDescriptor.OperatingSystem(
                rawValue: value.operatingSystem
            )
        else {
            throw DirectWireMappingError.invalidEnum("operating system")
        }
        return ResourceSnapshot(
            id: ResourceID(rawValue: value.resourceID),
            displayName: value.displayName,
            platform: PlatformDescriptor(
                operatingSystem: operatingSystem,
                operatingSystemVersion: value.operatingSystemVersion,
                hardwareIdentifier: value.hasHardwareIdentifier ? value.hardwareIdentifier : nil
            ),
            connection: try connection(value.connection),
            execution: try execution(value.execution),
            capabilities: CapabilitySnapshot(
                supportedTasks: Set(try value.supportedTasks.map(task))
            ),
            models: try value.models.map(modelSummary),
            telemetry: TelemetrySnapshot(measurements: try telemetry(value.telemetry)),
            revision: value.revision
        )
    }

    private static func wireTelemetry(
        _ name: String,
        _ measurement: TelemetryMeasurement
    ) -> InferPeer_V2_TelemetryMeasurement {
        InferPeer_V2_TelemetryMeasurement.with {
            $0.name = name
            if let value = measurement.value {
                $0.value = value
            }
            $0.unit = measurement.unit
            $0.scope = measurement.scope.rawValue
            $0.quality = measurement.quality.rawValue
            if let sampleAge = measurement.sampleAge {
                $0.sampleAgeMilliseconds = durationMilliseconds(sampleAge)
            }
            if let unavailableReason = measurement.unavailableReason {
                $0.unavailableReason = unavailableReason
            }
        }
    }

    private static func telemetry(
        _ values: [InferPeer_V2_TelemetryMeasurement]
    ) throws -> [String: TelemetryMeasurement] {
        var result: [String: TelemetryMeasurement] = [:]
        for value in values {
            guard !value.name.isEmpty,
                let scope = TelemetryScope(rawValue: value.scope),
                let quality = TelemetryQuality(rawValue: value.quality),
                result[value.name] == nil
            else {
                throw DirectWireMappingError.invalidTelemetry(value.name)
            }
            do {
                result[value.name] = try TelemetryMeasurement(
                    value: value.hasValue ? value.value : nil,
                    unit: value.unit,
                    scope: scope,
                    quality: quality,
                    sampleAge: value.hasSampleAgeMilliseconds
                        ? duration(milliseconds: value.sampleAgeMilliseconds) : nil,
                    unavailableReason: value.hasUnavailableReason
                        ? value.unavailableReason : nil
                )
            } catch {
                throw DirectWireMappingError.invalidTelemetry(value.name)
            }
        }
        return result
    }

    private static func validResourceID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }
}
