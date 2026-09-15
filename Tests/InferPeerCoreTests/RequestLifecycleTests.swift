import InferPeerCore
import InferPeerProtocol
import Testing

@Suite("Coordinator request lifecycle")
struct RequestLifecycleTests {
    @Test("Transitions an accepted attempt to one completed request")
    func completesAcceptedAttempt() throws {
        var lifecycle = RequestLifecycle()
        let attemptID = try #require(AttemptID(rawValue: "attempt-1"))
        let workerID = try #require(PeerID(rawValue: "worker-1"))
        let incarnationID = try #require(
            CoordinatorIncarnationID(rawValue: "coordinator-run-1")
        )

        let attempt = try lifecycle.assign(
            attemptID: attemptID,
            workerID: workerID,
            coordinatorIncarnationID: incarnationID,
            leaseDeadline: MonotonicInstant(nanoseconds: 20_000_000_000)
        )
        try lifecycle.accept(attemptID: attemptID)
        let commit = try lifecycle.complete(attemptID: attemptID)

        #expect(attempt.number == 1)
        #expect(lifecycle.state == .completed)
        #expect(lifecycle.activeAttempt == nil)
        #expect(commit == .committed)
    }

    @Test("Retries an interruption under a fresh attempt identity")
    func retriesInterruptedAttempt() throws {
        var lifecycle = RequestLifecycle()
        let firstAttemptID = try #require(AttemptID(rawValue: "attempt-1"))
        let secondAttemptID = try #require(AttemptID(rawValue: "attempt-2"))

        _ = try lifecycle.assign(
            attemptID: firstAttemptID,
            workerID: try makeWorkerID(),
            coordinatorIncarnationID: try makeIncarnationID(),
            leaseDeadline: MonotonicInstant(nanoseconds: 20)
        )
        try lifecycle.accept(attemptID: firstAttemptID)
        try lifecycle.interrupt(attemptID: firstAttemptID, willRetry: true)
        let retry = try lifecycle.assign(
            attemptID: secondAttemptID,
            workerID: try makeWorkerID(),
            coordinatorIncarnationID: try makeIncarnationID(),
            leaseDeadline: MonotonicInstant(nanoseconds: 40)
        )

        #expect(lifecycle.state == .assigned)
        #expect(retry.number == 2)
        #expect(throws: RequestTransitionError.self) {
            try lifecycle.accept(attemptID: firstAttemptID)
        }
    }

    @Test("Interruption confirms an already-durable cancellation instead of retrying")
    func interruptionConfirmsPendingCancellation() throws {
        let attemptID = try #require(AttemptID(rawValue: "attempt-1"))
        var lifecycle = try runningLifecycle(attemptID: attemptID)
        #expect(lifecycle.requestCancellation() == .pending)

        try lifecycle.interrupt(attemptID: attemptID, willRetry: true)

        #expect(lifecycle.state == .cancelled)
        #expect(lifecycle.cancellationState == .confirmed)
        #expect(lifecycle.activeAttempt == nil)
        _ = try RequestLifecycle(
            restoring: lifecycle.state,
            attemptNumber: lifecycle.attemptNumber,
            activeAttempt: lifecycle.activeAttempt,
            cancellationState: lifecycle.cancellationState
        )
    }

    @Test("Makes the first terminal cancel-or-complete commit win")
    func resolvesCancellationRace() throws {
        let attemptID = try #require(AttemptID(rawValue: "attempt-1"))
        var cancellationWins = try runningLifecycle(attemptID: attemptID)
        var completionWins = try runningLifecycle(attemptID: attemptID)

        #expect(cancellationWins.requestCancellation() == .pending)
        #expect(try cancellationWins.confirmCancellation(attemptID: attemptID) == .committed)
        #expect(
            try cancellationWins.complete(attemptID: attemptID) == .alreadyTerminal(.cancelled)
        )

        #expect(completionWins.requestCancellation() == .pending)
        #expect(try completionWins.complete(attemptID: attemptID) == .committed)
        #expect(completionWins.cancellationState == .tooLate)
        #expect(
            try completionWins.confirmCancellation(attemptID: attemptID)
                == .alreadyTerminal(.completed)
        )
    }

    @Test("Expires only a nonterminal request")
    func expiresRequestOnce() {
        var lifecycle = RequestLifecycle()

        #expect(lifecycle.expire() == .committed)
        #expect(lifecycle.state == .expired)
        #expect(lifecycle.expire() == .alreadyTerminal(.expired))
    }

    @Test("Restores only internally consistent durable snapshots")
    func validatesRestoredSnapshot() throws {
        let attempt = try ActiveAttempt(
            attemptID: #require(AttemptID(rawValue: "attempt-1")),
            workerID: #require(PeerID(rawValue: "worker-1")),
            number: 1,
            coordinatorIncarnationID: #require(
                CoordinatorIncarnationID(rawValue: "coordinator-run-1")
            ),
            leaseDeadline: MonotonicInstant(nanoseconds: 20)
        )

        let restored = try RequestLifecycle(
            restoring: .running,
            attemptNumber: 1,
            activeAttempt: attempt,
            cancellationState: .pending
        )

        #expect(restored.activeAttempt == attempt)
        #expect(throws: RequestLifecycleSnapshotError.activeAttemptRequired) {
            try RequestLifecycle(
                restoring: .running,
                attemptNumber: 1,
                activeAttempt: nil,
                cancellationState: .notRequested
            )
        }
        #expect(throws: RequestLifecycleSnapshotError.activeAttemptNotAllowed) {
            try RequestLifecycle(
                restoring: .queued,
                attemptNumber: 1,
                activeAttempt: attempt,
                cancellationState: .notRequested
            )
        }
        #expect(throws: RequestLifecycleSnapshotError.invalidCancellationState) {
            try RequestLifecycle(
                restoring: .completed,
                attemptNumber: 1,
                activeAttempt: nil,
                cancellationState: .pending
            )
        }
    }

    private func runningLifecycle(attemptID: AttemptID) throws -> RequestLifecycle {
        var lifecycle = RequestLifecycle()
        _ = try lifecycle.assign(
            attemptID: attemptID,
            workerID: makeWorkerID(),
            coordinatorIncarnationID: makeIncarnationID(),
            leaseDeadline: MonotonicInstant(nanoseconds: 20)
        )
        try lifecycle.accept(attemptID: attemptID)
        return lifecycle
    }

    private func makeWorkerID() throws -> PeerID {
        try #require(PeerID(rawValue: "worker-1"))
    }

    private func makeIncarnationID() throws -> CoordinatorIncarnationID {
        try #require(CoordinatorIncarnationID(rawValue: "coordinator-run-1"))
    }
}
