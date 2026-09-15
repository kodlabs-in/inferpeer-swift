import InferPeerCore
@testable import InferPeerGRPC
import InferPeerProtocol
import Testing

@Suite("gRPC peer transport", .serialized)
struct GRPCPeerTransportTests {
    @Test("mutual TLS carries a bounded caller session in both directions")
    func callerSessionRoundTrip() async throws {
        let harness = try await GRPCTestHarness.make(clientRoles: [.caller])
        let inboundTask = firstTask(in: harness.listener.sessions(bufferingLimit: 4))
        let caller = try await harness.clientTransport.connectCaller(to: harness.endpoint)
        let inbound = try await inboundTask.value
        guard case .caller(let coordinator) = inbound else {
            Issue.record("Expected caller session")
            return
        }

        let request = InferPeer_V1_ClientSessionRequest.with {
            $0.metadata = makeMetadata(
                clusterID: harness.clusterID,
                senderID: harness.clientIdentity.credentials.identity.peerID,
                sequence: 2
            )
            $0.resume.afterEventCursor = 7
        }
        let requestTask = firstTask(in: coordinator.requests(bufferingLimit: 4))
        try await caller.send(request)
        let receivedRequest = try await requestTask.value
        #expect(receivedRequest.resume.afterEventCursor == 7)
        #expect(
            coordinator.authenticatedPeerID == harness.clientIdentity.credentials.identity.peerID)

        let response = InferPeer_V1_ClientSessionResponse.with {
            $0.metadata = makeMetadata(
                clusterID: harness.clusterID,
                senderID: harness.serverIdentity.credentials.identity.peerID,
                sequence: 2
            )
            $0.requestAccepted.state = .queued
        }
        let responseTask = firstTask(in: caller.responses(bufferingLimit: 4))
        try await coordinator.send(response)
        let receivedResponse = try await responseTask.value
        #expect(receivedResponse.requestAccepted.state == .queued)

        await harness.stop()
    }

    @Test("mutual TLS carries a worker session in both directions")
    func workerSessionRoundTrip() async throws {
        let harness = try await GRPCTestHarness.make(clientRoles: [.worker])
        let inboundTask = firstTask(in: harness.listener.sessions(bufferingLimit: 4))
        let worker = try await harness.clientTransport.connectWorker(to: harness.endpoint)
        let inbound = try await inboundTask.value
        guard case .worker(let coordinator) = inbound else {
            Issue.record("Expected worker session")
            return
        }

        let request = InferPeer_V1_WorkerSessionRequest.with {
            $0.metadata = makeMetadata(
                clusterID: harness.clusterID,
                senderID: harness.clientIdentity.credentials.identity.peerID,
                sequence: 2
            )
            $0.leaseRenewal.requestedDurationMilliseconds = 1_000
        }
        let requestTask = firstTask(in: coordinator.requests(bufferingLimit: 4))
        try await worker.send(request)
        let receivedRequest = try await requestTask.value
        #expect(receivedRequest.leaseRenewal.requestedDurationMilliseconds == 1_000)

        let response = InferPeer_V1_WorkerSessionResponse.with {
            $0.metadata = makeMetadata(
                clusterID: harness.clusterID,
                senderID: harness.serverIdentity.credentials.identity.peerID,
                sequence: 2
            )
            $0.leaseExtended.leaseDurationMilliseconds = 2_000
        }
        let responseTask = firstTask(in: worker.responses(bufferingLimit: 4))
        try await coordinator.send(response)
        let receivedResponse = try await responseTask.value
        #expect(receivedResponse.leaseExtended.leaseDurationMilliseconds == 2_000)

        await harness.stop()
    }

    @Test("slow worker consumer preserves control traffic after saturated text deltas")
    func slowWorkerConsumerPreservesControlTraffic() async throws {
        let harness = try await GRPCTestHarness.make(clientRoles: [.worker])
        let inboundTask = firstTask(in: harness.listener.sessions(bufferingLimit: 4))
        let worker = try await harness.clientTransport.connectWorker(to: harness.endpoint)
        let inbound = try await inboundTask.value
        guard case .worker(let coordinator) = inbound else {
            Issue.record("Expected worker session")
            return
        }
        let requests = coordinator.requests(bufferingLimit: 4)
        let producer = Task {
            for sequence in 2...5 {
                try await worker.send(
                    workerTextRequest(sequence: UInt64(sequence), harness: harness)
                )
            }
            try await worker.send(workerLeaseRequest(sequence: 6, harness: harness))
            try await worker.send(workerTextRequest(sequence: 7, harness: harness))
        }
        try await Task.sleep(for: .milliseconds(50))

        let received = try await collect(6, from: requests)
        try await producer.value

        #expect(received.map(\.metadata.sequence) == Array(2...7).map(UInt64.init))
        #expect(received[4].leaseRenewal.requestedDurationMilliseconds == 1_000)
        await harness.stop()
    }

    @Test("coordinator rejects a certificate-bound but unauthorized peer")
    func unauthorizedPeerIsRejected() async throws {
        let harness = try await GRPCTestHarness.make(
            clientRoles: [.caller],
            authorizeClient: false
        )

        await #expect(throws: InferPeerGRPCError.self) {
            _ = try await harness.clientTransport.connectCaller(to: harness.endpoint)
        }

        await harness.stop()
    }

    @Test("TLS rejects a coordinator whose certificate does not match its endpoint pin")
    func incorrectCoordinatorPinIsRejected() async throws {
        let harness = try await GRPCTestHarness.make(
            clientRoles: [.caller],
            coordinatorPinMatches: false
        )

        await #expect(throws: InferPeerGRPCError.self) {
            _ = try await harness.clientTransport.connectCaller(to: harness.endpoint)
        }

        await harness.stop()
    }

    @Test("closing a client session releases its transport retention")
    func closedSessionIsReleased() async throws {
        let harness = try await GRPCTestHarness.make(clientRoles: [.caller])
        let inboundTask = firstTask(in: harness.listener.sessions(bufferingLimit: 4))
        let caller = try await harness.clientTransport.connectCaller(to: harness.endpoint)
        _ = try await inboundTask.value
        #expect(await harness.clientTransport.activeClientSessionCount() == 1)

        await caller.close()
        for _ in 0..<10 {
            if await harness.clientTransport.activeClientSessionCount() == 0 { break }
            await Task.yield()
        }

        #expect(await harness.clientTransport.activeClientSessionCount() == 0)
        await harness.stop()
    }

    @Test("caller rejects metadata with an unbound sender or skipped sequence")
    func callerRejectsInvalidOutboundMetadata() async throws {
        let harness = try await GRPCTestHarness.make(clientRoles: [.caller])
        let inboundTask = firstTask(in: harness.listener.sessions(bufferingLimit: 4))
        let caller = try await harness.clientTransport.connectCaller(to: harness.endpoint)
        _ = try await inboundTask.value

        let wrongSender = InferPeer_V1_ClientSessionRequest.with {
            $0.metadata = makeMetadata(
                clusterID: harness.clusterID,
                senderID: harness.serverIdentity.credentials.identity.peerID,
                sequence: 2
            )
            $0.resume.afterEventCursor = 1
        }
        await #expect(throws: InferPeerGRPCError.self) {
            try await caller.send(wrongSender)
        }

        let skippedSequence = InferPeer_V1_ClientSessionRequest.with {
            $0.metadata = makeMetadata(
                clusterID: harness.clusterID,
                senderID: harness.clientIdentity.credentials.identity.peerID,
                sequence: 3
            )
            $0.resume.afterEventCursor = 1
        }
        await #expect(throws: InferPeerGRPCError.self) {
            try await caller.send(skippedSequence)
        }

        await harness.stop()
    }

}

private func workerTextRequest(
    sequence: UInt64,
    harness: GRPCTestHarness
) -> InferPeer_V1_WorkerSessionRequest {
    InferPeer_V1_WorkerSessionRequest.with {
        $0.metadata = makeMetadata(
            clusterID: harness.clusterID,
            senderID: harness.clientIdentity.credentials.identity.peerID,
            sequence: sequence
        )
        $0.generationEvent.textDelta.text = "delta-\(sequence)"
    }
}

private func workerLeaseRequest(
    sequence: UInt64,
    harness: GRPCTestHarness
) -> InferPeer_V1_WorkerSessionRequest {
    InferPeer_V1_WorkerSessionRequest.with {
        $0.metadata = makeMetadata(
            clusterID: harness.clusterID,
            senderID: harness.clientIdentity.credentials.identity.peerID,
            sequence: sequence
        )
        $0.leaseRenewal.requestedDurationMilliseconds = 1_000
    }
}

private func collect<Element: Sendable>(
    _ count: Int,
    from stream: TransportMessageStream<Element>
) async throws -> [Element] {
    try await withThrowingTaskGroup(of: [Element].self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            var elements: [Element] = []
            while elements.count < count {
                elements.append(try #require(try await iterator.next()))
            }
            return elements
        }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw InferPeerGRPCError.deadlineExceeded
        }
        defer { group.cancelAll() }
        return try await group.next() ?? []
    }
}

private struct GRPCTestHarness: Sendable {
    let clusterID: ClusterID
    let endpoint: PeerEndpoint
    let serverIdentity: GRPCTestIdentity
    let clientIdentity: GRPCTestIdentity
    let serverTransport: GRPCPeerTransport
    let clientTransport: GRPCPeerTransport
    let listener: any CoordinatorTransportListener

    static func make(
        clientRoles: Set<NodeRole>,
        authorizeClient: Bool = true,
        coordinatorPinMatches: Bool = true
    ) async throws -> Self {
        let setup = try await GRPCTestSetup.make(
            clientRoles: clientRoles,
            authorizeClient: authorizeClient,
            coordinatorPinMatches: coordinatorPinMatches
        )
        let serverTransport = GRPCPeerTransport(configuration: try setup.serverConfiguration())
        let listener = try await serverTransport.listen(at: setup.endpoint)
        return Self(
            clusterID: setup.clusterID,
            endpoint: setup.endpoint,
            serverIdentity: setup.serverIdentity,
            clientIdentity: setup.clientIdentity,
            serverTransport: serverTransport,
            clientTransport: GRPCPeerTransport(configuration: try setup.clientConfiguration()),
            listener: listener
        )
    }

    func stop() async {
        await clientTransport.stop()
        await serverTransport.stop()
    }
}

private struct GRPCTestSetup: Sendable {
    let clusterID: ClusterID
    let incarnationID: CoordinatorIncarnationID
    let endpoint: PeerEndpoint
    let networkPolicy: GRPCNetworkPolicy
    let serverIdentity: GRPCTestIdentity
    let clientIdentity: GRPCTestIdentity
    let clientRoles: Set<NodeRole>
    let authorizeClient: Bool
    let coordinatorPinMatches: Bool

    static func make(
        clientRoles: Set<NodeRole>,
        authorizeClient: Bool,
        coordinatorPinMatches: Bool
    ) async throws -> Self {
        let clusterID = try #require(ClusterID(rawValue: "cluster-test"))
        let incarnationID = try #require(CoordinatorIncarnationID(rawValue: "coordinator-run"))
        let endpoint = try makeGRPCEndpoint()
        return try await Self(
            clusterID: clusterID,
            incarnationID: incarnationID,
            endpoint: endpoint,
            networkPolicy: makeNetworkPolicy(endpoint: endpoint),
            serverIdentity: makeGRPCTestIdentity(),
            clientIdentity: makeGRPCTestIdentity(),
            clientRoles: clientRoles,
            authorizeClient: authorizeClient,
            coordinatorPinMatches: coordinatorPinMatches
        )
    }

    func serverConfiguration() throws -> GRPCTransportConfiguration {
        let allowedPeerID = authorizeClient ? clientIdentity.credentials.identity.peerID : nil
        return try GRPCTransportConfiguration(
            clusterID: clusterID,
            credentials: serverIdentity.transportCredentials,
            enabledRoles: [.coordinator],
            coordinatorIncarnationID: incarnationID,
            coordinatorPins: [],
            certificateVerifier: makeCertificateVerifier(),
            sessionAuthorizer: makeAuthorizer(allowing: allowedPeerID),
            networkPolicy: networkPolicy,
            streamBufferLimit: 4
        )
    }

    func clientConfiguration() throws -> GRPCTransportConfiguration {
        let fingerprint =
            coordinatorPinMatches
            ? serverIdentity.credentials.identity.certificateFingerprint
            : clientIdentity.credentials.identity.certificateFingerprint
        return try GRPCTransportConfiguration(
            clusterID: clusterID,
            credentials: clientIdentity.transportCredentials,
            enabledRoles: clientRoles,
            coordinatorPins: [
                GRPCCoordinatorPin(
                    endpoint: endpoint,
                    certificateFingerprint: fingerprint
                )
            ],
            certificateVerifier: makeCertificateVerifier(),
            sessionAuthorizer: makeAuthorizer(allowing: nil),
            networkPolicy: networkPolicy,
            streamBufferLimit: 4
        )
    }
}
