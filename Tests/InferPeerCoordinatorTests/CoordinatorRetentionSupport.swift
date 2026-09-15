import Foundation
@testable import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage
import Testing

struct PrunedCoordinatorCompletion {
    let requestID: RequestID
    let callerID: PeerID
    let attemptID: AttemptID
    let result: GenerationResult
}

private struct CoordinatorTerminalMutation {
    let attemptID: AttemptID
    let result: GenerationResult
    let mutation: RequestMutation
}

func seedPrunedCompletion(
    in store: SQLiteJobStore
) async throws -> PrunedCoordinatorCompletion {
    let requestID = try #require(RequestID(rawValue: "request-retained"))
    let callerID = try #require(PeerID(rawValue: "caller-retained"))
    let submission = try storedSubmission(
        requestID: requestID,
        callerID: callerID,
        model: makeCoordinatorModel()
    )
    let accepted = try accepted(try await store.accept(submission))
    let terminal = try makeTerminalMutation(from: accepted)
    _ = try await store.commit(terminal.mutation)
    try await store.pruneTerminalRequests(before: .distantFuture)
    return PrunedCoordinatorCompletion(
        requestID: requestID,
        callerID: callerID,
        attemptID: terminal.attemptID,
        result: terminal.result
    )
}

private func makeTerminalMutation(
    from accepted: StoredRequest
) throws -> CoordinatorTerminalMutation {
    let attemptID = try #require(AttemptID(rawValue: "attempt-retained"))
    var lifecycle = accepted.lifecycle
    _ = try lifecycle.assign(
        attemptID: attemptID,
        workerID: #require(PeerID(rawValue: "worker-retained")),
        coordinatorIncarnationID: #require(
            CoordinatorIncarnationID(rawValue: "incarnation-retained")
        ),
        leaseDeadline: MonotonicInstant(nanoseconds: 20_000_000_000)
    )
    try lifecycle.accept(attemptID: attemptID)
    _ = try lifecycle.complete(attemptID: attemptID)
    let result = GenerationResult(
        fullText: "Retained coordinator answer",
        modelUsed: try makeCoordinatorModel(),
        finishReason: .stop,
        usage: TokenUsage(promptTokens: 2, outputTokens: 4)
    )
    let mutation = RequestMutation(
        requestID: accepted.submission.requestID,
        callerID: accepted.submission.callerID,
        expectedRevision: accepted.revision,
        lifecycle: lifecycle,
        events: [
            PendingRequestEvent(
                attemptID: attemptID,
                payload: .generation(.completed(result))
            )
        ]
    )
    return CoordinatorTerminalMutation(
        attemptID: attemptID,
        result: result,
        mutation: mutation
    )
}
