import InferPeerCore
@testable import InferPeerTelemetry
import Testing

private struct FixedSampler: WorkerStatusSampling {
    let measurements: PlatformWorkerMeasurements

    // swiftlint:disable:next async_without_await
    func sample() async -> PlatformWorkerMeasurements {
        measurements
    }
}

@Test("Current status combines measured and host-controlled state")
func currentStatusCombinesState() async throws {
    let battery = try BatteryPercentage(72)
    let sampler = FixedSampler(
        measurements: PlatformWorkerMeasurements(
            thermalState: .fair,
            lowPowerModeEnabled: true,
            availableAppMemoryBytes: 1_024,
            batteryPercentage: battery
        )
    )
    let provider = try SystemStatusProvider(
        participation: .available,
        generationCapacity: 2,
        activeGenerations: 1,
        sampler: sampler
    )

    let status = await provider.currentStatus()

    #expect(status.condition.participation == .available)
    #expect(status.condition.thermalState == .fair)
    #expect(status.condition.lowPowerModeEnabled == true)
    #expect(status.load.activeGenerations == 1)
    #expect(status.load.generationCapacity == 2)
    #expect(status.load.availableAppMemoryBytes == 1_024)
    #expect(status.batteryPercentage == battery)
}

@Test("Unknown platform metrics stay unknown")
func unknownMetricsStayUnknown() async throws {
    let sampler = FixedSampler(
        measurements: PlatformWorkerMeasurements(
            thermalState: .unknown,
            lowPowerModeEnabled: nil,
            availableAppMemoryBytes: nil,
            batteryPercentage: nil
        )
    )
    let provider = try SystemStatusProvider(sampler: sampler)

    let status = await provider.currentStatus()

    #expect(status.condition.thermalState == .unknown)
    #expect(status.condition.lowPowerModeEnabled == nil)
    #expect(status.load.availableAppMemoryBytes == nil)
    #expect(status.batteryPercentage == nil)
}

@Test("Host participation changes are streamed")
func participationChangesAreStreamed() async throws {
    let sampler = FixedSampler(
        measurements: PlatformWorkerMeasurements(
            thermalState: .nominal,
            lowPowerModeEnabled: false,
            availableAppMemoryBytes: 4_096,
            batteryPercentage: nil
        )
    )
    let provider = try SystemStatusProvider(sampler: sampler)
    let updates = provider.updates(bufferingLimit: 1)
    let task = Task { await updates.first(where: { _ in true }) }
    await Task.yield()

    await provider.setParticipation(.available)

    let status = await task.value
    #expect(status?.condition.participation == .available)
}

@Test("Generation load cannot exceed configured capacity")
func rejectsExcessActiveGenerations() async throws {
    let provider = try SystemStatusProvider(generationCapacity: 1)

    await #expect(throws: StatusProviderError.activeGenerationsExceedCapacity) {
        try await provider.setActiveGenerations(2)
    }
}

@Test("Status update streams reject nonpositive bounds by finishing")
func invalidStatusStreamFinishes() async throws {
    let provider = try SystemStatusProvider()
    let updates = provider.updates(bufferingLimit: 0)

    let value = await updates.first(where: { _ in true })

    #expect(value == nil)
}
