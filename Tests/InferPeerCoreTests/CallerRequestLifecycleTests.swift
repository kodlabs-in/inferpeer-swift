import InferPeerCore
import InferPeerProtocol
import Testing

@Suite("Caller request lifecycle")
struct CallerRequestLifecycleTests {
    @Test("Keeps a request pending until durable coordinator acceptance")
    func waitsForAcceptance() throws {
        var lifecycle = try makeLifecycle()

        try lifecycle.markSubmitted()
        try lifecycle.accept(coordinatorState: .queued)

        #expect(lifecycle.phase == .accepted(.queued))
        #expect(lifecycle.canRemoveFromOutbox)
    }

    @Test("Deduplicates replay and acknowledges only observed cursors")
    func tracksReplayCursor() throws {
        var lifecycle = try acceptedLifecycle()

        #expect(try lifecycle.observe(coordinatorState: .assigned, eventCursor: 7) == .new)
        #expect(try lifecycle.observe(coordinatorState: .assigned, eventCursor: 7) == .duplicate)
        try lifecycle.acknowledge(through: 7)

        #expect(lifecycle.latestEventCursor == 7)
        #expect(lifecycle.acknowledgedEventCursor == 7)
        #expect(throws: CallerRequestTransitionError.cursorNotObserved) {
            try lifecycle.acknowledge(through: 8)
        }
    }

    @Test("Cancels locally before submission and reports late cancellation")
    func handlesCancellationBoundaries() throws {
        var local = try makeLifecycle()
        var completed = try acceptedLifecycle()

        #expect(local.requestCancellation() == .confirmed)
        _ = try completed.observe(coordinatorState: .completed, eventCursor: 9)
        #expect(completed.requestCancellation() == .tooLate)

        #expect(local.phase == .terminal(.cancelled))
        #expect(completed.phase == .terminal(.completed))
    }

    @Test("Applies coordinator cancellation progress")
    func appliesCoordinatorCancellation() throws {
        var lifecycle = try acceptedLifecycle()
        #expect(lifecycle.requestCancellation() == .pending)

        try lifecycle.applyCancellation(.confirmed)

        #expect(lifecycle.cancellationState == .confirmed)
        #expect(lifecycle.phase == .terminal(.cancelled))
    }

    private func acceptedLifecycle() throws -> CallerRequestLifecycle {
        var lifecycle = try makeLifecycle()
        try lifecycle.markSubmitted()
        try lifecycle.accept(coordinatorState: .queued)
        return lifecycle
    }

    private func makeLifecycle() throws -> CallerRequestLifecycle {
        let requestID = try #require(RequestID(rawValue: "request-1"))
        return CallerRequestLifecycle(requestID: requestID)
    }
}
