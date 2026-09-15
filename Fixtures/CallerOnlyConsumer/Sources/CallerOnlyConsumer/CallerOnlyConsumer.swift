import InferPeer

/// Proves that a downstream caller can import the facade without linking InferPeerMLX.
public enum CallerOnlyConsumer {
    /// Builds a caller-only facade configuration without source-level access to implementation modules.
    public static func configuration() throws -> InferPeerNodeConfiguration {
        try InferPeerNodeConfiguration(roles: [.caller])
    }
}
