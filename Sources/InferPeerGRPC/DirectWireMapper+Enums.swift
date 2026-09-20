import InferPeerCore
import InferPeerInference
import InferPeerProtocol

/// Validated conversion between v2 Protobuf values and public domain values.
public enum DirectWireMapper {
    /// Converts one domain inference task to its v2 representation.
    public static func wireTask(_ task: InferenceTask) -> InferPeer_V2_Task {
        switch task {
        case .textGeneration: .text
        case .imageUnderstanding: .vision
        case .transcribe: .transcribe
        case .synthesizeSpeech: .synthesizeSpeech
        }
    }

    /// Converts one v2 task, rejecting unspecified and future values.
    public static func task(_ value: InferPeer_V2_Task) throws -> InferenceTask {
        switch value {
        case .text: .textGeneration
        case .vision: .imageUnderstanding
        case .transcribe: .transcribe
        case .synthesizeSpeech: .synthesizeSpeech
        case .unspecified, .UNRECOGNIZED:
            throw DirectWireMappingError.invalidEnum("task")
        }
    }

    static func wireConnection(_ value: ConnectionState) -> InferPeer_V2_ConnectionState {
        switch value {
        case .connecting: .connecting
        case .authenticating: .authenticating
        case .connected: .connected
        case .reconnecting: .reconnecting
        case .disconnected: .disconnected
        case .blocked: .blocked
        }
    }

    static func connection(_ value: InferPeer_V2_ConnectionState) throws -> ConnectionState {
        switch value {
        case .connecting: .connecting
        case .authenticating: .authenticating
        case .connected: .connected
        case .reconnecting: .reconnecting
        case .disconnected: .disconnected
        case .blocked: .blocked
        case .unspecified, .UNRECOGNIZED:
            throw DirectWireMappingError.invalidEnum("connection")
        }
    }

    static func wireExecution(
        _ value: ExecutionAvailability
    ) -> InferPeer_V2_ExecutionAvailability {
        switch value {
        case .available: .available
        case .busy: .busy
        case .pausedByHost: .pausedByHost
        case .thermalLimited: .thermalLimited
        case .memoryLimited: .memoryLimited
        case .backgroundRestricted: .backgroundRestricted
        case .unavailable: .unavailable
        }
    }

    static func execution(
        _ value: InferPeer_V2_ExecutionAvailability
    ) throws -> ExecutionAvailability {
        switch value {
        case .available: .available
        case .busy: .busy
        case .pausedByHost: .pausedByHost
        case .thermalLimited: .thermalLimited
        case .memoryLimited: .memoryLimited
        case .backgroundRestricted: .backgroundRestricted
        case .unavailable: .unavailable
        case .unspecified, .UNRECOGNIZED:
            throw DirectWireMappingError.invalidEnum("execution")
        }
    }

    static func wireReadiness(_ value: ModelReadiness) -> InferPeer_V2_ModelReadiness {
        switch value {
        case .registered: .registered
        case .preparing: .preparing
        case .ready: .ready
        case .unloading: .unloading
        case .failed: .failed
        }
    }

    static func readiness(_ value: InferPeer_V2_ModelReadiness) throws -> ModelReadiness {
        switch value {
        case .registered: .registered
        case .preparing: .preparing
        case .ready: .ready
        case .unloading: .unloading
        case .failed: .failed
        case .unspecified, .UNRECOGNIZED:
            throw DirectWireMappingError.invalidEnum("model readiness")
        }
    }
}
