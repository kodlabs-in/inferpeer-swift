import InferPeerCore
import InferPeerProtocol
import Testing

@Suite("Worker attempt lifecycle")
struct WorkerAttemptLifecycleTests {
    @Test("Accepts work and renews only the owning coordinator lease")
    func acceptsAndRenewsLease() throws {
        let attemptID = try #require(AttemptID(rawValue: "attempt-1"))
        let incarnationID = try makeIncarnationID("coordinator-run-1")
        var lifecycle = WorkerAttemptLifecycle(
            attemptID: attemptID,
            coordinatorIncarnationID: incarnationID,
            leaseDeadline: MonotonicInstant(nanoseconds: 20)
        )

        try lifecycle.accept(at: MonotonicInstant(nanoseconds: 10))
        try lifecycle.renewLease(
            until: MonotonicInstant(nanoseconds: 40),
            coordinatorIncarnationID: incarnationID
        )

        #expect(lifecycle.state == .running)
        #expect(lifecycle.leaseDeadline == MonotonicInstant(nanoseconds: 40))
    }

    @Test("Stops an attempt when its lease expires")
    func expiresLease() throws {
        var lifecycle = try runningLifecycle()
        let expiredEarly = lifecycle.expireIfNeeded(at: MonotonicInstant(nanoseconds: 19))
        let expiredOnDeadline = lifecycle.expireIfNeeded(
            at: MonotonicInstant(nanoseconds: 20)
        )

        #expect(!expiredEarly)
        #expect(expiredOnDeadline)
        #expect(lifecycle.state == .leaseExpired)
        #expect(lifecycle.shouldStop)
    }

    @Test("Allows completion to race cooperative cancellation")
    func allowsCompletionRace() throws {
        var cancellationWins = try runningLifecycle()
        var completionWins = try runningLifecycle()

        cancellationWins.requestCancellation()
        try cancellationWins.confirmCancellation()

        completionWins.requestCancellation()
        try completionWins.complete()

        #expect(cancellationWins.state == .cancelled)
        #expect(completionWins.state == .completed)
    }

    @Test("Rejects a stale coordinator incarnation")
    func rejectsStaleIncarnation() throws {
        var lifecycle = try runningLifecycle()
        let staleID = try makeIncarnationID("coordinator-run-old")

        #expect(throws: WorkerAttemptTransitionError.staleCoordinatorIncarnation) {
            try lifecycle.renewLease(
                until: MonotonicInstant(nanoseconds: 40),
                coordinatorIncarnationID: staleID
            )
        }
    }

    private func runningLifecycle() throws -> WorkerAttemptLifecycle {
        let attemptID = try #require(AttemptID(rawValue: "attempt-1"))
        var lifecycle = WorkerAttemptLifecycle(
            attemptID: attemptID,
            coordinatorIncarnationID: try makeIncarnationID("coordinator-run-1"),
            leaseDeadline: MonotonicInstant(nanoseconds: 20)
        )
        try lifecycle.accept(at: MonotonicInstant(nanoseconds: 10))
        return lifecycle
    }

    private func makeIncarnationID(_ value: String) throws -> CoordinatorIncarnationID {
        try #require(CoordinatorIncarnationID(rawValue: value))
    }
}
