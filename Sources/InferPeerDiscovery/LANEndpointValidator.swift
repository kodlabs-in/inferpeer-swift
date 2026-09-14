import Foundation
import InferPeerCore
import Network

struct LANEndpointValidator: Sendable {
    let permitsLoopback: Bool

    func validate(_ endpoint: PeerEndpoint) throws -> PeerEndpoint {
        let address = endpoint.host.split(separator: "%", maxSplits: 1).first.map(String.init)
        guard let address else { throw PeerDiscoveryError.numericAddressRequired }

        if let ipv4 = IPv4Address(address) {
            guard isPermitted(ipv4) else { throw PeerDiscoveryError.nonLocalAddress }
            return endpoint
        }
        if let ipv6 = IPv6Address(address) {
            guard isPermitted(ipv6) else { throw PeerDiscoveryError.nonLocalAddress }
            return endpoint
        }
        throw PeerDiscoveryError.numericAddressRequired
    }

    private func isPermitted(_ address: IPv4Address) -> Bool {
        let bytes = Array(address.rawValue)
        guard bytes.count == 4 else { return false }
        if bytes[0] == 127 { return permitsLoopback }
        if bytes[0] == 169, bytes[1] == 254 { return true }
        if bytes[0] == 10 { return true }
        if bytes[0] == 172, (16...31).contains(bytes[1]) { return true }
        return bytes[0] == 192 && bytes[1] == 168
    }

    private func isPermitted(_ address: IPv6Address) -> Bool {
        if address.isLoopback { return permitsLoopback }
        return address.isLinkLocal || address.isUniqueLocal
    }
}
