import Darwin
import Foundation
import GRPCNIOTransportCore
import GRPCNIOTransportHTTP2Posix
import InferPeerCore
import NIOCore
import NIOSSL
import X509

final class VerifiedPeerRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [Certificate: PresentedPeerIdentity] = [:]
    private let verifier: GRPCCertificateVerifier

    init(verifier: GRPCCertificateVerifier) {
        self.verifier = verifier
    }

    func verificationCallback(
        expectedFingerprint: CertificateFingerprint?
    )
        -> @Sendable (
            [NIOSSLCertificate],
            EventLoopPromise<NIOSSLVerificationResultWithMetadata>
        ) -> Void
    {
        { [self] certificates, promise in
            do {
                guard let leaf = certificates.first else {
                    promise.succeed(.failed)
                    return
                }
                let der = Data(try leaf.toDERBytes())
                let identity = try verifier.verify(
                    certificateDER: der,
                    expectedFingerprint: expectedFingerprint
                )
                let certificate = try Certificate(derEncoded: Array(der))
                record(identity, for: certificate)
                let chain = ValidatedCertificateChain(certificates)
                promise.succeed(.certificateVerified(VerificationMetadata(chain)))
            } catch {
                promise.succeed(.failed)
            }
        }
    }

    func identity(for certificate: Certificate) throws -> PresentedPeerIdentity {
        try lock.withLock {
            guard let identity = identities[certificate] else {
                throw InferPeerGRPCError.unauthenticated
            }
            return identity
        }
    }

    func identity(matching fingerprint: CertificateFingerprint) throws -> PresentedPeerIdentity {
        try lock.withLock {
            guard
                let identity = identities.values.first(where: {
                    $0.certificateFingerprint == fingerprint
                })
            else {
                throw InferPeerGRPCError.unauthenticated
            }
            return identity
        }
    }

    private func record(_ identity: PresentedPeerIdentity, for certificate: Certificate) {
        lock.withLock { identities[certificate] = identity }
    }
}

enum PosixTLSFactory {
    static func serverSecurity(
        configuration: GRPCTransportConfiguration,
        registry: VerifiedPeerRegistry
    ) -> HTTP2ServerTransport.Posix.TransportSecurity {
        .mTLS(
            certificateChain: [certificateSource(configuration.credentials)],
            privateKey: privateKeySource(configuration.credentials)
        ) { tls in
            tls.clientCertificateVerification = .noHostnameVerification
            tls.requireALPN = true
            tls.customVerificationCallback = registry.verificationCallback(
                expectedFingerprint: nil
            )
        }
    }

    static func clientSecurity(
        configuration: GRPCTransportConfiguration,
        expectedFingerprint: CertificateFingerprint,
        registry: VerifiedPeerRegistry
    ) -> HTTP2ClientTransport.Posix.TransportSecurity {
        .mTLS(
            certificateChain: [certificateSource(configuration.credentials)],
            privateKey: privateKeySource(configuration.credentials)
        ) { tls in
            tls.serverCertificateVerification = .noHostnameVerification
            tls.customVerificationCallback = registry.verificationCallback(
                expectedFingerprint: expectedFingerprint
            )
        }
    }

    private static func certificateSource(
        _ credentials: GRPCDeviceCredentials
    ) -> TLSConfig.CertificateSource {
        .bytes(Array(credentials.certificateDER), format: .der)
    }

    private static func privateKeySource(
        _ credentials: GRPCDeviceCredentials
    ) -> TLSConfig.PrivateKeySource {
        .bytes(Array(credentials.privateKeyDER), format: .der)
    }
}

enum PosixNetworkFactory {
    static func socketAddress(for endpoint: PeerEndpoint) -> GRPCNIOTransportCore.SocketAddress {
        if endpoint.host.contains(":") {
            return .ipv6(host: endpoint.host, port: Int(endpoint.port))
        }
        return .ipv4(host: endpoint.host, port: Int(endpoint.port))
    }

    static func target(for endpoint: PeerEndpoint) -> any ResolvableTarget {
        if endpoint.host.contains(":") {
            return ResolvableTargets.IPv6(addresses: [
                .init(host: endpoint.host, port: Int(endpoint.port))
            ])
        }
        return ResolvableTargets.IPv4(addresses: [
            .init(host: endpoint.host, port: Int(endpoint.port))
        ])
    }

    static func clientConfig(
        endpoint: PeerEndpoint,
        policy: GRPCNetworkPolicy
    ) -> HTTP2ClientTransport.Posix.Config {
        .defaults { config in
            config.channelDebuggingCallbacks.onCreateTCPConnection = { channel in
                bind(channel: channel, endpoint: endpoint, interfaceIndex: policy.interfaceIndex)
            }
        }
    }

    static func serverConfig(
        endpoint: PeerEndpoint,
        policy: GRPCNetworkPolicy,
        maximumMessageBytes: Int
    ) -> HTTP2ServerTransport.Posix.Config {
        .defaults { config in
            config.rpc.maxRequestPayloadSize = maximumMessageBytes
            config.channelDebuggingCallbacks.onBindTCPListener = { channel in
                bind(channel: channel, endpoint: endpoint, interfaceIndex: policy.interfaceIndex)
            }
        }
    }

    private static func bind(
        channel: any Channel,
        endpoint: PeerEndpoint,
        interfaceIndex: UInt32
    ) -> EventLoopFuture<Void> {
        let option = boundInterfaceOption(ipv6: endpoint.host.contains(":"))
        return channel.setOption(option, value: CInt(interfaceIndex))
    }

    private static func boundInterfaceOption(
        ipv6: Bool
    ) -> ChannelOptions.Types.SocketOption {
        if ipv6 {
            return .init(level: CInt(IPPROTO_IPV6), name: CInt(IPV6_BOUND_IF))
        }
        return .init(level: CInt(IPPROTO_IP), name: CInt(IP_BOUND_IF))
    }
}
