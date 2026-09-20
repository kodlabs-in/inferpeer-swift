import Foundation
import GRPCCore
import InferPeerCore
@testable import InferPeerGRPC
import InferPeerProtocol
import Testing

@Suite("v2 direct wire mapping")
struct DirectWireMapperTests {
    @Test("resource snapshots preserve optional telemetry presence")
    func resourceSnapshotRoundTrip() throws {
        let original = try makeResource()

        let wire = DirectWireMapper.wireResource(original)
        let decoded = try DirectWireMapper.resource(wire)

        #expect(!wire.hasHardwareIdentifier)
        let gpuPower = try #require(wire.telemetry.first { $0.name == "gpuPower" })
        #expect(!gpuPower.hasValue)
        #expect(decoded.id == original.id)
        #expect(decoded.displayName == original.displayName)
        #expect(decoded.connection == .connected)
        #expect(decoded.execution == .available)
        #expect(decoded.revision == 7)
        #expect(decoded.telemetry.measurements == original.telemetry.measurements)
    }

    @Test("unspecified task fails closed")
    func rejectsUnspecifiedTask() {
        #expect(throws: DirectWireMappingError.invalidEnum("task")) {
            _ = try DirectWireMapper.task(.unspecified)
        }
    }

    @Test("invalid resource identity fails before entering the domain")
    func rejectsInvalidResource() {
        let wire = InferPeer_V2_ResourceSnapshot.with {
            $0.resourceID = "bad resource"
            $0.displayName = "Bad"
            $0.operatingSystem = "macOS"
            $0.connection = .connected
            $0.execution = .available
        }

        #expect(throws: DirectWireMappingError.invalidResource) {
            _ = try DirectWireMapper.resource(wire)
        }
    }

    @Test("duplicate telemetry names fail instead of trapping")
    func rejectsDuplicateTelemetry() {
        var wire = makeMinimalWireResource()
        let measurement = InferPeer_V2_TelemetryMeasurement.with {
            $0.name = "memory"
            $0.value = 1
            $0.unit = "bytes"
            $0.scope = "resource"
            $0.quality = "measured"
        }
        wire.telemetry = [measurement, measurement]

        #expect(throws: DirectWireMappingError.invalidTelemetry("memory")) {
            _ = try DirectWireMapper.resource(wire)
        }
    }

    @Test("typed errors preserve stable v2 classification")
    func typedErrorRoundTrip() {
        let original = InferPeerError(code: .queueFull, isRetryable: true)

        let wire = DirectWireMapper.wireError(original, retryDelay: .milliseconds(250))
        let decoded = DirectWireMapper.error(wire)

        #expect(wire.code == .queueFull)
        #expect(wire.retryDelayMilliseconds == 250)
        #expect(decoded == original)
    }

    @Test("gRPC status conversion is stable and sanitized")
    func rpcErrorMapping() {
        let source = RPCError(code: .unavailable, message: " retry later ")
        let mapped = DirectRPCErrorMapper.publicError(from: source)

        #expect(mapped.code == .connectionLost)
        #expect(mapped.message == "retry later")
        #expect(mapped.isRetryable)

        let rpc = DirectRPCErrorMapper.rpcError(
            from: InferPeerError(code: .queueFull, isRetryable: true)
        )
        #expect(rpc.code == .resourceExhausted)
    }

    @Test("run state mapping preserves queue and terminal classification")
    func runStateMapping() throws {
        #expect(DirectWireMapper.wireRunState(.queued(position: 4)) == .queued)
        #expect(try DirectWireMapper.runStatus(.queued, queuePosition: 4) == .queued(position: 4))
        #expect(try DirectWireMapper.runStatus(.expired) == .expired)
        #expect(throws: DirectWireMappingError.invalidEnum("run state")) {
            _ = try DirectWireMapper.runStatus(.unspecified)
        }
    }

    private func makeResource() throws -> ResourceSnapshot {
        let unavailable = try TelemetryMeasurement(
            value: nil,
            unit: "bytes",
            scope: .resource,
            quality: .unavailable,
            unavailableReason: "not supported"
        )
        let measured = try TelemetryMeasurement(
            value: 42,
            unit: "bytes",
            scope: .process,
            quality: .measured,
            sampleAge: .milliseconds(125)
        )
        return ResourceSnapshot(
            id: ResourceID(rawValue: "resource-1"),
            displayName: "Test Mac",
            platform: PlatformDescriptor(
                operatingSystem: .macOS,
                operatingSystemVersion: "15.0"
            ),
            connection: .connected,
            execution: .available,
            capabilities: CapabilitySnapshot(supportedTasks: []),
            models: [],
            telemetry: TelemetrySnapshot(
                measurements: ["freeMemory": measured, "gpuPower": unavailable]
            ),
            revision: 7
        )
    }

    private func makeMinimalWireResource() -> InferPeer_V2_ResourceSnapshot {
        InferPeer_V2_ResourceSnapshot.with {
            $0.resourceID = "resource-1"
            $0.displayName = "Test Mac"
            $0.operatingSystem = "macOS"
            $0.connection = .connected
            $0.execution = .available
        }
    }
}
