import InferPeerCore
import Testing

@Suite("Direct resource publication")
struct DirectResourcePublicationTests {
    @Test("Standard cadence matches active and idle PRD defaults")
    func standardCadence() {
        let schedule = DirectPublicationSchedule.standard

        #expect(schedule.samplingInterval(for: .active) == .seconds(2))
        #expect(schedule.samplingInterval(for: .idle) == .seconds(15))
        #expect(schedule.heartbeatInterval(for: .active) == .seconds(5))
        #expect(schedule.heartbeatInterval(for: .idle) == .seconds(15))
        #expect(schedule.missedHeartbeatLimit == 3)
    }

    @Test("Schedules reject nonpositive intervals and missed limits")
    func invalidCadence() {
        #expect(throws: DirectPublicationScheduleError.invalidInterval) {
            _ = try DirectPublicationSchedule(activeSamplingInterval: .zero)
        }
        #expect(throws: DirectPublicationScheduleError.invalidMissedHeartbeatLimit) {
            _ = try DirectPublicationSchedule(missedHeartbeatLimit: 0)
        }
    }

    @Test("Exact deltas advance state and gaps request resynchronization")
    func deltaGapDetection() {
        let first = snapshot(revision: 1, displayName: "One")
        let second = snapshot(revision: 2, displayName: "Two")
        let skipped = snapshot(revision: 5, displayName: "Skipped")
        var accumulator = DirectResourcePublicationAccumulator()

        #expect(accumulator.apply(.snapshot(first)) == .appliedSnapshot)
        #expect(
            accumulator.apply(
                .delta(
                    DirectResourceDelta(
                        resourceID: first.id,
                        baseRevision: 1,
                        revision: 2,
                        changedSnapshot: second
                    )
                )
            ) == .appliedDelta
        )
        #expect(accumulator.snapshot?.displayName == "Two")
        #expect(
            accumulator.apply(
                .delta(
                    DirectResourceDelta(
                        resourceID: first.id,
                        baseRevision: 4,
                        revision: 5,
                        changedSnapshot: skipped
                    )
                )
            ) == .resyncRequired(expectedBase: 2, receivedBase: 4)
        )
        #expect(accumulator.snapshot?.revision == 2)
    }

    @Test("Revision overflow cannot masquerade as a valid delta")
    func deltaRevisionOverflow() {
        let current = snapshot(revision: .max, displayName: "Current")
        let wrapped = snapshot(revision: 0, displayName: "Wrapped")
        var accumulator = DirectResourcePublicationAccumulator(snapshot: current)

        let result = accumulator.apply(
            .delta(
                DirectResourceDelta(
                    resourceID: current.id,
                    baseRevision: .max,
                    revision: 0,
                    changedSnapshot: wrapped
                )
            )
        )

        #expect(result == .resyncRequired(expectedBase: .max, receivedBase: .max))
        #expect(accumulator.snapshot?.revision == .max)
    }

    @Test("Heartbeats detect gaps and ignore stale revisions")
    func heartbeatGapDetection() {
        let current = snapshot(revision: 2)
        var accumulator = DirectResourcePublicationAccumulator(snapshot: current)

        #expect(
            accumulator.apply(.heartbeat(resourceID: current.id, revision: 2)) == .heartbeat
        )
        #expect(
            accumulator.apply(.heartbeat(resourceID: current.id, revision: 1)) == .ignoredStale
        )
        #expect(
            accumulator.apply(.heartbeat(resourceID: current.id, revision: 3))
                == .resyncRequired(expectedBase: 2, receivedBase: 3)
        )
    }

    @Test("Three missed active intervals mark a resource stale and disconnected")
    func activeFreshnessBoundary() {
        let classifier = DirectResourceFreshnessClassifier()
        let received = MonotonicInstant(nanoseconds: 1_000_000_000)

        let beforeDeadline = classifier.assess(
            lastReceivedAt: received,
            now: MonotonicInstant(nanoseconds: 15_999_999_999),
            activity: .active
        )
        let atDeadline = classifier.assess(
            lastReceivedAt: received,
            now: MonotonicInstant(nanoseconds: 16_000_000_000),
            activity: .active
        )

        #expect(beforeDeadline.freshness == .fresh)
        #expect(beforeDeadline.connection == .connected)
        #expect(atDeadline.freshness == .stale)
        #expect(atDeadline.connection == .disconnected)
    }

    @Test("Idle timeout is 45 seconds and transport failure is immediate")
    func idleAndTransportFreshness() {
        let classifier = DirectResourceFreshnessClassifier()
        let received = MonotonicInstant(nanoseconds: 0)

        let idleTimeout = classifier.assess(
            lastReceivedAt: received,
            now: MonotonicInstant(nanoseconds: 45_000_000_000),
            activity: .idle
        )
        let transportFailure = classifier.assess(
            lastReceivedAt: received,
            now: received,
            activity: .active,
            transportFailed: true
        )

        #expect(idleTimeout.freshness == .stale)
        #expect(idleTimeout.connection == .disconnected)
        #expect(transportFailure.freshness == .disconnected)
        #expect(transportFailure.connection == .disconnected)
    }

    private func snapshot(
        revision: UInt64,
        displayName: String = "Resource"
    ) -> ResourceSnapshot {
        ResourceSnapshot(
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
            revision: revision
        )
    }
}
