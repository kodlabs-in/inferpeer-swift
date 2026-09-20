import InferPeerCore
import InferPeerInference
import InferPeerProtocol

extension DirectGRPCSessionManager {
    func admit(
        requestID: RequestID,
        query: InferenceQuery,
        encoded: EncodedDirectRunSpecification,
        resourceID: ResourceID,
        options: RunOptions
    ) async throws -> Admission {
        let startedAt = clock.now()
        var session = try await session(for: resourceID)
        let request = startRequest(
            requestID: requestID,
            encoded: encoded,
            remaining: options.totalTimeout
        )
        do {
            return try admission(
                from: await session.connection.startRun(request),
                requestID: requestID
            )
        } catch {
            guard isConnectionLoss(error) else { throw error }
        }

        invalidate(resourceID, matching: session)
        guard reconnectPolicy.maximumAttempts > 1 else {
            throw InferPeerError(code: .connectionLost, isRetryable: true)
        }
        for attempt in 2...reconnectPolicy.maximumAttempts {
            try await sleep(beforeAttempt: attempt)
            let remaining = try remaining(options.totalTimeout, since: startedAt)
            do {
                session = try await connectOnce(resourceID)
                var retryRequest = request
                retryRequest.remainingTimeoutMilliseconds = DirectWireMapper.durationMilliseconds(
                    remaining
                )
                return try await reconcile(
                    requestID: requestID,
                    query: query,
                    originalRequest: retryRequest,
                    session: session
                )
            } catch {
                guard isConnectionLoss(error) else { throw error }
                invalidate(resourceID, matching: session)
            }
        }
        throw InferPeerError(code: .connectionLost, isRetryable: true)
    }

    func reconcile(
        requestID: RequestID,
        query: InferenceQuery,
        originalRequest: InferPeer_V2_StartRunRequest,
        session: Session
    ) async throws -> Admission {
        do {
            let response = try await session.connection.getRun(
                InferPeer_V2_GetRunRequest.with { $0.requestID = requestID.rawValue }
            )
            return try admission(
                from: response,
                query: query,
                incarnation: session.incarnation,
                requestID: requestID
            )
        } catch let error as InferPeerError where error.code == .outcomeUnknown {
            return try admission(
                from: await session.connection.startRun(originalRequest),
                requestID: requestID
            )
        }
    }

    func makeExecution(
        requestID: RequestID,
        resourceID: ResourceID,
        admission: Admission,
        disconnectPolicy: RunDisconnectPolicy,
        attachmentReceipts: [String] = []
    ) -> RemoteRunExecution {
        let state = DirectRemoteRunState(
            initialStatus: admission.status,
            eventBufferLimit: eventBufferLimit
        )
        let context = WatchContext(
            requestID: requestID,
            resourceID: resourceID,
            expectedIncarnation: admission.incarnation,
            terminalEvent: admission.terminalEvent,
            grace: disconnectPolicy.grace,
            state: state,
            attachmentReceipts: attachmentReceipts
        )
        Task { await watch(context) }
        return RemoteRunExecution(
            requestID: requestID,
            resourceID: resourceID,
            events: state.events,
            result: { try await state.result() },
            cancel: { [weak self] in
                await self?.cancel(requestID: requestID, resourceID: resourceID)
            },
            status: { await state.status() }
        )
    }

    func watch(_ context: WatchContext) async {
        defer {
            Task {
                await releaseAssets(
                    context.attachmentReceipts,
                    resourceID: context.resourceID
                )
            }
        }
        if let terminalEvent = context.terminalEvent {
            await applyTerminalReplacement(terminalEvent, context: context)
            return
        }
        var disconnectedAt: MonotonicInstant?
        var attempts = 0
        while attempts < reconnectPolicy.maximumAttempts {
            do {
                try await watchOnce(context, reconnecting: attempts > 0)
                guard !(await context.state.status()).isTerminal else { return }
                throw InferPeerError(code: .connectionLost, isRetryable: true)
            } catch {
                let now = clock.now()
                let graceStartedAt = disconnectedAt ?? now
                disconnectedAt = graceStartedAt
                guard isConnectionLoss(error), now.elapsed(since: graceStartedAt) < context.grace
                else {
                    await context.state.fail(publicError(error))
                    return
                }
                attempts += 1
                do {
                    try await sleep(beforeAttempt: attempts + 1)
                } catch {
                    await context.state.fail(publicError(error))
                    return
                }
            }
        }
        await context.state.fail(InferPeerError(code: .connectionLost, isRetryable: true))
    }

    func watchOnce(_ context: WatchContext, reconnecting: Bool) async throws {
        let session: Session
        if reconnecting {
            session = try await connectOnce(context.resourceID)
        } else {
            session = try await self.session(for: context.resourceID)
        }
        do {
            try requireIncarnation(session.incarnation, expected: context.expectedIncarnation)
            if reconnecting {
                try await reconcileReplay(
                    requestID: context.requestID,
                    session: session,
                    state: context.state
                )
                guard !(await context.state.status()).isTerminal else { return }
            }
            let cursor = await context.state.latestSequence()
            try await session.connection.watchRun(
                requestID: context.requestID,
                resumeAfterSequence: cursor
            ) { event in
                try await self.apply(
                    event,
                    requestID: context.requestID,
                    incarnation: context.expectedIncarnation,
                    state: context.state
                )
            }
        } catch {
            invalidate(context.resourceID, matching: session)
            throw error
        }
    }

    func reconcileReplay(
        requestID: RequestID,
        session: Session,
        state: DirectRemoteRunState
    ) async throws {
        let response = try await session.connection.getRun(
            InferPeer_V2_GetRunRequest.with { $0.requestID = requestID.rawValue }
        )
        try requireRequestID(response.requestID, expected: requestID)
        let cursor = await state.latestSequence()
        if response.hasTerminalEvent {
            try requireRequestID(response.terminalEvent.requestID, expected: requestID)
            try requireIncarnation(
                response.terminalEvent.executionIncarnation,
                expected: session.incarnation
            )
            try await state.applyTerminalReplacement(
                sequence: response.terminalEvent.sequence,
                event: wireCodec.decode(response.terminalEvent)
            )
            return
        }
        guard
            response.firstAvailableSequence == 0
                || cursor + 1 >= response.firstAvailableSequence
        else {
            throw InferPeerError(code: .replayExpired, isRetryable: false)
        }
    }

    func apply(
        _ wireEvent: InferPeer_V2_RunEvent,
        requestID: RequestID,
        incarnation: String,
        state: DirectRemoteRunState
    ) async throws -> UInt64 {
        try requireRequestID(wireEvent.requestID, expected: requestID)
        try requireIncarnation(wireEvent.executionIncarnation, expected: incarnation)
        return try await state.apply(
            sequence: wireEvent.sequence,
            event: wireCodec.decode(wireEvent)
        )
    }

    func applyTerminalReplacement(
        _ wireEvent: InferPeer_V2_RunEvent,
        context: WatchContext
    ) async {
        do {
            try requireRequestID(wireEvent.requestID, expected: context.requestID)
            try requireIncarnation(
                wireEvent.executionIncarnation,
                expected: context.expectedIncarnation
            )
            try await context.state.applyTerminalReplacement(
                sequence: wireEvent.sequence,
                event: wireCodec.decode(wireEvent)
            )
        } catch {
            await context.state.fail(publicError(error))
        }
    }
}
