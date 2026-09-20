import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Direct resource registry")
struct DirectResourceTypesTests {
    @Test("V2 errors preserve unknown codes and safe retry metadata")
    func v2ErrorRoundTripPreservesUnknownCodes() {
        let wire = InferPeer_V2_ErrorDetail.with {
            $0.code = .UNRECOGNIZED(901)
            $0.safeMessage = "Future safe failure"
            $0.retryable = true
        }

        let error = InferPeerError(wireValue: wire)
        let encoded = error.v2WireValue

        #expect(error.code == .unrecognized(901))
        #expect(encoded.code == .UNRECOGNIZED(901))
        #expect(encoded.safeMessage == "Future safe failure")
        #expect(encoded.retryable)
    }

    @Test("Connected filtering keeps local and authenticated live resources")
    func connectedFilter() async {
        let registry = ResourceRegistry(
            initialSnapshots: [
                snapshot(id: .local, connection: .connected),
                snapshot(id: ResourceID(rawValue: "connected"), connection: .connected),
                snapshot(id: ResourceID(rawValue: "remembered"), connection: .disconnected),
            ]
        )

        let connected = await registry.snapshots(.connected)
        let known = await registry.snapshots(.known)

        #expect(connected.map(\.id.rawValue) == ["connected", "local"])
        #expect(known.map(\.id.rawValue) == ["connected", "local", "remembered"])
    }

    @Test("Only newer resource revisions replace current state")
    func revisionOrdering() async {
        let resourceID = ResourceID(rawValue: "remote")
        let registry = ResourceRegistry(
            initialSnapshots: [snapshot(id: resourceID, connection: .connected, revision: 2)]
        )

        await registry.apply(snapshot(id: resourceID, connection: .disconnected, revision: 1))

        #expect(await registry.snapshots(.known).first?.connection == .connected)
    }

    @Test("Unavailable telemetry cannot carry a fabricated numeric value")
    func unavailableTelemetryHasNoValue() {
        #expect(throws: TelemetryMeasurementError.unavailableValuePresent) {
            _ = try TelemetryMeasurement(
                value: 0,
                unit: "bytes",
                scope: .process,
                quality: .unavailable,
                unavailableReason: "API unavailable"
            )
        }
    }

    @Test("Terminal results preserve modality-specific output")
    func modalitySpecificRunResults() throws {
        let model = try ModelReference(
            modelID: #require(ModelID(rawValue: "model")),
            revision: "1"
        )
        let segment = TranscriptSegment(
            id: "segment-1",
            revision: 2,
            start: .zero,
            end: .seconds(1),
            text: "Hello",
            isFinal: true
        )
        let transcription = RunResult(
            content: .transcription(
                segments: [segment],
                language: "en",
                mode: .transcription
            ),
            model: model,
            finishReason: .stop,
            usage: .init(promptTokens: 0, outputTokens: 0)
        )
        let speech = RunResult(
            content: .speech(
                asset: .init(rawValue: "output-receipt"),
                format: .signedInt16,
                sampleRate: 24_000,
                channelCount: 1,
                frameCount: 24_000
            ),
            model: model,
            finishReason: .stop,
            usage: .init(promptTokens: 0, outputTokens: 0)
        )

        #expect(transcription.text == "Hello")
        #expect(speech.text.isEmpty)
        #expect(speech.content != transcription.content)
    }

    private func snapshot(
        id: ResourceID,
        connection: ConnectionState,
        revision: UInt64 = 1
    ) -> ResourceSnapshot {
        ResourceSnapshot(
            id: id,
            displayName: id.rawValue,
            platform: PlatformDescriptor(
                operatingSystem: .macOS,
                operatingSystemVersion: "test"
            ),
            connection: connection,
            execution: .available,
            capabilities: CapabilitySnapshot(supportedTasks: []),
            models: [],
            revision: revision
        )
    }
}
