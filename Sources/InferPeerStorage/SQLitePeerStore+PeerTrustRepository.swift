import InferPeerCore
import InferPeerProtocol

extension SQLitePeerStore: PeerTrustRepository {
    /// Adapts the richer storage membership to Core's minimal trust view.
    public func trustRecord(peerID: PeerID) async throws -> PeerTrustRecord? {
        guard let membership = try await membership(peerID: peerID) else {
            return nil
        }
        return PeerTrustRecord(
            identity: membership.identity,
            revokedAt: membership.revokedAt
        )
    }

    /// Persists approval through the durable SQLite membership store.
    public func recordApproval(
        _ identity: PresentedPeerIdentity,
        roles: Set<NodeRole>
    ) async throws {
        _ = try await approve(identity, roles: roles)
    }

    /// Persists revocation through the durable SQLite membership store.
    public func recordRevocation(peerID: PeerID) async throws {
        try await revoke(peerID: peerID)
    }
}
