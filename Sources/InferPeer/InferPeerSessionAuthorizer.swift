import InferPeerCore
import InferPeerGRPC
import InferPeerProtocol

/// Builds the fail-closed gRPC authorization policy used by an InferPeer coordinator.
public enum InferPeerSessionAuthorizer {
    /// Trusts approved role-scoped peers or atomically pairs one unknown peer.
    public static func make(
        identityProvider: any IdentityProvider
    ) -> GRPCSessionAuthorizer {
        GRPCSessionAuthorizer { identity, hello, role in
            let decision = try await identityProvider.trustDecision(for: identity, role: role)
            switch decision {
            case .trusted:
                return
            case .revoked:
                throw InferPeerError(code: .permissionDenied, isRetryable: false)
            case .unknown:
                try await pair(
                    identity: identity,
                    hello: hello,
                    identityProvider: identityProvider
                )
            }
        }
    }

    private static func pair(
        identity: PresentedPeerIdentity,
        hello: InferPeer_V1_SessionHello,
        identityProvider: any IdentityProvider
    ) async throws {
        guard hello.hasInvitationID,
            hello.hasInvitationProof,
            let invitationID = InvitationID(rawValue: hello.invitationID),
            !hello.invitationProof.isEmpty
        else {
            throw InferPeerError(code: .permissionDenied, isRetryable: false)
        }
        do {
            try await identityProvider.consume(
                invitationID: invitationID,
                proof: hello.invitationProof
            )
            try await identityProvider.approve(identity)
        } catch {
            throw InferPeerError(code: .unauthenticated, isRetryable: false)
        }
    }
}
