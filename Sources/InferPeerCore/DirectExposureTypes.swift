/// Host policy for one direct-resource listener and its matching advertisement.
public struct ExposureConfiguration: Hashable, Sendable {
    /// Default direct-resource exposure policy.
    public static let `default` = Self()

    /// Whether the bound listener should also advertise through local discovery.
    public let advertisesOnLocalNetwork: Bool

    /// Maximum authenticated app identities retained by this endpoint.
    public let maximumPairings: Int

    /// Creates host exposure policy without starting a listener.
    public init(
        advertisesOnLocalNetwork: Bool = true,
        maximumPairings: Int = 16
    ) {
        self.advertisesOnLocalNetwork = advertisesOnLocalNetwork
        self.maximumPairings = maximumPairings
    }
}

/// Idempotent ownership handle for a bound direct-resource endpoint.
public struct ExposureHandle: Sendable {
    /// Actual endpoint bound before any advertisement is published.
    public let endpoint: PeerEndpoint

    private let lease: ExposureLease

    /// Creates a handle around one already-bound adapter endpoint.
    public init(
        endpoint: PeerEndpoint,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.endpoint = endpoint
        lease = ExposureLease(stopOperation: stop)
    }

    /// Withdraws advertising and stops the listener at most once.
    public func stop() async {
        await lease.stop()
    }

    package func isStopped() async -> Bool {
        await lease.stopped()
    }
}

/// Adapter that binds one authenticated endpoint before advertising its real port.
public protocol ResourceExposure: Sendable {
    /// Binds first, optionally advertises the actual port, and returns its owner handle.
    func start(configuration: ExposureConfiguration) async throws -> ExposureHandle
}

private actor ExposureLease {
    private let stopOperation: @Sendable () async -> Void
    private var isStopped = false

    init(stopOperation: @escaping @Sendable () async -> Void) {
        self.stopOperation = stopOperation
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        await stopOperation()
    }

    func stopped() -> Bool {
        isStopped
    }
}
