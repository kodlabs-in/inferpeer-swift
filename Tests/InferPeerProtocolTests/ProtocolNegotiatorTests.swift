import InferPeerProtocol
import Testing

@Suite("Protocol negotiation")
struct ProtocolNegotiatorTests {
    @Test("Selects the highest shared minor and known capability intersection")
    func negotiatesCompatiblePeers() throws {
        let local = support(
            major: 1,
            minimumMinor: 0,
            maximumMinor: 3,
            capabilities: [.eventReplay, .durableCancellation, .attemptLeases]
        )
        let remote = support(
            major: 1,
            minimumMinor: 1,
            maximumMinor: 2,
            capabilities: [.durableCancellation, .eventReplay, .boundedStreaming]
        )

        let negotiated = try ProtocolNegotiator.negotiate(local: local, remote: remote)

        #expect(negotiated.version.major == 1)
        #expect(negotiated.version.minor == 2)
        #expect(negotiated.capabilities == [.eventReplay, .durableCancellation])
    }

    @Test("Rejects incompatible major versions")
    func rejectsIncompatibleMajors() {
        let local = support(major: 1, minimumMinor: 0, maximumMinor: 0)
        let remote = support(major: 2, minimumMinor: 0, maximumMinor: 0)

        #expect(
            throws: ProtocolNegotiationError.incompatibleMajor(local: 1, remote: 2)
        ) {
            try ProtocolNegotiator.negotiate(local: local, remote: remote)
        }
    }

    @Test("Rejects nonoverlapping minor versions")
    func rejectsNonoverlappingMinors() {
        let local = support(major: 1, minimumMinor: 0, maximumMinor: 1)
        let remote = support(major: 1, minimumMinor: 2, maximumMinor: 3)

        #expect(throws: ProtocolNegotiationError.noSharedMinorVersion) {
            try ProtocolNegotiator.negotiate(local: local, remote: remote)
        }
    }

    @Test("Rejects invalid advertised ranges")
    func rejectsInvalidSupport() {
        let invalidMajor = support(major: 0, minimumMinor: 0, maximumMinor: 0)
        let invalidRange = support(major: 1, minimumMinor: 2, maximumMinor: 1)
        let valid = support(major: 1, minimumMinor: 0, maximumMinor: 0)

        #expect(throws: ProtocolNegotiationError.invalidMajor(peer: .local)) {
            try ProtocolNegotiator.negotiate(local: invalidMajor, remote: valid)
        }
        #expect(throws: ProtocolNegotiationError.invalidMinorRange(peer: .remote)) {
            try ProtocolNegotiator.negotiate(local: valid, remote: invalidRange)
        }
    }

    @Test("Does not negotiate unknown capabilities")
    func ignoresUnknownCapabilities() throws {
        let unknown = try #require(InferPeer_V1_Capability(rawValue: 999))
        let local = support(
            major: 1,
            minimumMinor: 0,
            maximumMinor: 0,
            capabilities: [.eventReplay, unknown]
        )
        let remote = support(
            major: 1,
            minimumMinor: 0,
            maximumMinor: 0,
            capabilities: [.eventReplay, unknown]
        )

        let negotiated = try ProtocolNegotiator.negotiate(local: local, remote: remote)

        #expect(negotiated.capabilities == [InferPeer_V1_Capability.eventReplay])
    }

    private func support(
        major: UInt32,
        minimumMinor: UInt32,
        maximumMinor: UInt32,
        capabilities: [InferPeer_V1_Capability] = []
    ) -> InferPeer_V1_ProtocolSupport {
        InferPeer_V1_ProtocolSupport.with {
            $0.major = major
            $0.minimumMinor = minimumMinor
            $0.maximumMinor = maximumMinor
            $0.capabilities = capabilities
        }
    }
}
