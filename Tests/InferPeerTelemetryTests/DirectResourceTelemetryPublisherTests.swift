import InferPeerCore
@testable import InferPeerTelemetry
import Testing

@Suite("Direct resource telemetry publisher")
struct DirectResourceTelemetryPublisherTests {
    @Test("Optional polling runs only while subscribed")
    func subscriberAwarePolling() async throws {
        let sampler = MutableResourceSampler(snapshot: try snapshot(revision: 0))
        let publisher = DirectResourceTelemetryPublisher(sampler: sampler)

        #expect(await publisher.nextOptionalSamplingInterval() == nil)
        #expect(try await publisher.poll() == false)
        #expect(await sampler.sampleCount() == 0)

        let subscription = await publisher.subscribe(bufferingLimit: 2)
        #expect(await publisher.nextOptionalSamplingInterval() == .seconds(15))
        #expect(await publisher.nextHeartbeatInterval() == .seconds(15))
        #expect(try await publisher.poll())
        #expect(await sampler.sampleCount() == 1)

        await subscription.cancel()

        #expect(await publisher.nextOptionalSamplingInterval() == nil)
        #expect(try await publisher.poll() == false)
        #expect(await sampler.sampleCount() == 1)
    }

    @Test("Active resources expose two-second sampling and five-second heartbeat hints")
    func activeScheduleHints() async throws {
        let sampler = MutableResourceSampler(snapshot: try snapshot(revision: 0))
        let publisher = DirectResourceTelemetryPublisher(
            sampler: sampler,
            activity: .active
        )
        let subscription = await publisher.subscribe(bufferingLimit: 1)

        #expect(await publisher.nextOptionalSamplingInterval() == .seconds(2))
        #expect(await publisher.nextHeartbeatInterval() == .seconds(5))

        await subscription.cancel()
    }

    @Test("Initial delivery is complete and changed state advances one revision")
    func snapshotAndDeltaPublication() async throws {
        let first = try snapshot(revision: 41, displayName: "First")
        let second = try snapshot(revision: 99, displayName: "Second")
        let sampler = MutableResourceSampler(snapshot: first)
        let publisher = DirectResourceTelemetryPublisher(sampler: sampler)
        let subscription = await publisher.subscribe(bufferingLimit: 3)
        var iterator = subscription.updates.makeAsyncIterator()

        #expect(try await publisher.poll())
        let initial = await iterator.next()
        try assertSnapshot(initial, displayName: "First", revision: 41)
        #expect(try await publisher.poll() == false)

        await sampler.setSnapshot(second)
        #expect(try await publisher.poll())
        let update = await iterator.next()
        try assertDelta(update, displayName: "Second", baseRevision: 41, revision: 42)

        let lateSubscriber = await publisher.subscribe(bufferingLimit: 1)
        var lateIterator = lateSubscriber.updates.makeAsyncIterator()
        try assertSnapshot(await lateIterator.next(), displayName: "Second", revision: 42)

        await subscription.cancel()
        await lateSubscriber.cancel()
    }

    @Test("Unknown measurements and measured zero remain distinct")
    func unknownVersusZero() async throws {
        let sampler = MutableResourceSampler(snapshot: try snapshot(revision: 0))
        let publisher = DirectResourceTelemetryPublisher(sampler: sampler)
        let subscription = await publisher.subscribe(bufferingLimit: 1)
        var iterator = subscription.updates.makeAsyncIterator()

        #expect(try await publisher.poll())
        let publication = await iterator.next()
        guard case .snapshot(let value) = publication else {
            Issue.record("Expected complete snapshot")
            return
        }
        let zero = value.telemetry.measurements["activeRuns"]
        let unknown = value.telemetry.measurements["memoryBytes"]

        #expect(zero?.value == 0)
        #expect(zero?.quality == .measured)
        #expect(zero?.scope == .runtime)
        #expect(zero?.unit == "count")
        #expect(zero?.sampleAge == .milliseconds(250))
        #expect(unknown?.value == nil)
        #expect(unknown?.quality == .unavailable)
        #expect(unknown?.scope == .process)
        #expect(unknown?.unavailableReason == "platform API unavailable")

        await subscription.cancel()
    }

    @Test("Heartbeat carries the latest published revision")
    func heartbeatPublication() async throws {
        let sampler = MutableResourceSampler(snapshot: try snapshot(revision: 7))
        let publisher = DirectResourceTelemetryPublisher(sampler: sampler)
        let subscription = await publisher.subscribe(bufferingLimit: 2)
        var iterator = subscription.updates.makeAsyncIterator()

        #expect(try await publisher.poll())
        _ = await iterator.next()
        await publisher.publishHeartbeat()

        guard case .heartbeat(let resourceID, let revision) = await iterator.next() else {
            Issue.record("Expected heartbeat")
            return
        }
        #expect(resourceID.rawValue == "resource")
        #expect(revision == 7)

        await subscription.cancel()
    }

    private func snapshot(
        revision: UInt64,
        displayName: String = "Resource"
    ) throws -> ResourceSnapshot {
        let zero = try TelemetryMeasurement(
            value: 0,
            unit: "count",
            scope: .runtime,
            quality: .measured,
            sampleAge: .milliseconds(250)
        )
        let unknown = try TelemetryMeasurement(
            value: nil,
            unit: "bytes",
            scope: .process,
            quality: .unavailable,
            unavailableReason: "platform API unavailable"
        )
        return ResourceSnapshot(
            id: ResourceID(rawValue: "resource"),
            displayName: displayName,
            platform: PlatformDescriptor(
                operatingSystem: .macOS,
                operatingSystemVersion: "test"
            ),
            connection: .connected,
            execution: .available,
            capabilities: CapabilitySnapshot(supportedTasks: []),
            models: [],
            telemetry: TelemetrySnapshot(
                measurements: ["activeRuns": zero, "memoryBytes": unknown]
            ),
            revision: revision
        )
    }

    private func assertSnapshot(
        _ publication: DirectResourcePublication?,
        displayName: String,
        revision: UInt64
    ) throws {
        guard case .snapshot(let value) = publication else {
            Issue.record("Expected complete snapshot")
            return
        }
        #expect(value.displayName == displayName)
        #expect(value.revision == revision)
    }

    private func assertDelta(
        _ publication: DirectResourcePublication?,
        displayName: String,
        baseRevision: UInt64,
        revision: UInt64
    ) throws {
        guard case .delta(let delta) = publication else {
            Issue.record("Expected revisioned delta")
            return
        }
        #expect(delta.baseRevision == baseRevision)
        #expect(delta.revision == revision)
        #expect(delta.changedSnapshot.displayName == displayName)
        #expect(delta.changedSnapshot.revision == revision)
    }
}

private actor MutableResourceSampler: DirectResourceSnapshotSampling {
    private var snapshot: ResourceSnapshot
    private var count = 0

    init(snapshot: ResourceSnapshot) {
        self.snapshot = snapshot
    }

    func sampleResourceSnapshot() async throws -> ResourceSnapshot {
        await Task.yield()
        count += 1
        return snapshot
    }

    func setSnapshot(_ snapshot: ResourceSnapshot) {
        self.snapshot = snapshot
    }

    func sampleCount() -> Int {
        count
    }
}
