import Foundation
import InferPeerProtocol

/// The security-relevant subset of one persisted membership.
public struct PeerTrustRecord: Hashable, Sendable {
    /// The exact approved certificate-bound identity.
    public let identity: PresentedPeerIdentity

    /// The revocation time, or `nil` while active.
    public let revokedAt: Date?

    /// Creates a persisted trust snapshot.
    public init(identity: PresentedPeerIdentity, revokedAt: Date?) {
        self.identity = identity
        self.revokedAt = revokedAt
    }
}

/// Durable trust operations required by an identity provider.
public protocol PeerTrustRepository: Sendable {
    /// Loads an approval or revocation by stable peer identifier.
    func trustRecord(peerID: PeerID) async throws -> PeerTrustRecord?

    /// Persists a host-confirmed identity and its authorized roles.
    func recordApproval(
        _ identity: PresentedPeerIdentity,
        roles: Set<NodeRole>
    ) async throws

    /// Revokes future authentication for a peer.
    func recordRevocation(peerID: PeerID) async throws
}
