import Foundation
import InferPeerCore
import InferPeerGRPC
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Authenticated direct resource sessions")
struct DirectGRPCSessionManagerTests {
    @Test("Pairing pins the exact endpoint and persists the scoped credential")
    func pairsAndPersistsCredential() async throws {
        let fixture = try SessionFixture()
        let pairing = FakeDirectRPCConnection(
            pairResponse: fixture.pairResponse(credential: Data([1, 2, 3]))
        )
        let authenticated = FakeDirectRPCConnection(helloResponse: fixture.helloResponse())
        await fixture.factory.enqueue(pairing)
        await fixture.factory.enqueue(authenticated)

        let snapshot = try await fixture.manager.pair(fixture.invitation)
        let stored = await fixture.credentials.credential(for: fixture.resourceID)
        let openings = await fixture.factory.recordedOpenings()

        #expect(snapshot.id == fixture.resourceID)
        #expect(stored?.credential == Data([1, 2, 3]))
        #expect(stored?.endpoint == fixture.invitation.endpoint)
        #expect(
            openings.map(\.endpoint) == [fixture.invitation.endpoint, fixture.invitation.endpoint])
        #expect(openings[0].credential == nil)
        #expect(openings[1].credential == Data([1, 2, 3]))
    }

    @Test("Lost StartRun acknowledgement reconciles with GetRun on the same endpoint")
    func reconcilesLostAcceptanceAcknowledgement() async throws {
        let fixture = try SessionFixture()
        try await fixture.storeCredential()
        let first = FakeDirectRPCConnection(
            helloResponse: fixture.helloResponse(),
            startError: InferPeerError(code: .connectionLost, isRetryable: true)
        )
        let completed = fixture.completedEvent(sequence: 1, text: "done")
        let second = FakeDirectRPCConnection(
            helloResponse: fixture.helloResponse(),
            getRunResponse: fixture.getRunResponse(state: .completed, terminal: completed),
            watchEvents: []
        )
        await fixture.factory.enqueue(first)
        await fixture.factory.enqueue(second)

        let execution = try await fixture.manager.run(
            fixture.query,
            resourceID: fixture.resourceID,
            options: fixture.options
        )
        let result = try await execution.result()
        let openings = await fixture.factory.recordedOpenings()

        #expect(result.text == "done")
        #expect(await first.startRequests().count == 1)
        #expect(await second.getRunRequests() == [fixture.requestID.rawValue])
        #expect(openings.allSatisfy { $0.endpoint == fixture.endpoint })
        #expect(await fixture.sleeper.recordedDelays() == [.milliseconds(10)])
    }

    @Test("An unknown acceptance outcome reuses immutable bytes with reduced timeout")
    func retriesUnknownAcceptanceOutcome() async throws {
        let fixture = try SessionFixture()
        try await fixture.storeCredential()
        let first = FakeDirectRPCConnection(
            helloResponse: fixture.helloResponse(),
            startError: InferPeerError(code: .connectionLost, isRetryable: true)
        )
        let second = FakeDirectRPCConnection(
            helloResponse: fixture.helloResponse(),
            startResponse: fixture.startResponse(),
            watchEvents: [fixture.completedEvent(sequence: 1, text: "done")]
        )
        await fixture.factory.enqueue(first)
        await fixture.factory.enqueue(second)

        let execution = try await fixture.manager.run(
            fixture.query,
            resourceID: fixture.resourceID,
            options: fixture.options
        )
        _ = try await execution.result()
        let original = try #require(await first.startRequests().first)
        let retried = try #require(await second.startRequests().first)

        #expect(retried.requestID == original.requestID)
        #expect(retried.specificationBytes == original.specificationBytes)
        #expect(retried.attachmentReceipts == original.attachmentReceipts)
        #expect(original.remainingTimeoutMilliseconds == 60_000)
        #expect(retried.remainingTimeoutMilliseconds == 59_990)
    }

    @Test("Mid-output reconnect resumes after the last applied sequence without duplicates")
    func resumesOutputAfterDisconnect() async throws {
        let fixture = try SessionFixture()
        try await fixture.storeCredential()
        let first = FakeDirectRPCConnection(
            helloResponse: fixture.helloResponse(),
            startResponse: fixture.startResponse(),
            watchEvents: [fixture.textEvent(sequence: 1, text: "hel")],
            watchError: InferPeerError(code: .connectionLost, isRetryable: true)
        )
        let second = FakeDirectRPCConnection(
            helloResponse: fixture.helloResponse(),
            getRunResponse: fixture.getRunResponse(
                state: .running,
                first: 1,
                last: 1
            ),
            watchEvents: [
                fixture.textEvent(sequence: 1, text: "hel"),
                fixture.completedEvent(sequence: 2, text: "hello"),
            ]
        )
        await fixture.factory.enqueue(first)
        await fixture.factory.enqueue(second)

        let execution = try await fixture.manager.run(
            fixture.query,
            resourceID: fixture.resourceID,
            options: fixture.options
        )
        let events = try await collect(execution.events)
        let result = try await execution.result()

        #expect(textDeltas(events) == ["hel"])
        #expect(result.text == "hello")
        #expect(await first.watchCursors() == [0])
        #expect(await second.watchCursors() == [1])
        #expect(await second.acknowledgements() == [1, 2])
    }

    @Test("An unavailable replay prefix fails instead of silently dropping output")
    func rejectsExpiredReplay() async throws {
        let fixture = try SessionFixture()
        try await fixture.storeCredential()
        let first = FakeDirectRPCConnection(
            helloResponse: fixture.helloResponse(),
            startResponse: fixture.startResponse(),
            watchEvents: [fixture.textEvent(sequence: 1, text: "partial")],
            watchError: InferPeerError(code: .connectionLost, isRetryable: true)
        )
        let second = FakeDirectRPCConnection(
            helloResponse: fixture.helloResponse(),
            getRunResponse: fixture.getRunResponse(state: .running, first: 3, last: 4)
        )
        await fixture.factory.enqueue(first)
        await fixture.factory.enqueue(second)

        let execution = try await fixture.manager.run(
            fixture.query,
            resourceID: fixture.resourceID,
            options: fixture.options
        )

        do {
            _ = try await execution.result()
            Issue.record("Expected replay expiry")
        } catch let error as InferPeerError {
            #expect(error.code == .replayExpired)
        }
        #expect(await second.watchCursors().isEmpty)
    }
}

private func collect(_ stream: RunEventStream) async throws -> [RunEvent] {
    var events: [RunEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private func textDeltas(_ events: [RunEvent]) -> [String] {
    events.compactMap {
        guard case .textDelta(let text) = $0 else { return nil }
        return text
    }
}

private struct SessionFixture {
    let resourceID = ResourceID(rawValue: "resource-1")
    let requestID: RequestID
    let model: ModelKey
    let endpoint: PeerEndpoint
    let invitation: ResourcePairingInvitation
    let query: InferenceQuery
    let options: RunOptions
    let credentials = MemoryDirectCredentialStore()
    let factory = FakeDirectRPCConnectionFactory()
    let clock: SessionTestClock
    let sleeper: RecordingDirectSessionSleeper
    let manager: DirectGRPCSessionManager

    init() throws {
        clock = SessionTestClock()
        sleeper = RecordingDirectSessionSleeper(clock: clock)
        guard let invitationID = InvitationID(rawValue: "invite-1") else {
            throw SessionFixtureError.invalidIdentifier
        }
        requestID = try #require(RequestID(rawValue: "request-1"))
        model = try ModelReference(
            modelID: #require(ModelID(rawValue: "model")),
            revision: "1"
        )
        endpoint = try PeerEndpoint(host: "192.168.1.20", port: 9443)
        invitation = try ResourcePairingInvitation(
            protocolMajor: 2,
            invitationID: invitationID,
            resourceID: resourceID,
            endpoint: endpoint,
            certificateFingerprint: CertificateFingerprint(bytes: Data(repeating: 7, count: 32)),
            secret: Data(repeating: 8, count: 32),
            expiresAt: Date(timeIntervalSince1970: 20_000)
        )
        query = .text(model: .exact(model), messages: [.user("Hello")])
        options = RunOptions(
            requestID: requestID,
            totalTimeout: .seconds(60),
            disconnectPolicy: .cancelAfter(.seconds(30))
        )
        manager = DirectGRPCSessionManager(
            credentialStore: credentials,
            connectionFactory: factory,
            wireCodec: FixtureDirectRunWireCodec(model: model),
            reconnectPolicy: .init(maximumAttempts: 3),
            delayProvider: FixedDirectReconnectDelayProvider(delay: .milliseconds(10)),
            sleeper: sleeper,
            clock: clock,
            wallClock: FixedSessionWallClock(date: Date(timeIntervalSince1970: 10_000)),
            eventBufferLimit: 8
        )
    }

    func storeCredential() async throws {
        try await credentials.save(
            DirectResourceCredential(
                resourceID: resourceID,
                endpoint: endpoint,
                certificateFingerprint: invitation.certificateFingerprint,
                credential: Data([1, 2, 3])
            )
        )
    }

    func pairResponse(credential: Data) -> InferPeer_V2_PairResponse {
        InferPeer_V2_PairResponse.with {
            $0.resourceID = resourceID.rawValue
            $0.credential = credential
            $0.snapshot = DirectWireMapper.wireResource(snapshot())
        }
    }

    func helloResponse() -> InferPeer_V2_HelloResponse {
        InferPeer_V2_HelloResponse.with {
            $0.protocolMajor = 2
            $0.protocolMinor = 0
            $0.resourceID = resourceID.rawValue
            $0.incarnation = "incarnation-1"
            $0.maximumMessageBytes = 1_048_576
        }
    }

    func startResponse() -> InferPeer_V2_StartRunResponse {
        InferPeer_V2_StartRunResponse.with {
            $0.requestID = requestID.rawValue
            $0.admittedModel = DirectWireMapper.wireModelKey(model)
            $0.state = .accepted
            $0.incarnation = "incarnation-1"
            $0.firstEventSequence = 1
            $0.originalTimeoutMilliseconds = 60_000
        }
    }

    func getRunResponse(
        state: InferPeer_V2_RunState,
        first: UInt64 = 1,
        last: UInt64 = 1,
        terminal: InferPeer_V2_RunEvent? = nil
    ) -> InferPeer_V2_GetRunResponse {
        InferPeer_V2_GetRunResponse.with {
            $0.requestID = requestID.rawValue
            $0.state = state
            $0.firstAvailableSequence = first
            $0.lastAvailableSequence = last
            if let terminal { $0.terminalEvent = terminal }
        }
    }

    func textEvent(sequence: UInt64, text: String) -> InferPeer_V2_RunEvent {
        wireEvent(sequence: sequence, type: "text", payload: Data(text.utf8))
    }

    func completedEvent(sequence: UInt64, text: String) -> InferPeer_V2_RunEvent {
        wireEvent(sequence: sequence, type: "completed", payload: Data(text.utf8))
    }

    private func wireEvent(
        sequence: UInt64,
        type: String,
        payload: Data
    ) -> InferPeer_V2_RunEvent {
        InferPeer_V2_RunEvent.with {
            $0.requestID = requestID.rawValue
            $0.executionIncarnation = "incarnation-1"
            $0.sequence = sequence
            $0.eventType = type
            $0.boundedPayload = payload
        }
    }

    private func snapshot() -> ResourceSnapshot {
        ResourceSnapshot(
            id: resourceID,
            displayName: "Mac",
            platform: PlatformDescriptor(
                operatingSystem: .macOS,
                operatingSystemVersion: "27"
            ),
            connection: .connected,
            execution: .available,
            capabilities: CapabilitySnapshot(supportedTasks: [.textGeneration]),
            models: [],
            revision: 1
        )
    }
}

private enum SessionFixtureError: Error {
    case invalidIdentifier
}
