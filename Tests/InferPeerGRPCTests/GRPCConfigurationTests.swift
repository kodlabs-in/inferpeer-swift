import Foundation
@testable import InferPeerGRPC
import InferPeerCore
import InferPeerProtocol
import Testing
import X509

@Suite("gRPC configuration")
struct GRPCConfigurationTests {
    @Test("transport errors expose a named diagnostic instead of an enum ordinal")
    func transportErrorDescription() {
        #expect(
            InferPeerGRPCError.deadlineExceeded.localizedDescription
                == "InferPeer transport error: deadlineExceeded"
        )
    }

    @Test("network policy permits only an explicit numeric endpoint")
    func networkPolicyAllowlist() throws {
        let allowed = try PeerEndpoint(host: "127.0.0.1", port: 50_051)
        let blocked = try PeerEndpoint(host: "127.0.0.1", port: 50_052)
        let policy = try GRPCNetworkPolicy(
            interfaceName: "lo0",
            allowedEndpoints: [allowed],
            allowsLoopback: true
        )

        #expect(throws: Never.self) { try policy.validate(allowed) }
        #expect(throws: InferPeerGRPCError.endpointNotAllowed) {
            try policy.validate(blocked)
        }
    }

    @Test("network policy rejects wildcard and DNS endpoints")
    func networkPolicyRejectsUnsafeHosts() throws {
        let wildcard = try PeerEndpoint(host: "0.0.0.0", port: 50_051)
        let dns = try PeerEndpoint(host: "coordinator.local", port: 50_051)

        #expect(throws: InferPeerGRPCError.invalidConfiguration) {
            try GRPCNetworkPolicy(interfaceName: "lo0", allowedEndpoints: [wildcard])
        }
        #expect(throws: InferPeerGRPCError.invalidConfiguration) {
            try GRPCNetworkPolicy(interfaceName: "lo0", allowedEndpoints: [dns])
        }
        let publicAddress = try PeerEndpoint(host: "8.8.8.8", port: 50_051)
        #expect(throws: InferPeerGRPCError.invalidConfiguration) {
            try GRPCNetworkPolicy(interfaceName: "lo0", allowedEndpoints: [publicAddress])
        }
        let loopback = try PeerEndpoint(host: "127.0.0.1", port: 50_051)
        #expect(throws: InferPeerGRPCError.invalidConfiguration) {
            try GRPCNetworkPolicy(interfaceName: "lo0", allowedEndpoints: [loopback])
        }
    }

    @Test("network policy accepts a link-local IPv6 scope only on its selected interface")
    func networkPolicyValidatesIPv6Scope() throws {
        let matching = try PeerEndpoint(host: "fe80::1%lo0", port: 50_051)
        let mismatched = try PeerEndpoint(host: "fe80::1%en0", port: 50_051)

        #expect(throws: Never.self) {
            try GRPCNetworkPolicy(interfaceName: "lo0", allowedEndpoints: [matching])
        }
        #expect(throws: InferPeerGRPCError.invalidConfiguration) {
            try GRPCNetworkPolicy(interfaceName: "lo0", allowedEndpoints: [mismatched])
        }
    }

    @Test("join-time invitation supplies cluster, proof, and coordinator pin")
    func appliesJoinInvitation() async throws {
        let endpoint = try makeGRPCEndpoint()
        let identity = try await makeGRPCTestIdentity()
        let baseClusterID = try #require(ClusterID(rawValue: "unjoined"))
        let joinedClusterID = try #require(ClusterID(rawValue: "joined"))
        let invitationID = try #require(InvitationID(rawValue: "invitation-1"))
        let coordinatorFingerprint = try CertificateFingerprint(
            bytes: Data(repeating: 0x77, count: 32)
        )
        let invitation = PairingInvitation(
            invitationID: invitationID,
            coordinator: PairingCoordinator(
                clusterID: joinedClusterID,
                endpoint: endpoint,
                certificateFingerprint: coordinatorFingerprint
            ),
            expiresAt: Date().addingTimeInterval(60),
            proof: Data(repeating: 0x55, count: 32)
        )
        let base = try GRPCTransportConfiguration(
            clusterID: baseClusterID,
            credentials: identity.transportCredentials,
            enabledRoles: [.caller],
            coordinatorPins: [],
            certificateVerifier: makeCertificateVerifier(),
            sessionAuthorizer: makeAuthorizer(allowing: nil),
            networkPolicy: makeNetworkPolicy(endpoint: endpoint)
        )

        let joined = try base.applying(invitation, to: endpoint)
        let hello = HandshakeMessageFactory.callerHello(configuration: joined)

        #expect(hello.metadata.clusterID == joinedClusterID.rawValue)
        #expect(hello.hello.invitationID == invitationID.rawValue)
        #expect(hello.hello.invitationProof == invitation.proof)
        #expect(try joined.coordinatorFingerprint(for: endpoint) == coordinatorFingerprint)
    }

    @Test("handshake wait fails at its configured deadline")
    func handshakeTimeout() async {
        let latch = HandshakeLatch<Int>()

        await #expect(throws: InferPeerGRPCError.deadlineExceeded) {
            _ = try await ClientSessionRunner.waitForHandshake(
                latch,
                timeout: .milliseconds(1)
            )
        }
    }

    @Test("cancelling a handshake wait releases its continuation")
    func handshakeCancellation() async {
        let latch = HandshakeLatch<Int>()
        let task = Task {
            try await ClientSessionRunner.waitForHandshake(
                latch,
                timeout: .seconds(30)
            )
        }
        await Task.yield()

        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("bounded pipe applies backpressure instead of silently dropping")
    func boundedPipeBackpressuresOnOverflow() async throws {
        let pipe = BoundedMessagePipe<Int>(capacity: 1)
        let stream = pipe.internalStream()
        var iterator = stream.makeAsyncIterator()

        try await pipe.send(1)
        let secondSend = Task {
            try await pipe.send(2)
        }

        #expect(try await iterator.next() == 1)
        try await secondSend.value
        #expect(try await iterator.next() == 2)
    }

    @Test("bounded pipe releases cancelled senders and receivers")
    func boundedPipeCancellation() async throws {
        let sendPipe = BoundedMessagePipe<Int>(capacity: 1)
        try await sendPipe.send(1)
        let blockedSend = Task { try await sendPipe.send(2) }
        blockedSend.cancel()
        await #expect(throws: CancellationError.self) {
            try await blockedSend.value
        }

        let receivePipe = BoundedMessagePipe<Int>(capacity: 1)
        let stream = receivePipe.internalStream()
        let blockedReceive = Task {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
        blockedReceive.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await blockedReceive.value
        }
    }

    @Test("bounded pipe reserves one slot for ordered control traffic")
    func boundedPipeReservesControlCapacity() async throws {
        let pipe = BoundedMessagePipe<TestMessage>(
            capacity: 4,
            isControl: { if case .control = $0 { true } else { false } }
        )
        let stream = pipe.internalStream()
        var iterator = stream.makeAsyncIterator()
        try await pipe.send(.data(1))
        try await pipe.send(.data(2))
        try await pipe.send(.data(3))
        let producer = Task {
            try await pipe.send(.data(4))
            try await pipe.send(.control(5))
            try await pipe.send(.data(6))
        }

        var received: [TestMessage] = []
        for _ in 0..<6 {
            if let value = try await iterator.next() { received.append(value) }
        }
        try await producer.value

        #expect(received == [.data(1), .data(2), .data(3), .data(4), .control(5), .data(6)])
    }

    @Test("transport limits enforce the PRD message and memory budgets")
    func transportResourceBudgets() async throws {
        #expect(GRPCTransportConfiguration.defaultMaximumMessageBytes == 256 * 1_024)
        #expect(
            GRPCTransportConfiguration.defaultMaximumMessageBytes
                * GRPCTransportConfiguration.defaultStreamBufferLimit
                == GRPCTransportConfiguration.maximumBufferedBytes
        )

        let endpoint = try makeGRPCEndpoint()
        let identity = try await makeGRPCTestIdentity()
        #expect(throws: InferPeerGRPCError.invalidConfiguration) {
            try GRPCTransportConfiguration(
                clusterID: #require(ClusterID(rawValue: "cluster-1")),
                credentials: identity.transportCredentials,
                enabledRoles: [.caller],
                coordinatorPins: [],
                certificateVerifier: makeCertificateVerifier(),
                sessionAuthorizer: makeAuthorizer(allowing: nil),
                networkPolicy: makeNetworkPolicy(endpoint: endpoint),
                streamBufferLimit: 1
            )
        }
        #expect(throws: InferPeerGRPCError.invalidConfiguration) {
            try GRPCTransportConfiguration(
                clusterID: #require(ClusterID(rawValue: "cluster-1")),
                credentials: identity.transportCredentials,
                enabledRoles: [.caller],
                coordinatorPins: [],
                certificateVerifier: makeCertificateVerifier(),
                sessionAuthorizer: makeAuthorizer(allowing: nil),
                networkPolicy: makeNetworkPolicy(endpoint: endpoint),
                maximumMessageBytes: 256 * 1_024 + 1
            )
        }
    }

    @Test("bounded stream is single consumer")
    func boundedStreamIsSingleConsumer() async throws {
        let pipe = BoundedMessagePipe<Int>(capacity: 2)
        _ = pipe.claimedStream(bufferingLimit: 2)
        let duplicate = pipe.claimedStream(bufferingLimit: 2)

        await #expect(throws: InferPeerGRPCError.streamAlreadyConsumed) {
            for try await _ in duplicate {}
        }
    }

    @Test("verified peer registry is bounded and consumes identities")
    func verifiedPeerRegistryIsBounded() async throws {
        let first = try await makeGRPCTestIdentity()
        let second = try await makeGRPCTestIdentity()
        let firstCertificate = try Certificate(
            derEncoded: Array(first.credentials.certificateDER)
        )
        let secondCertificate = try Certificate(
            derEncoded: Array(second.credentials.certificateDER)
        )
        let registry = VerifiedPeerRegistry(
            verifier: makeCertificateVerifier(),
            maximumEntries: 1
        )
        registry.record(presentedIdentity(first), for: firstCertificate)
        registry.record(presentedIdentity(second), for: secondCertificate)

        #expect(registry.recordedIdentityCount() == 1)
        #expect(throws: InferPeerGRPCError.unauthenticated) {
            try registry.identity(for: firstCertificate)
        }
        #expect(
            try registry.identity(for: secondCertificate).peerID
                == second.credentials.identity.peerID)
        #expect(registry.recordedIdentityCount() == 0)
    }

    private func presentedIdentity(_ identity: GRPCTestIdentity) -> PresentedPeerIdentity {
        PresentedPeerIdentity(
            peerID: identity.credentials.identity.peerID,
            certificateFingerprint: identity.credentials.identity.certificateFingerprint
        )
    }
}

private enum TestMessage: Equatable, Sendable {
    case data(Int)
    case control(Int)
}
