import Foundation
import InferPeerCore
import InferPeerSecurity
import Testing

@Suite("Pairing invitations")
struct PairingInvitationAuthorityTests {
    @Test("Round-trips and consumes an invitation exactly once")
    func consumesInvitationOnce() async throws {
        let authority = PairingInvitationAuthority(secretStore: MemorySecretStore())
        let invitation = try await authority.issue(for: makePairingCoordinator())
        let encoded = try PairingInvitationCodec.encode(invitation)
        let decoded = try PairingInvitationCodec.decode(encoded)

        #expect(decoded.invitationID == invitation.invitationID)
        #expect(decoded.coordinator == invitation.coordinator)
        #expect(abs(decoded.expiresAt.timeIntervalSince(invitation.expiresAt)) < 0.001)
        #expect(decoded.proof == invitation.proof)

        try await authority.consume(decoded)
        await #expect(throws: InferPeerSecurityError.invitationUnknownOrConsumed) {
            try await authority.consume(decoded)
        }
    }

    @Test("Rejects a tampered proof without consuming the valid invitation")
    func rejectsTamperedProof() async throws {
        let authority = PairingInvitationAuthority(secretStore: MemorySecretStore())
        let invitation = try await authority.issue(for: makePairingCoordinator())
        var changedProof = invitation.proof
        changedProof[changedProof.startIndex] ^= 0xFF
        let tampered = replacing(invitation, proof: changedProof)

        await #expect(throws: InferPeerSecurityError.invalidInvitationProof) {
            try await authority.consume(tampered)
        }
        try await authority.consume(invitation)
    }

    @Test("Binds every coordinator claim into the proof")
    func rejectsTamperedClaims() async throws {
        let authority = PairingInvitationAuthority(secretStore: MemorySecretStore())
        let invitation = try await authority.issue(for: makePairingCoordinator())
        let changedCoordinator = PairingCoordinator(
            clusterID: invitation.coordinator.clusterID,
            endpoint: try PeerEndpoint(host: "attacker.local", port: 50_051),
            certificateFingerprint: invitation.coordinator.certificateFingerprint
        )
        let tampered = PairingInvitation(
            invitationID: invitation.invitationID,
            coordinator: changedCoordinator,
            expiresAt: invitation.expiresAt,
            proof: invitation.proof
        )

        await #expect(throws: InferPeerSecurityError.invalidInvitationProof) {
            try await authority.consume(tampered)
        }
    }

    @Test("Expires invitations and removes their replay state")
    func expiresInvitation() async throws {
        let clock = MutableSecurityDateProvider()
        let configuration = try PairingConfiguration(
            invitationValidity: 30,
            maximumEncodedInvitationBytes: 4_096
        )
        let authority = PairingInvitationAuthority(
            secretStore: MemorySecretStore(),
            configuration: configuration,
            dateProvider: clock
        )
        let invitation = try await authority.issue(for: makePairingCoordinator())

        clock.advance(by: 30)
        await #expect(throws: InferPeerSecurityError.invitationExpired) {
            try await authority.consume(invitation)
        }
        await #expect(throws: InferPeerSecurityError.invitationUnknownOrConsumed) {
            try await authority.consume(invitation)
        }
    }

    @Test("Authority rotation invalidates outstanding invitation proofs")
    func rotatesAuthorityKey() async throws {
        let authority = PairingInvitationAuthority(secretStore: MemorySecretStore())
        let invitation = try await authority.issue(for: makePairingCoordinator())

        try await authority.rotateAuthorityKey()

        await #expect(throws: InferPeerSecurityError.invalidInvitationProof) {
            try await authority.consume(invitation)
        }
    }

    @Test("Rejects malformed and oversized encodings")
    func rejectsInvalidEncoding() async throws {
        let invitation = try await PairingInvitationAuthority(
            secretStore: MemorySecretStore()
        ).issue(for: makePairingCoordinator())
        let malformed = replacing(invitation, proof: Data())
        let tinyLimit = try PairingConfiguration(
            invitationValidity: 60,
            maximumEncodedInvitationBytes: 8
        )

        #expect(throws: InferPeerSecurityError.invalidInvitationEncoding) {
            try PairingInvitationCodec.encode(malformed)
        }
        #expect(throws: InferPeerSecurityError.invalidInvitationEncoding) {
            try PairingInvitationCodec.encode(invitation, configuration: tinyLimit)
        }
        #expect(throws: InferPeerSecurityError.invalidInvitationEncoding) {
            try PairingInvitationCodec.decode(Data("not-json".utf8))
        }
    }

    private func replacing(
        _ invitation: PairingInvitation,
        proof: Data
    ) -> PairingInvitation {
        PairingInvitation(
            invitationID: invitation.invitationID,
            coordinator: invitation.coordinator,
            expiresAt: invitation.expiresAt,
            proof: proof
        )
    }
}
