import Foundation
@testable import InferPeerGRPC
import InferPeer
import InferPeerCore
import InferPeerProtocol
import Testing

@Suite("Default session authorization")
struct InferPeerSessionAuthorizerTests {
    @Test("An invitation atomically approves an unknown role-scoped peer")
    func pairsUnknownPeer() async throws {
        let identityProvider = AuthorizerIdentityProvider()
        let authorizer = InferPeerSessionAuthorizer.make(identityProvider: identityProvider)
        let identity = try makeAuthorizerIdentity()
        let invitationID = try #require(InvitationID(rawValue: "invitation-1"))
        let hello = InferPeer_V1_SessionHello.with {
            $0.invitationID = invitationID.rawValue
            $0.invitationProof = Data([0x01])
        }

        try await authorizer.authorize(identity: identity, hello: hello, role: .caller)
        try await authorizer.authorize(
            identity: identity,
            hello: InferPeer_V1_SessionHello(),
            role: .caller
        )

        #expect(await identityProvider.consumedInvitationIDs == [invitationID])
        #expect(await identityProvider.approvedPeerIDs == [identity.peerID])
    }

    @Test("Unknown peers without an invitation fail closed")
    func rejectsUnknownPeer() async throws {
        let identityProvider = AuthorizerIdentityProvider()
        let authorizer = InferPeerSessionAuthorizer.make(identityProvider: identityProvider)

        await #expect(throws: InferPeerError.self) {
            try await authorizer.authorize(
                identity: makeAuthorizerIdentity(),
                hello: InferPeer_V1_SessionHello(),
                role: .worker
            )
        }
    }
}

private actor AuthorizerIdentityProvider: IdentityProvider {
    private var trustedPeerIDs: Set<PeerID> = []
    private(set) var consumedInvitationIDs: [InvitationID] = []
    private(set) var approvedPeerIDs: [PeerID] = []

    func localIdentity() throws -> LocalPeerIdentity {
        let identity = try makeAuthorizerIdentity()
        return LocalPeerIdentity(
            peerID: identity.peerID,
            certificateFingerprint: identity.certificateFingerprint
        )
    }

    func trustDecision(for identity: PresentedPeerIdentity) -> PeerTrustDecision {
        trustedPeerIDs.contains(identity.peerID) ? .trusted : .unknown
    }

    func trustDecision(
        for identity: PresentedPeerIdentity,
        role: NodeRole
    ) -> PeerTrustDecision {
        trustedPeerIDs.contains(identity.peerID) ? .trusted : .unknown
    }

    func approve(_ identity: PresentedPeerIdentity) {
        trustedPeerIDs.insert(identity.peerID)
        approvedPeerIDs.append(identity.peerID)
    }

    func consume(_ invitation: PairingInvitation) {}

    func consume(invitationID: InvitationID, proof: Data) {
        consumedInvitationIDs.append(invitationID)
    }

    func revoke(peerID: PeerID) {
        trustedPeerIDs.remove(peerID)
    }
}

private func makeAuthorizerIdentity() throws -> PresentedPeerIdentity {
    PresentedPeerIdentity(
        peerID: try #require(PeerID(rawValue: "peer-1")),
        certificateFingerprint: try CertificateFingerprint(bytes: Data(repeating: 0x55, count: 32))
    )
}
