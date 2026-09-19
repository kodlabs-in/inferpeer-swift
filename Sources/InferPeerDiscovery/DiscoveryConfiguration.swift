import Foundation

/// Configuration for coordinator advertisement and browsing on the local network.
public struct BonjourDiscoveryConfiguration: Hashable, Sendable {
    /// The DNS-SD service type reserved for InferPeer coordinators.
    public static let serviceType = "_inferpeer._tcp."

    /// The optional Bonjour domain. `nil` uses the platform default domains.
    public let domain: String?

    /// Whether Apple peer-to-peer interfaces may be used in addition to Wi-Fi.
    public let includesPeerToPeer: Bool

    /// Whether loopback addresses are accepted. Intended only for local integration tests.
    public let permitsLoopback: Bool

    /// Deadline and retry policy for resolving one Bonjour service.
    public let resolutionPolicy: BonjourResolutionPolicy

    /// Creates local-network discovery configuration.
    public init(
        domain: String? = nil,
        includesPeerToPeer: Bool = false,
        permitsLoopback: Bool = false,
        resolutionPolicy: BonjourResolutionPolicy = .standard
    ) {
        self.domain = domain
        self.includesPeerToPeer = includesPeerToPeer
        self.permitsLoopback = permitsLoopback
        self.resolutionPolicy = resolutionPolicy
    }
}

/// Bounded retry settings for resolving a Bonjour service into a numeric endpoint.
public struct BonjourResolutionPolicy: Hashable, Sendable {
    /// Two three-second attempts separated by a short delay.
    public static let standard = Self(
        validatedTimeout: 3,
        maximumAttempts: 2,
        retryDelay: 0.1
    )

    /// Per-attempt deadline in seconds.
    public let timeout: TimeInterval

    /// Maximum number of resolution attempts.
    public let maximumAttempts: Int

    /// Delay in seconds before a retry.
    public let retryDelay: TimeInterval

    /// Creates a validated finite resolution policy.
    public init(
        timeout: TimeInterval,
        maximumAttempts: Int,
        retryDelay: TimeInterval
    ) throws {
        guard timeout.isFinite, timeout > 0,
            maximumAttempts > 0,
            retryDelay.isFinite, retryDelay >= 0
        else {
            throw PeerDiscoveryError.invalidConfiguration
        }
        self.timeout = timeout
        self.maximumAttempts = maximumAttempts
        self.retryDelay = retryDelay
    }

    private init(
        validatedTimeout: TimeInterval,
        maximumAttempts: Int,
        retryDelay: TimeInterval
    ) {
        timeout = validatedTimeout
        self.maximumAttempts = maximumAttempts
        self.retryDelay = retryDelay
    }
}

/// Failures produced before a discovery candidate reaches authentication.
public enum PeerDiscoveryError: Error, Equatable, Sendable {
    /// A discovery deadline or retry value was invalid.
    case invalidConfiguration

    /// A stream capacity was zero or negative.
    case invalidBufferingLimit

    /// This discovery instance already owns an active browser.
    case discoveryAlreadyActive

    /// The supplied explicit endpoint was not a numeric IP address.
    case numericAddressRequired

    /// The supplied address is not private, link-local, or permitted loopback.
    case nonLocalAddress

    /// Bonjour returned an endpoint that could not be resolved to a LAN address.
    case resolutionFailed

    /// The system browser stopped because Network.framework reported a failure.
    case browsingFailed

    /// The bounded stream could not retain every discovery transition.
    case streamOverflow

    /// An advertisement service name was empty.
    case invalidServiceName

    /// An advertisement port was zero.
    case invalidAdvertisementPort

    /// An advertiser was started more than once.
    case advertisementAlreadyActive

    /// Bonjour TXT metadata was missing, oversized, malformed, or incompatible.
    case invalidTXTRecord
}
