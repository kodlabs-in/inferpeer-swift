import Foundation
import InferPeerProtocol

/// Bounded same-process replay, acknowledgement, deduplication, and grace coordinator.
public actor DirectRunReplayStore {
    private struct TerminalRecord: Sendable {
        let sequence: UInt64
        let kind: RunTerminalKind
        var outcome: RunTerminalOutcome?
        let committedAt: MonotonicInstant
        let retainedByteCount: UInt64
    }

    private struct RunState: Sendable {
        let immutableRequestDigest: Data
        var nextSequence: UInt64 = 1
        var acknowledgedThrough: UInt64 = 0
        var events: [SequencedRunEvent] = []
        var retainedByteCount: UInt64 = 0
        var disconnectedAt: MonotonicInstant?
        var cancellationRequested = false
        var terminal: TerminalRecord?
    }

    private let configuration: ReplayBufferConfiguration
    private let clock: any CoreClock
    private var runs: [RequestID: RunState] = [:]
    private var resourceRetainedByteCount: UInt64 = 0

    /// Creates a replay owner for one resource process incarnation.
    public init(
        configuration: ReplayBufferConfiguration = .standard,
        clock: any CoreClock = SystemCoreClock()
    ) {
        self.configuration = configuration
        self.clock = clock
    }

    /// Registers immutable request content or identifies a lost-ACK retry.
    public func register(
        requestID: RequestID,
        immutableRequestDigest: Data
    ) throws -> ReplayRunRegistration {
        guard !immutableRequestDigest.isEmpty else {
            throw DirectRunReplayError.invalidImmutableRequestDigest
        }
        if let existing = runs[requestID] {
            guard existing.immutableRequestDigest == immutableRequestDigest else {
                throw DirectRunReplayError.requestConflict
            }
            return .duplicate
        }
        runs[requestID] = RunState(immutableRequestDigest: immutableRequestDigest)
        return .accepted
    }

    /// Offers an event without exceeding either configured byte budget.
    public func offer(
        _ event: RunEvent,
        retainedByteCount: UInt64,
        to requestID: RequestID
    ) throws -> ReplayAppendDisposition {
        guard retainedByteCount > 0 else {
            throw DirectRunReplayError.invalidRetainedByteCount
        }
        guard var state = runs[requestID] else {
            throw DirectRunReplayError.unknownRequest
        }
        if let terminal = state.terminal {
            guard event.directTerminalOutcome != nil else {
                throw DirectRunReplayError.eventAfterTerminal
            }
            return .alreadyTerminal(terminal.kind)
        }
        if let scope = exceededBudget(for: state, adding: retainedByteCount) {
            return budgetDisposition(scope: scope, requestID: requestID, state: &state)
        }
        guard state.nextSequence < UInt64.max else {
            throw DirectRunReplayError.sequenceExhausted
        }

        let sequenced = SequencedRunEvent(
            requestID: requestID,
            sequence: state.nextSequence,
            event: event,
            retainedByteCount: retainedByteCount
        )
        state.nextSequence += 1
        state.events.append(sequenced)
        state.retainedByteCount += retainedByteCount
        resourceRetainedByteCount += retainedByteCount
        commitTerminalIfNeeded(event, sequenced: sequenced, state: &state)
        runs[requestID] = state
        return .appended(sequenced)
    }

    /// Appends an event or throws when its producer must suspend or cancel.
    public func append(
        _ event: RunEvent,
        retainedByteCount: UInt64,
        to requestID: RequestID
    ) throws -> SequencedRunEvent {
        let disposition = try offer(
            event,
            retainedByteCount: retainedByteCount,
            to: requestID
        )
        switch disposition {
        case .appended(let sequenced):
            return sequenced
        case .alreadyTerminal:
            throw DirectRunReplayError.eventAfterTerminal
        case .backpressured(let scope):
            throw DirectRunReplayError.backpressureRequired(scope)
        case .cancellationRequired(let code):
            throw DirectRunReplayError.cancellationRequired(code)
        }
    }

    /// Returns events after a consumer cursor or a precise expired/ahead error.
    public func replay(
        after sequence: UInt64,
        for requestID: RequestID
    ) throws -> [SequencedRunEvent] {
        guard let state = runs[requestID] else {
            throw DirectRunReplayError.unknownRequest
        }
        let latest = state.nextSequence - 1
        guard sequence <= latest else {
            throw DirectRunReplayError.cursorAhead(latestAvailable: latest)
        }
        guard sequence < latest else { return [] }
        guard let first = state.events.first?.sequence else {
            throw DirectRunReplayError.replayExpired(earliestAvailable: nil)
        }
        guard sequence + 1 >= first else {
            throw DirectRunReplayError.replayExpired(earliestAvailable: first)
        }
        return state.events.filter { $0.sequence > sequence }
    }

    /// Reclaims an acknowledged contiguous prefix while preserving terminal content.
    public func acknowledge(through sequence: UInt64, for requestID: RequestID) throws {
        guard var state = runs[requestID] else {
            throw DirectRunReplayError.unknownRequest
        }
        let latest = state.nextSequence - 1
        guard sequence <= latest else {
            throw DirectRunReplayError.invalidAcknowledgement(latestAvailable: latest)
        }
        guard sequence >= state.acknowledgedThrough else {
            throw DirectRunReplayError.acknowledgementRegressed
        }

        let removed = state.events.prefix { $0.sequence <= sequence }
        let terminalSequence = state.terminal?.sequence
        let reclaimed = removed.reduce(UInt64.zero) { partial, event in
            event.sequence == terminalSequence ? partial : partial + event.retainedByteCount
        }
        state.events.removeFirst(removed.count)
        state.acknowledgedThrough = sequence
        state.retainedByteCount -= reclaimed
        resourceRetainedByteCount -= reclaimed
        runs[requestID] = state
    }

    /// Starts the bounded same-resource reconnect grace period.
    public func markDisconnected(_ requestID: RequestID) throws {
        guard var state = runs[requestID] else {
            throw DirectRunReplayError.unknownRequest
        }
        guard state.terminal == nil else { return }
        if state.disconnectedAt == nil {
            state.disconnectedAt = clock.now()
            runs[requestID] = state
        }
    }

    /// Clears a disconnect that recovered before cancellation became required.
    public func markConnected(_ requestID: RequestID) throws {
        guard var state = runs[requestID] else {
            throw DirectRunReplayError.unknownRequest
        }
        guard !state.cancellationRequested else { return }
        state.disconnectedAt = nil
        runs[requestID] = state
    }

    /// Marks disconnected runs whose recovery grace elapsed for cooperative cancellation.
    public func cancellationsRequired() -> [ReplayCancellation] {
        let now = clock.now()
        var cancellations: [ReplayCancellation] = []
        for requestID in runs.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard var state = runs[requestID] else { continue }
            guard shouldCancelForDisconnect(state, at: now) else { continue }
            state.cancellationRequested = true
            runs[requestID] = state
            cancellations.append(
                ReplayCancellation(requestID: requestID, reason: .connectionLost)
            )
        }
        return cancellations
    }

    /// Drops acknowledged terminal content after its retention while keeping dedup metadata.
    @discardableResult
    public func expireRetainedTerminalContent() -> [RequestID] {
        let now = clock.now()
        var expired: [RequestID] = []
        for requestID in runs.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard var state = runs[requestID] else { continue }
            guard expireTerminalContent(in: &state, at: now) else { continue }
            runs[requestID] = state
            expired.append(requestID)
        }
        return expired
    }

    /// Returns a wire-ready current replay/status view for ambiguity resolution.
    public func snapshot(for requestID: RequestID) throws -> DirectRunReplaySnapshot {
        guard let state = runs[requestID] else {
            throw DirectRunReplayError.unknownRequest
        }
        return makeSnapshot(state)
    }

    /// Returns resource-wide retained bytes and registration count.
    public func usage() -> ReplayResourceUsage {
        ReplayResourceUsage(
            retainedByteCount: resourceRetainedByteCount,
            byteLimit: configuration.resourceWideByteLimit,
            registeredRunCount: runs.count
        )
    }
}

private extension DirectRunReplayStore {
    private func exceededBudget(
        for state: RunState,
        adding byteCount: UInt64
    ) -> ReplayBudgetScope? {
        guard
            !wouldExceed(
                state.retainedByteCount, adding: byteCount,
                limit: configuration.perRunByteLimit)
        else {
            return .perRun
        }
        guard
            !wouldExceed(
                resourceRetainedByteCount, adding: byteCount,
                limit: configuration.resourceWideByteLimit)
        else {
            return .resourceWide
        }
        return nil
    }

    private func wouldExceed(_ current: UInt64, adding: UInt64, limit: UInt64) -> Bool {
        let sum = current.addingReportingOverflow(adding)
        return sum.overflow || sum.partialValue > limit
    }

    private func budgetDisposition(
        scope: ReplayBudgetScope,
        requestID: RequestID,
        state: inout RunState
    ) -> ReplayAppendDisposition {
        guard state.disconnectedAt != nil else { return .backpressured(scope) }
        state.cancellationRequested = true
        runs[requestID] = state
        return .cancellationRequired(.outputBackpressure)
    }

    private func commitTerminalIfNeeded(
        _ event: RunEvent,
        sequenced: SequencedRunEvent,
        state: inout RunState
    ) {
        guard let outcome = event.directTerminalOutcome else { return }
        state.terminal = TerminalRecord(
            sequence: sequenced.sequence,
            kind: outcome.kind,
            outcome: outcome,
            committedAt: clock.now(),
            retainedByteCount: sequenced.retainedByteCount
        )
        state.disconnectedAt = nil
        state.cancellationRequested = false
    }

    private func shouldCancelForDisconnect(
        _ state: RunState,
        at now: MonotonicInstant
    ) -> Bool {
        guard state.terminal == nil, !state.cancellationRequested else { return false }
        guard let disconnectedAt = state.disconnectedAt else { return false }
        return now.elapsed(since: disconnectedAt) >= configuration.disconnectGrace
    }

    private func expireTerminalContent(
        in state: inout RunState,
        at now: MonotonicInstant
    ) -> Bool {
        guard var terminal = state.terminal, terminal.outcome != nil else { return false }
        guard state.acknowledgedThrough >= terminal.sequence else { return false }
        guard now.elapsed(since: terminal.committedAt) >= configuration.terminalRetention else {
            return false
        }
        terminal.outcome = nil
        state.terminal = terminal
        state.retainedByteCount -= terminal.retainedByteCount
        resourceRetainedByteCount -= terminal.retainedByteCount
        return true
    }

    private func makeSnapshot(_ state: RunState) -> DirectRunReplaySnapshot {
        let range = state.events.first.flatMap { first in
            state.events.last.map { RunReplayRange(first: first.sequence, last: $0.sequence) }
        }
        return DirectRunReplaySnapshot(
            latestSequence: state.nextSequence - 1,
            acknowledgedThrough: state.acknowledgedThrough,
            replayRange: range,
            retainedByteCount: state.retainedByteCount,
            connection: connection(for: state),
            terminal: state.terminal.map(makeTerminalSnapshot)
        )
    }

    private func connection(for state: RunState) -> RunReplayConnection {
        if state.cancellationRequested { return .cancellationRequired }
        guard let disconnectedAt = state.disconnectedAt else { return .connected }
        return .disconnected(
            graceDeadline: disconnectedAt.advanced(by: configuration.disconnectGrace)
        )
    }

    private func makeTerminalSnapshot(_ record: TerminalRecord) -> RunTerminalSnapshot {
        RunTerminalSnapshot(
            sequence: record.sequence,
            kind: record.kind,
            outcome: record.outcome
        )
    }
}
