import InferPeerCore
import InferPeerProtocol

/// Default identity, invitation, approval, trust, and revocation orchestration.
public actor DefaultIdentityProvider: IdentityProvider {
    private let identityManager: DeviceIdentityManager
    private let invitationAuthority: PairingInvitationAuthority
    private let trustRepository: any PeerTrustRepository
    private let approvalConfiguration: PeerApprovalConfiguration

    /// Creates an identity provider with explicit roles granted upon host approval.
    public init(
        identityManager: DeviceIdentityManager,
        invitationAuthority: PairingInvitationAuthority,
        trustRepository: any PeerTrustRepository,
        approvedRoles: Set<NodeRole>
    ) throws {
        self.identityManager = identityManager
        self.invitationAuthority = invitationAuthority
        self.trustRepository = trustRepository
        approvalConfiguration = try PeerApprovalConfiguration(roles: approvedRoles)
    }

    /// Returns the certificate-bound device identity, creating it on first use.
    public func localIdentity() async throws -> LocalPeerIdentity {
        try await identityManager.credentials().identity
    }

    /// Trusts only the exact active fingerprint previously approved for this peer identifier.
    public func trustDecision(
        for identity: PresentedPeerIdentity
    ) async throws -> PeerTrustDecision {
        guard let record = try await trustRepository.trustRecord(peerID: identity.peerID) else {
            return .unknown
        }
        guard record.revokedAt == nil else { return .revoked }
        return record.identity.certificateFingerprint == identity.certificateFingerprint
            ? .trusted
            : .unknown
    }

    /// Persists explicit host approval with the configured role scope.
    public func approve(_ identity: PresentedPeerIdentity) async throws {
        try await trustRepository.recordApproval(
            identity,
            roles: approvalConfiguration.roles
        )
    }

    /// Validates and atomically consumes a single-use invitation.
    public func consume(_ invitation: PairingInvitation) async throws {
        try await invitationAuthority.consume(invitation)
    }

    /// Persists revocation so future sessions fail authentication.
    public func revoke(peerID: PeerID) async throws {
        try await trustRepository.recordRevocation(peerID: peerID)
    }
}
