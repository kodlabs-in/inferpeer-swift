import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import InferPeerCore
import InferPeerProtocol

/// gRPC Swift 2 transport implementing InferPeer's caller, worker, and coordinator contracts.
public actor GRPCPeerTransport: PeerTransport {
    private let configuration: GRPCTransportConfiguration
    private var listener: GRPCCoordinatorListener?
    private var clientTerminators: [UUID: SessionTerminator] = [:]
    private let pathMonitor = WiFiPathMonitor()

    /// Creates a stopped adapter. No socket or credential access occurs until connect/listen.
    public init(configuration: GRPCTransportConfiguration) {
        self.configuration = configuration
    }

    /// Starts a mutually authenticated coordinator server on an approved interface endpoint.
    public func listen(
        at endpoint: PeerEndpoint
    ) async throws -> any CoordinatorTransportListener {
        try requireRole(.coordinator)
        try configuration.networkPolicy.validate(endpoint)
        startPathMonitoringIfNeeded()
        guard listener == nil else { throw InferPeerGRPCError.invalidConfiguration }

        let registry = VerifiedPeerRegistry(verifier: configuration.certificateVerifier)
        let inbound = BoundedMessagePipe<InboundPeerSession>(
            capacity: configuration.streamBufferLimit
        )
        let serverTransport = HTTP2ServerTransport.Posix(
            address: PosixNetworkFactory.socketAddress(for: endpoint),
            transportSecurity: PosixTLSFactory.serverSecurity(
                configuration: configuration,
                registry: registry
            ),
            config: PosixNetworkFactory.serverConfig(
                endpoint: endpoint,
                policy: configuration.networkPolicy,
                maximumMessageBytes: configuration.maximumMessageBytes
            )
        )
        let service = GRPCSessionService(
            configuration: configuration,
            inboundSessions: inbound,
            identityExtractor: Self.identityExtractor(registry: registry)
        )
        let server = GRPCServer(transport: serverTransport, services: [service])
        let serverTask = Self.startServer(server, inboundSessions: inbound)
        do {
            _ = try await serverTransport.listeningAddress
        } catch {
            serverTask.cancel()
            throw GRPCErrorMapper.publicError(from: error)
        }

        let listener = GRPCCoordinatorListener(
            inboundSessions: inbound,
            server: server,
            serverTask: serverTask
        )
        self.listener = listener
        return listener
    }

    /// Opens and negotiates a mutually authenticated caller bidirectional RPC.
    public func connectCaller(
        to endpoint: PeerEndpoint
    ) async throws -> any CallerTransportSession {
        try await openCaller(to: endpoint, configuration: configuration)
    }

    /// Opens a caller session using the invitation selected by the joining host.
    public func connectCaller(
        to endpoint: PeerEndpoint,
        invitation: PairingInvitation
    ) async throws -> any CallerTransportSession {
        let configuration = try configuration.applying(invitation, to: endpoint)
        return try await openCaller(to: endpoint, configuration: configuration)
    }

    private func openCaller(
        to endpoint: PeerEndpoint,
        configuration: GRPCTransportConfiguration
    ) async throws -> any CallerTransportSession {
        try requireRole(.caller)
        let resources = try makeClientResources(
            endpoint: endpoint,
            configuration: configuration
        )
        let opened = try await ClientSessionRunner.openCaller(
            configuration: configuration,
            registry: resources.registry,
            expectedFingerprint: resources.expectedFingerprint,
            client: resources.client
        )
        retain(opened.terminator)
        return opened.session
    }

    /// Opens and negotiates a mutually authenticated worker bidirectional RPC.
    public func connectWorker(
        to endpoint: PeerEndpoint
    ) async throws -> any WorkerTransportSession {
        try await openWorker(to: endpoint, configuration: configuration)
    }

    /// Opens a worker session using the invitation selected by the joining host.
    public func connectWorker(
        to endpoint: PeerEndpoint,
        invitation: PairingInvitation
    ) async throws -> any WorkerTransportSession {
        let configuration = try configuration.applying(invitation, to: endpoint)
        return try await openWorker(to: endpoint, configuration: configuration)
    }

    private func openWorker(
        to endpoint: PeerEndpoint,
        configuration: GRPCTransportConfiguration
    ) async throws -> any WorkerTransportSession {
        try requireRole(.worker)
        let resources = try makeClientResources(
            endpoint: endpoint,
            configuration: configuration
        )
        let opened = try await ClientSessionRunner.openWorker(
            configuration: configuration,
            registry: resources.registry,
            expectedFingerprint: resources.expectedFingerprint,
            client: resources.client
        )
        retain(opened.terminator)
        return opened.session
    }

    /// Closes the listener, active client sessions, and their underlying gRPC clients.
    public func stop() async {
        pathMonitor.cancel()
        await listener?.close()
        listener = nil
        let terminators = Array(clientTerminators.values)
        clientTerminators.removeAll()
        terminators.forEach { $0.terminate() }
    }

    private func requireRole(_ role: NodeRole) throws {
        guard configuration.enabledRoles.contains(role) else {
            throw InferPeerGRPCError.roleDisabled
        }
    }

    private func retain(_ terminator: SessionTerminator) {
        clientTerminators[terminator.id] = terminator
        terminator.notifyOnTermination { [weak self] id in
            Task { await self?.removeTerminator(id) }
        }
    }

    private func removeTerminator(_ id: UUID) {
        clientTerminators[id] = nil
    }

    func activeClientSessionCount() -> Int {
        clientTerminators.count
    }

    private func makeClientResources(
        endpoint: PeerEndpoint,
        configuration: GRPCTransportConfiguration
    ) throws -> ClientResources {
        try configuration.networkPolicy.validate(endpoint)
        startPathMonitoringIfNeeded()
        let expectedFingerprint = try configuration.coordinatorFingerprint(for: endpoint)
        let registry = VerifiedPeerRegistry(verifier: configuration.certificateVerifier)
        let transport = try HTTP2ClientTransport.Posix(
            target: PosixNetworkFactory.target(for: endpoint),
            transportSecurity: PosixTLSFactory.clientSecurity(
                configuration: configuration,
                expectedFingerprint: expectedFingerprint,
                registry: registry
            ),
            config: PosixNetworkFactory.clientConfig(
                endpoint: endpoint,
                policy: configuration.networkPolicy
            )
        )
        return ClientResources(
            client: GRPCClient(transport: transport),
            registry: registry,
            expectedFingerprint: expectedFingerprint
        )
    }

    private func startPathMonitoringIfNeeded() {
        let policy = configuration.networkPolicy
        guard !policy.allowsLoopback else { return }
        pathMonitor.start(interfaceName: policy.interfaceName) { [weak self] in
            Task { await self?.stopForDisallowedPath() }
        }
    }

    private func stopForDisallowedPath() async {
        await stop()
    }

    private static func identityExtractor(
        registry: VerifiedPeerRegistry
    ) -> ContextIdentityExtractor {
        { context in
            guard
                let posix = context.transportSpecific as? HTTP2ServerTransport.Posix.Context,
                let certificate = posix.peerCertificate
            else {
                throw InferPeerGRPCError.unauthenticated
            }
            return try registry.identity(for: certificate)
        }
    }

    private static func startServer(
        _ server: GRPCServer<HTTP2ServerTransport.Posix>,
        inboundSessions: BoundedMessagePipe<InboundPeerSession>
    ) -> Task<Void, Never> {
        Task {
            do {
                try await server.serve()
                inboundSessions.finish()
            } catch is CancellationError {
                inboundSessions.finish()
            } catch {
                inboundSessions.fail(GRPCErrorMapper.publicError(from: error))
            }
        }
    }
}

private struct ClientResources: Sendable {
    let client: GRPCClient<HTTP2ClientTransport.Posix>
    let registry: VerifiedPeerRegistry
    let expectedFingerprint: CertificateFingerprint
}
