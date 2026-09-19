import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import InferPeerCore
import InferPeerProtocol

/// Pinned TLS client factory for arbitrary explicitly selected LAN endpoints.
public struct PosixDirectResourceRPCFactory: AuthenticatedDirectResourceRPCFactory, Sendable {
    private let certificateVerifier: GRPCCertificateVerifier
    private let endpointValidator: @Sendable (PeerEndpoint) throws -> Void
    private let maximumMessageBytes: Int

    /// Creates a factory with an injected LAN policy and certificate verifier.
    public init(
        certificateVerifier: GRPCCertificateVerifier,
        maximumMessageBytes: Int = 4 * 1_024 * 1_024,
        endpointValidator: @escaping @Sendable (PeerEndpoint) throws -> Void
    ) throws {
        guard maximumMessageBytes > 0 else {
            throw InferPeerGRPCError.invalidConfiguration
        }
        self.certificateVerifier = certificateVerifier
        self.maximumMessageBytes = maximumMessageBytes
        self.endpointValidator = endpointValidator
    }

    // Async is required by the factory protocol; channel startup is owned by its task.
    // swiftlint:disable async_without_await
    /// Opens a channel pinned to the invitation certificate and fixed destination.
    public func open(
        endpoint: PeerEndpoint,
        certificateFingerprint: CertificateFingerprint,
        credential: Data?
    ) async throws -> any AuthenticatedDirectResourceRPC {
        try endpointValidator(endpoint)
        let registry = VerifiedPeerRegistry(verifier: certificateVerifier)
        let transport = try HTTP2ClientTransport.Posix(
            target: PosixNetworkFactory.target(for: endpoint),
            transportSecurity: PosixTLSFactory.pinnedDirectClientSecurity(
                expectedFingerprint: certificateFingerprint,
                registry: registry
            )
        )
        let client = GRPCClient(transport: transport)
        let connectionTask = Task { try await client.runConnections() }
        let generated = InferPeer_V2_DirectResourceService.Client(wrapping: client)
        let resourceClient = try DirectResourceGRPCClient(
            client: generated,
            maximumMessageBytes: maximumMessageBytes,
            credential: credential
        )
        return GRPCDirectResourceRPCConnection(client: resourceClient) {
            client.beginGracefulShutdown()
            connectionTask.cancel()
        }
    }
    // swiftlint:enable async_without_await
}
