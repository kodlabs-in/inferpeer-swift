import Foundation
import InferPeerCore
import InferPeerGRPC
import InferPeerProtocol

extension DirectResourceHostHandler {
    /// Streams retained and live events from a client-supplied replay cursor.
    public func watchRun(
        _ requests: DirectRPCStream<InferPeer_V2_WatchRunRequest>
    ) async throws -> DirectRPCStream<InferPeer_V2_WatchRunResponse> {
        let principal = try requirePrincipal()
        var iterator = requests.makeAsyncIterator()
        guard let first = try await iterator.next(),
            let requestID = RequestID(rawValue: first.requestID),
            case .resumeAfterSequence(let cursor)? = first.operation
        else {
            throw InferPeerError(code: .invalidRequest, isRetryable: false)
        }
        let key = RunKey(principalID: principal, requestID: requestID)
        let subscription = try subscribe(key: key, after: cursor)
        let controlTask = Task { [weak self] in
            do {
                var remaining = iterator
                while let control = try await remaining.next() {
                    guard control.requestID == requestID.rawValue,
                        case .acknowledgeSequence? = control.operation
                    else {
                        throw InferPeerError(code: .invalidRequest, isRetryable: false)
                    }
                }
            } catch {
                await self?.removeWatcher(subscription.id, key: key)
            }
        }
        subscription.continuation.onTermination = { [weak self] _ in
            controlTask.cancel()
            Task { await self?.removeWatcher(subscription.id, key: key) }
        }
        return subscription.stream
    }

    // Async is required by the service protocol; actor state is already isolated.
    // swiftlint:disable async_without_await
    /// Reconciles one owner-scoped run's retained state and sequence range.
    public func getRun(
        _ request: InferPeer_V2_GetRunRequest
    ) async throws -> InferPeer_V2_GetRunResponse {
        let principal = try requirePrincipal()
        guard let requestID = RequestID(rawValue: request.requestID),
            let run = runs[RunKey(principalID: principal, requestID: requestID)]
        else {
            throw InferPeerError(code: .outcomeUnknown, isRetryable: true)
        }
        return InferPeer_V2_GetRunResponse.with {
            $0.requestID = request.requestID
            $0.state = DirectWireMapper.wireRunState(run.status)
            $0.firstAvailableSequence = run.events.first?.sequence ?? 0
            $0.lastAvailableSequence = run.events.last?.sequence ?? 0
            if let terminal = run.terminalEvent { $0.terminalEvent = terminal }
        }
    }
    // swiftlint:enable async_without_await

    private func subscribe(
        key: RunKey,
        after sequence: UInt64
    ) throws -> (
        id: UUID,
        stream: DirectRPCStream<InferPeer_V2_WatchRunResponse>,
        continuation: DirectRPCStream<InferPeer_V2_WatchRunResponse>.Continuation
    ) {
        guard var run = runs[key] else {
            throw InferPeerError(code: .outcomeUnknown, isRetryable: true)
        }
        let nextSequence = sequence.addingReportingOverflow(1)
        guard !nextSequence.overflow else {
            throw InferPeerError(code: .invalidRequest, isRetryable: false)
        }
        let first = run.events.first?.sequence ?? nextSequence.partialValue
        guard nextSequence.partialValue >= first else {
            throw InferPeerError(code: .replayExpired, isRetryable: false)
        }
        guard run.status.isHostTerminal || run.watchers.count < Self.maximumWatchersPerRun else {
            throw InferPeerError(code: .resourceExhausted, isRetryable: true)
        }
        let pair = DirectRPCStream<InferPeer_V2_WatchRunResponse>.makeStream(
            bufferingPolicy: .bufferingOldest(64)
        )
        for event in run.events where event.sequence > sequence {
            pair.continuation.yield(
                InferPeer_V2_WatchRunResponse.with { $0.event = event }
            )
        }
        let id = UUID()
        if run.status.isHostTerminal {
            pair.continuation.finish()
        } else {
            run.watchers[id] = pair.continuation
            runs[key] = run
        }
        return (id, pair.stream, pair.continuation)
    }

    private func removeWatcher(_ id: UUID, key: RunKey) {
        runs[key]?.watchers[id] = nil
    }
}
