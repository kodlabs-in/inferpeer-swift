import Foundation
import InferPeerCore
import InferPeerSecurity
import Testing

@Suite("Direct resource invitations")
struct DirectResourceInvitationAuthorityTests {
    @Test("A direct invitation round-trips and is consumed exactly once")
    func roundTripsAndConsumesOnce() async throws {
        let authority = DirectResourceInvitationAuthority(secretStore: MemorySecretStore())
        let invitation = try await authority.issue(
            resourceID: ResourceID(rawValue: "resource-phone"),
            endpoint: try PeerEndpoint(host: "192.168.1.20", port: 57_421),
            certificateFingerprint: try CertificateFingerprint(
                bytes: Data(repeating: 0x2A, count: CertificateFingerprint.byteCount)
            )
        )

        let decoded = try ResourcePairingInvitationCodec.decode(
            ResourcePairingInvitationCodec.encode(invitation)
        )
        let invitationID = try #require(decoded.invitationID)

        #expect(decoded.invitationID == invitation.invitationID)
        #expect(decoded.resourceID == invitation.resourceID)
        #expect(decoded.endpoint == invitation.endpoint)
        #expect(decoded.certificateFingerprint == invitation.certificateFingerprint)
        #expect(decoded.secret == invitation.secret)
        #expect(abs(decoded.expiresAt.timeIntervalSince(invitation.expiresAt)) < 0.001)
        #expect(
            try await authority.consume(
                invitationID: invitationID,
                secret: decoded.secret,
                expectedResourceID: decoded.resourceID
            ) == decoded.resourceID
        )
        await #expect(throws: InferPeerSecurityError.invitationUnknownOrConsumed) {
            _ = try await authority.consume(
                invitationID: invitationID,
                secret: decoded.secret,
                expectedResourceID: decoded.resourceID
            )
        }
    }

    @Test("A mismatched resource identity does not consume the invitation")
    func rejectsMismatchedResourceWithoutConsumption() async throws {
        let authority = DirectResourceInvitationAuthority(secretStore: MemorySecretStore())
        let invitation = try await authority.issue(
            resourceID: ResourceID(rawValue: "resource-mac"),
            endpoint: try PeerEndpoint(host: "192.168.1.30", port: 57_421),
            certificateFingerprint: try CertificateFingerprint(
                bytes: Data(repeating: 0x4B, count: CertificateFingerprint.byteCount)
            )
        )
        let invitationID = try #require(invitation.invitationID)

        await #expect(throws: InferPeerSecurityError.invalidInvitationProof) {
            _ = try await authority.consume(
                invitationID: invitationID,
                secret: invitation.secret,
                expectedResourceID: ResourceID(rawValue: "resource-other")
            )
        }
        #expect(
            try await authority.consume(
                invitationID: invitationID,
                secret: invitation.secret,
                expectedResourceID: invitation.resourceID
            ) == invitation.resourceID
        )
    }

    @Test("A revoked invitation cannot be consumed")
    func revokesInvitation() async throws {
        let authority = DirectResourceInvitationAuthority(secretStore: MemorySecretStore())
        let invitation = try await authority.issue(
            resourceID: ResourceID(rawValue: "resource-mac"),
            endpoint: try PeerEndpoint(host: "192.168.1.30", port: 57_421),
            certificateFingerprint: try CertificateFingerprint(
                bytes: Data(repeating: 0x5C, count: CertificateFingerprint.byteCount)
            )
        )
        let invitationID = try #require(invitation.invitationID)

        try await authority.revoke(invitationID)

        await #expect(throws: InferPeerSecurityError.invitationUnknownOrConsumed) {
            _ = try await authority.consume(
                invitationID: invitationID,
                secret: invitation.secret,
                expectedResourceID: invitation.resourceID
            )
        }
    }
}
