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

    /// Creates local-network discovery configuration.
    public init(
        domain: String? = nil,
        includesPeerToPeer: Bool = false,
        permitsLoopback: Bool = false
    ) {
        self.domain = domain
        self.includesPeerToPeer = includesPeerToPeer
        self.permitsLoopback = permitsLoopback
    }
}

/// Failures produced before a discovery candidate reaches authentication.
public enum PeerDiscoveryError: Error, Equatable, Sendable {
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
}
