/// Version information for the InferPeer wire protocol implemented by this package.
public enum InferPeerProtocolVersion {
    /// The protocol version emitted by this package.
    public static let current = InferPeer_V1_ProtocolVersion.with {
        $0.major = 1
        $0.minor = 0
    }

    /// The protocol versions and capabilities accepted by this package.
    public static let supported = InferPeer_V1_ProtocolSupport.with {
        $0.major = current.major
        $0.minimumMinor = current.minor
        $0.maximumMinor = current.minor
        $0.capabilities = [
            .sessionResumption,
            .eventReplay,
            .durableCancellation,
            .attemptLeases,
            .boundedStreaming,
            .allowedWorkers,
            .modelRevisionSelection,
        ]
    }
}
