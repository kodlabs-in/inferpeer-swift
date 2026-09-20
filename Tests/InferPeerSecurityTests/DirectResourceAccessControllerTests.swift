import Foundation
import InferPeerCore
import InferPeerSecurity
import Testing

@Suite("Direct resource access")
struct DirectResourceAccessControllerTests {
    @Test("Invitation exchange creates a durable revocable credential")
    func exchangesAuthorizesAndRevokes() async throws {
        let store = MemorySecretStore()
        let invitations = DirectResourceInvitationAuthority(secretStore: store)
        let controller = try DirectResourceAccessController(
            secretStore: store,
            invitations: invitations
        )
        let invitation = try await issueInvitation(with: invitations)
        let invitationID = try #require(invitation.invitationID)

        let grant = try await controller.exchange(
            invitationID: invitationID,
            secret: invitation.secret,
            expectedResourceID: invitation.resourceID
        )

        #expect(try await controller.authorize(grant.credential) == grant.principal)
        #expect(try await controller.pairingCount() == 1)
        try await controller.revoke(grant.principal)
        await #expect(throws: DirectResourceAccessError.invalidCredential) {
            _ = try await controller.authorize(grant.credential)
        }
    }

    @Test("The configured pairing bound is enforced before consuming an invitation")
    func preservesInvitationWhenPairingLimitIsReached() async throws {
        let store = MemorySecretStore()
        let invitations = DirectResourceInvitationAuthority(secretStore: store)
        let controller = try DirectResourceAccessController(
            secretStore: store,
            invitations: invitations,
            maximumPairings: 1
        )
        let first = try await issueInvitation(with: invitations, resourceID: "resource-one")
        _ = try await controller.exchange(
            invitationID: try #require(first.invitationID),
            secret: first.secret,
            expectedResourceID: first.resourceID
        )
        let second = try await issueInvitation(with: invitations, resourceID: "resource-two")
        let secondID = try #require(second.invitationID)

        await #expect(throws: DirectResourceAccessError.maximumPairingsReached) {
            _ = try await controller.exchange(
                invitationID: secondID,
                secret: second.secret,
                expectedResourceID: second.resourceID
            )
        }
        let otherController = try DirectResourceAccessController(
            secretStore: store,
            invitations: invitations,
            maximumPairings: 2
        )
        _ = try await otherController.exchange(
            invitationID: secondID,
            secret: second.secret,
            expectedResourceID: second.resourceID
        )
    }

    @Test("All paired principals can be revoked together")
    func revokesAllPairings() async throws {
        let store = MemorySecretStore()
        let invitations = DirectResourceInvitationAuthority(secretStore: store)
        let controller = try DirectResourceAccessController(
            secretStore: store,
            invitations: invitations
        )
        let first = try await issueInvitation(with: invitations, resourceID: "resource-one")
        let firstGrant = try await controller.exchange(
            invitationID: try #require(first.invitationID),
            secret: first.secret,
            expectedResourceID: first.resourceID
        )
        let second = try await issueInvitation(with: invitations, resourceID: "resource-two")
        let secondGrant = try await controller.exchange(
            invitationID: try #require(second.invitationID),
            secret: second.secret,
            expectedResourceID: second.resourceID
        )

        #expect(try await controller.pairingCount() == 2)
        try await controller.revokeAll()
        #expect(try await controller.pairingCount() == 0)
        for credential in [firstGrant.credential, secondGrant.credential] {
            await #expect(throws: DirectResourceAccessError.invalidCredential) {
                _ = try await controller.authorize(credential)
            }
        }
    }

    @Test("Concurrent exchanges retain every issued credential")
    func concurrentExchangesRetainEveryCredential() async throws {
        let store = MemorySecretStore()
        let invitations = DirectResourceInvitationAuthority(secretStore: store)
        let controller = try DirectResourceAccessController(
            secretStore: store,
            invitations: invitations,
            maximumPairings: 8
        )
        var pending: [ResourcePairingInvitation] = []
        for index in 0..<8 {
            pending.append(
                try await issueInvitation(
                    with: invitations,
                    resourceID: "resource-\(index)"
                )
            )
        }

        let grants = try await withThrowingTaskGroup(
            of: DirectResourceAccessGrant.self
        ) { group in
            for invitation in pending {
                group.addTask {
                    try await controller.exchange(
                        invitationID: try #require(invitation.invitationID),
                        secret: invitation.secret,
                        expectedResourceID: invitation.resourceID
                    )
                }
            }
            var result: [DirectResourceAccessGrant] = []
            for try await grant in group { result.append(grant) }
            return result
        }

        #expect(grants.count == 8)
        #expect(try await controller.pairingCount() == 8)
        for grant in grants {
            #expect(try await controller.authorize(grant.credential) == grant.principal)
        }
    }
}

private func issueInvitation(
    with authority: DirectResourceInvitationAuthority,
    resourceID: String = "resource-host"
) async throws -> ResourcePairingInvitation {
    try await authority.issue(
        resourceID: ResourceID(rawValue: resourceID),
        endpoint: PeerEndpoint(host: "192.168.1.50", port: 57_421),
        certificateFingerprint: CertificateFingerprint(
            bytes: Data(repeating: 0x6C, count: CertificateFingerprint.byteCount)
        )
    )
}
