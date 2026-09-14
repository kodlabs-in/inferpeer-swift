import InferPeerInference
import InferPeerProtocol
@testable import InferPeerTelemetry
import Testing

@Test("Recorder streams measured metadata without content fields")
func recordsInferenceTiming() async throws {
    let model = try ModelReference(
        modelID: #require(ModelID(rawValue: "llama")),
        revision: "v1"
    )
    let measurement = try InferenceTimingMeasurement(
        model: model,
        phase: .generation,
        duration: .milliseconds(25)
    )
    let recorder = LocalTelemetryRecorder()
    let events = recorder.events(bufferingLimit: 1)
    let task = Task { await events.first(where: { _ in true }) }
    await Task.yield()

    await recorder.record(.inference(measurement))

    #expect(await task.value == .inference(measurement))
}

@Test("Negative timing measurements are rejected")
func rejectsNegativeTiming() throws {
    #expect(throws: TelemetryMeasurementError.negativeDuration) {
        _ = try NetworkTimingMeasurement(
            operation: .connection,
            duration: .milliseconds(-1)
        )
    }
}

@Test("Telemetry streams with invalid bounds finish immediately")
func invalidTelemetryStreamFinishes() async {
    let recorder = LocalTelemetryRecorder()
    let events = recorder.events(bufferingLimit: 0)

    let value = await events.first(where: { _ in true })

    #expect(value == nil)
}
