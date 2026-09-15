import Foundation
@testable import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage
import Testing

@Suite("Coordinator engine")
struct CoordinatorEngineTests {
    @Test("Connected worker service executes a remote request end to end")
    func executesOnRemoteWorkerService() async throws {
        let fixture = try CoordinatorStoreFixture()
        defer { fixture.remove() }
        let model = try makeCoordinatorModel()
        let workerID = try #require(PeerID(rawValue: "remote-worker"))
        let callerID = try #require(PeerID(rawValue: "caller-1"))
        let workerSession = TestCoordinatorWorkerSession(peerID: workerID)
        let caller = TestCoordinatorCallerSession(peerID: callerID)
        let listener = TestCoordinatorListener()
        let engine = CoordinatorEngine(
            configuration: try makeCoordinatorConfiguration(),
            store: fixture.store,
            scheduler: DefaultSchedulerPolicy(configuration: .standard)
        )
        let workerService = WorkerSessionService(
            configuration: try WorkerSessionConfiguration(
                clusterID: #require(ClusterID(rawValue: "cluster-1")),
                workerID: workerID
            ),
            statusProvider: FixedWorkerStatusProvider(value: try workerStatus(model: model)),
            backend: CompletingInferenceBackend(output: "remote")
        )
        try await engine.start(listener: listener)
        await engine.acceptWorker(workerSession)
        try await workerService.start(
            session: TestWorkerClientSession(coordinatorSession: workerSession)
        )
        await engine.acceptCaller(caller)
        let responses = Task { try await collectUntilCompleted(caller.responses()) }
        let requestID = try #require(RequestID(rawValue: "request-remote"))

        caller.emit(
            try makeSubmitCommand(
                requestID: requestID,
                callerID: callerID,
                model: model
            ))
        let received = try await responses.value

        #expect(received.contains { $0.generationEvent.textDelta.text == "remote" })
        #expect(received.last?.requestStateChanged.state == .completed)
        await workerService.stop()
        await engine.stop()
    }

    @Test("Coordinator executes locally and durably streams completion")
    func executesOnLocalWorker() async throws {
        let fixture = try CoordinatorStoreFixture()
        defer { fixture.remove() }
        let model = try makeCoordinatorModel()
        let workerID = try #require(PeerID(rawValue: "local-worker"))
        let localWorker = try TestLocalWorker(peerID: workerID, model: model)
        let listener = TestCoordinatorListener()
        let callerID = try #require(PeerID(rawValue: "caller-1"))
        let caller = TestCoordinatorCallerSession(peerID: callerID)
        let engine = CoordinatorEngine(
            configuration: try makeCoordinatorConfiguration(),
            store: fixture.store,
            scheduler: DefaultSchedulerPolicy(configuration: .standard),
            localWorker: localWorker
        )
        try await engine.start(listener: listener)
        defer { Task { await engine.stop() } }
        listener.emit(.caller(caller))
        let responses = Task { try await collectUntilCompleted(caller.responses()) }
        let requestID = try #require(RequestID(rawValue: "request-local"))

        caller.emit(
            try makeSubmitCommand(
                requestID: requestID,
                callerID: callerID,
                model: model
            ))
        let received = try await responses.value
        let stored = try await fixture.store.request(requestID: requestID, callerID: callerID)

        #expect(stored?.lifecycle.state == .completed)
        #expect(received.contains { $0.requestAccepted.state == .queued })
        #expect(received.contains { $0.requestStateChanged.state == .assigned })
        #expect(received.contains { $0.requestStateChanged.state == .running })
        #expect(received.contains { $0.generationEvent.textDelta.text == "local" })
        #expect(received.last?.requestStateChanged.state == .completed)
        #expect(await localWorker.startedAttemptIDs.count == 1)
        await engine.stop()
    }

    @Test("Remote interruption retries locally without mixing attempt identity")
    func retriesRemoteAttemptLocally() async throws {
        let fixture = try CoordinatorStoreFixture()
        defer { fixture.remove() }
        let model = try makeCoordinatorModel()
        let localID = try #require(PeerID(rawValue: "z-local"))
        let remoteID = try #require(PeerID(rawValue: "a-remote"))
        let localWorker = try TestLocalWorker(peerID: localID, model: model)
        let listener = TestCoordinatorListener()
        let callerID = try #require(PeerID(rawValue: "caller-1"))
        let caller = TestCoordinatorCallerSession(peerID: callerID)
        let remote = TestCoordinatorWorkerSession(peerID: remoteID)
        let engine = CoordinatorEngine(
            configuration: try makeCoordinatorConfiguration(),
            store: fixture.store,
            scheduler: DefaultSchedulerPolicy(configuration: .standard),
            localWorker: localWorker
        )
        try await engine.start(listener: listener)
        await engine.acceptWorker(remote)
        let status = makeWorkerStatus(workerID: remoteID, model: model).status
        try await engine.updateWorker(
            peerID: remoteID, status: LocalWorkerStatus(wireValue: status))
        await engine.acceptCaller(caller)
        let callerResponses = Task { try await collectUntilCompleted(caller.responses()) }
        let remoteAssignment = Task { try await firstAssignment(remote.responses()) }
        let requestID = try #require(RequestID(rawValue: "request-retry"))

        caller.emit(
            try makeSubmitCommand(
                requestID: requestID,
                callerID: callerID,
                model: model
            ))
        let assignmentResponse = try await remoteAssignment.value
        let assignment = assignmentResponse.assignment
        remote.emit(attemptAccepted(from: assignmentResponse))
        remote.emit(try textDelta("old", from: assignmentResponse))
        remote.disconnect()

        let received = try await callerResponses.value
        await assertRetryResponses(received, assignment: assignment, localWorker: localWorker)
        await engine.stop()
    }

    @Test("Restart reconciliation never trusts an old monotonic lease")
    func reconcilesOldIncarnation() async throws {
        let fixture = try CoordinatorStoreFixture()
        defer { fixture.remove() }
        let seeded = try await seedOldActiveRequest(in: fixture.store)
        let engine = CoordinatorEngine(
            configuration: try makeCoordinatorConfiguration(),
            store: fixture.store,
            scheduler: DefaultSchedulerPolicy(configuration: .standard)
        )

        try await engine.start(listener: TestCoordinatorListener())
        let recovered = try await fixture.store.request(
            requestID: seeded.requestID,
            callerID: seeded.callerID
        )
        let events = try await fixture.store.replay(
            requestID: seeded.requestID,
            callerID: seeded.callerID,
            after: nil,
            limit: 20
        )

        #expect(recovered?.lifecycle.state == .queued)
        #expect(recovered?.lifecycle.activeAttempt == nil)
        #expect(
            events.contains { event in
                guard case .interrupted(_, let willRetry) = event.payload else { return false }
                return willRetry
            })
        await engine.stop()
    }

    @Test("A full queue rejects admission without a durable event cursor")
    func rejectsFullQueue() async throws {
        let storage = try SQLiteStorageConfiguration(
            maximumDatabaseBytes: 256 * 1_024 * 1_024,
            maximumReplayPageSize: 1_000,
            maximumPendingRequests: 1,
            maximumPendingRequestsPerCaller: 1,
            busyTimeout: 1,
            maximumReaderCount: 1
        )
        let fixture = try CoordinatorStoreFixture(configuration: storage)
        defer { fixture.remove() }
        let callerID = try #require(PeerID(rawValue: "caller-1"))
        let caller = TestCoordinatorCallerSession(peerID: callerID)
        let engine = CoordinatorEngine(
            configuration: try makeCoordinatorConfiguration(),
            store: fixture.store,
            scheduler: DefaultSchedulerPolicy(configuration: .standard)
        )
        try await engine.start(listener: TestCoordinatorListener())
        await engine.acceptCaller(caller)
        let rejected = Task { try await firstCommandRejection(caller.responses()) }
        let model = try makeCoordinatorModel()

        caller.emit(
            try makeSubmitCommand(
                requestID: #require(RequestID(rawValue: "request-one")),
                callerID: callerID,
                model: model
            ))
        var second = try makeSubmitCommand(
            requestID: #require(RequestID(rawValue: "request-two")),
            callerID: callerID,
            model: model
        )
        second.submit.request.contextRevision = 2
        caller.emit(second)
        let response = try await rejected.value

        #expect(response.metadata.requestID == "request-two")
        #expect(!response.metadata.hasEventCursor)
        #expect(response.commandRejected.error.code == .resourceExhausted)
        #expect(response.commandRejected.error.retryable)
        await engine.stop()
    }

    @Test("An already-expired submission is rejected before durable acceptance")
    func rejectsExpiredSubmission() async throws {
        let fixture = try CoordinatorStoreFixture()
        defer { fixture.remove() }
        let callerID = try #require(PeerID(rawValue: "caller-1"))
        let caller = TestCoordinatorCallerSession(peerID: callerID)
        let engine = CoordinatorEngine(
            configuration: try makeCoordinatorConfiguration(),
            store: fixture.store,
            scheduler: DefaultSchedulerPolicy(configuration: .standard)
        )
        try await engine.start(listener: TestCoordinatorListener())
        await engine.acceptCaller(caller)
        let rejected = Task { try await firstCommandRejection(caller.responses()) }
        let requestID = try #require(RequestID(rawValue: "request-expired"))
        var command = try makeSubmitCommand(
            requestID: requestID,
            callerID: callerID,
            model: makeCoordinatorModel()
        )
        command.submit.request.deadlineUnixMilliseconds = 1

        caller.emit(command)
        let response = try await rejected.value

        #expect(response.commandRejected.error.code == .deadlineExceeded)
        #expect(
            try await fixture.store.request(requestID: requestID, callerID: callerID) == nil
        )
        await engine.stop()
    }
}

private func workerStatus(model: ModelReference) throws -> LocalWorkerStatus {
    LocalWorkerStatus(
        condition: WorkerCondition(
            participation: .available,
            thermalState: .nominal,
            lowPowerModeEnabled: false
        ),
        load: WorkerLoad(
            activeGenerations: 0,
            generationCapacity: 1,
            availableAppMemoryBytes: 4_000_000_000
        ),
        models: [
            try WorkerModelSnapshot(
                model: model,
                isLoaded: true,
                measuredMemoryBytes: 1_000,
                estimatedLoadDuration: .zero
            )
        ]
    )
}

private func firstAssignment(
    _ stream: WorkerResponseStream
) async throws -> InferPeer_V1_WorkerSessionResponse {
    try await withThrowingTaskGroup(of: InferPeer_V1_WorkerSessionResponse.self) { group in
        group.addTask {
            for try await response in stream {
                if case .assignment = response.payload { return response }
            }
            throw CoordinatorTestError.streamEnded
        }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw CoordinatorTestError.assignmentTimeout
        }
        defer { group.cancelAll() }
        guard let response = try await group.next() else { throw CoordinatorTestError.streamEnded }
        return response
    }
}

func firstCommandRejection(
    _ stream: CallerResponseStream
) async throws -> InferPeer_V1_ClientSessionResponse {
    try await withThrowingTaskGroup(of: InferPeer_V1_ClientSessionResponse.self) { group in
        group.addTask {
            for try await response in stream {
                if case .commandRejected = response.payload { return response }
            }
            throw CoordinatorTestError.streamEnded
        }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw CoordinatorTestError.completionTimeout
        }
        defer { group.cancelAll() }
        guard let response = try await group.next() else { throw CoordinatorTestError.streamEnded }
        return response
    }
}

private func attemptAccepted(
    from assignment: InferPeer_V1_WorkerSessionResponse
) -> InferPeer_V1_WorkerSessionRequest {
    InferPeer_V1_WorkerSessionRequest.with {
        $0.metadata.requestID = assignment.metadata.requestID
        $0.metadata.attemptID = assignment.metadata.attemptID
        $0.attemptAccepted = InferPeer_V1_AttemptAccepted()
    }
}

private func textDelta(
    _ text: String,
    from assignment: InferPeer_V1_WorkerSessionResponse
) throws -> InferPeer_V1_WorkerSessionRequest {
    let delta = try TextDelta(text)
    return InferPeer_V1_WorkerSessionRequest.with {
        $0.metadata.requestID = assignment.metadata.requestID
        $0.metadata.attemptID = assignment.metadata.attemptID
        $0.generationEvent.textDelta = delta.wireValue
    }
}

func storedSubmission(
    requestID: RequestID,
    callerID: PeerID,
    model: ModelReference
) throws -> RequestSubmission {
    let wire = try makeSubmitCommand(requestID: requestID, callerID: callerID, model: model)
    return RequestSubmission(
        requestID: requestID,
        callerID: callerID,
        request: try TextGenerationRequest(wireValue: wire.submit.request),
        contentDigest: try RequestContentDigest(bytes: wire.submit.immutableInputSha256)
    )
}

func accepted(_ acceptance: RequestAcceptance) throws -> StoredRequest {
    switch acceptance {
    case .accepted(let stored): return stored
    case .duplicate: throw CoordinatorTestError.streamEnded
    }
}
