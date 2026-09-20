import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol

extension DirectWireMapper {
    /// Converts an exact model reference and transport-owned artifact metadata.
    public static func wireModelKey(
        _ model: ModelKey,
        runtime: String = "",
        manifestSHA256: Data = Data()
    ) -> InferPeer_V2_ModelKey {
        InferPeer_V2_ModelKey.with {
            $0.modelID = model.modelID.rawValue
            $0.upstreamRevision = model.revision
            $0.manifestSha256 = manifestSHA256
            $0.runtime = runtime
        }
    }

    /// Converts a v2 model key to the public exact model reference.
    public static func modelKey(_ value: InferPeer_V2_ModelKey) throws -> ModelKey {
        guard let modelID = ModelID(rawValue: value.modelID) else {
            throw DirectWireMappingError.invalidModel
        }
        do {
            return try ModelKey(modelID: modelID, revision: value.upstreamRevision)
        } catch {
            throw DirectWireMappingError.invalidModel
        }
    }

    /// Converts a public model summary to its v2 representation.
    public static func wireModelSummary(_ value: ModelSummary) -> InferPeer_V2_ModelSummary {
        InferPeer_V2_ModelSummary.with {
            $0.key = wireModelKey(value.key)
            $0.readiness = wireReadiness(value.readiness)
            $0.supportedTasks = value.supportedTasks.map(wireTask).sorted {
                $0.rawValue < $1.rawValue
            }
        }
    }

    /// Converts and validates a v2 model summary.
    public static func modelSummary(_ value: InferPeer_V2_ModelSummary) throws -> ModelSummary {
        try ModelSummary(
            key: modelKey(value.key),
            readiness: readiness(value.readiness),
            supportedTasks: Set(value.supportedTasks.map(task))
        )
    }

    /// Converts one stable public failure to the v2 payload-safe representation.
    public static func wireError(
        _ error: InferPeerError,
        retryDelay: Duration? = nil
    ) -> InferPeer_V2_ErrorDetail {
        var value = error.v2WireValue
        if let retryDelay {
            value.retryDelayMilliseconds = durationMilliseconds(retryDelay)
        }
        return value
    }

    /// Converts one v2 error detail while preserving unknown stable error codes.
    public static func error(_ value: InferPeer_V2_ErrorDetail) -> InferPeerError {
        InferPeerError(wireValue: value)
    }

    static func durationMilliseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let milliseconds = UInt64(max(0, components.attoseconds / 1_000_000_000_000_000))
        let secondsResult = seconds.multipliedReportingOverflow(by: 1_000)
        guard !secondsResult.overflow else { return .max }
        let totalResult = secondsResult.partialValue.addingReportingOverflow(milliseconds)
        return totalResult.overflow ? .max : totalResult.partialValue
    }

    static func duration(milliseconds: UInt64) -> Duration {
        let seconds = milliseconds / 1_000
        let remainder = milliseconds % 1_000
        return .seconds(seconds) + .milliseconds(remainder)
    }
}
