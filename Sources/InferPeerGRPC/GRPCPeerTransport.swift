import GRPCCore
import GRPCNIOTransportHTTP2Posix
import InferPeerCore
import InferPeerProtocol

/// gRPC Swift 2 transport implementing InferPeer's caller, worker, and coordinator contracts.
public actor GRPCPeerTransport: PeerTransport {
    private let configuration: GRPCTransportConfiguration
    private var listener: GRPCCoordinatorListener?
    private var clientTerminators: [SessionTerminator] = []

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
        try requireRole(.caller)
        let resources = try makeClientResources(endpoint: endpoint)
        let opened = try await ClientSessionRunner.openCaller(
            configuration: configuration,
            registry: resources.registry,
            expectedFingerprint: resources.expectedFingerprint,
            client: resources.client
        )
        clientTerminators.append(opened.terminator)
        return opened.session
    }

    /// Opens and negotiates a mutually authenticated worker bidirectional RPC.
    public func connectWorker(
        to endpoint: PeerEndpoint
    ) async throws -> any WorkerTransportSession {
        try requireRole(.worker)
        let resources = try makeClientResources(endpoint: endpoint)
        let opened = try await ClientSessionRunner.openWorker(
            configuration: configuration,
            registry: resources.registry,
            expectedFingerprint: resources.expectedFingerprint,
            client: resources.client
        )
        clientTerminators.append(opened.terminator)
        return opened.session
    }

    /// Closes the listener, active client sessions, and their underlying gRPC clients.
    public func stop() async {
        await listener?.close()
        listener = nil
        clientTerminators.forEach { $0.terminate() }
        clientTerminators.removeAll()
    }

    private func requireRole(_ role: NodeRole) throws {
        guard configuration.enabledRoles.contains(role) else {
            throw InferPeerGRPCError.roleDisabled
        }
    }

    private func makeClientResources(
        endpoint: PeerEndpoint
    ) throws -> ClientResources {
        try configuration.networkPolicy.validate(endpoint)
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

enum ClientSessionRunner {
    struct RPCContext<Input: Sendable, Output: Sendable>: Sendable {
        let configuration: GRPCTransportConfiguration
        let registry: VerifiedPeerRegistry
        let expectedFingerprint: CertificateFingerprint
        let inbound: BoundedMessagePipe<Input>
        let outbound: BoundedMessagePipe<Output>
        let latch: HandshakeLatch<HandshakeResult>
    }

    struct OpenedCaller: Sendable {
        let session: CallerSessionAdapter
        let terminator: SessionTerminator
    }

    struct OpenedWorker: Sendable {
        let session: WorkerSessionAdapter
        let terminator: SessionTerminator
    }

    static func openCaller(
        configuration: GRPCTransportConfiguration,
        registry: VerifiedPeerRegistry,
        expectedFingerprint: CertificateFingerprint,
        client: GRPCClient<HTTP2ClientTransport.Posix>
    ) async throws -> OpenedCaller {
        let inbound = BoundedMessagePipe<InferPeer_V1_ClientSessionResponse>(
            capacity: configuration.streamBufferLimit
        )
        let outbound = BoundedMessagePipe<InferPeer_V1_ClientSessionRequest>(
            capacity: configuration.streamBufferLimit
        )
        let latch = HandshakeLatch<HandshakeResult>()
        let connectionTask = startClient(client)
        let context = RPCContext(
            configuration: configuration,
            registry: registry,
            expectedFingerprint: expectedFingerprint,
            inbound: inbound,
            outbound: outbound,
            latch: latch
        )
        let rpcTask = startCallerRPC(client: client, context: context)
        do {
            let handshake = try await latch.wait()
            let terminator = makeTerminator(
                client: client,
                connectionTask: connectionTask,
                rpcTask: rpcTask,
                inbound: inbound,
                outbound: outbound
            )
            let session = CallerSessionAdapter(
                inbound: inbound,
                outbound: outbound,
                configuration: configuration,
                negotiatedProtocol: handshake.negotiatedProtocol,
                terminator: terminator
            )
            return OpenedCaller(session: session, terminator: terminator)
        } catch {
            connectionTask.cancel()
            rpcTask.cancel()
            throw GRPCErrorMapper.publicError(from: error)
        }
    }

    static func openWorker(
        configuration: GRPCTransportConfiguration,
        registry: VerifiedPeerRegistry,
        expectedFingerprint: CertificateFingerprint,
        client: GRPCClient<HTTP2ClientTransport.Posix>
    ) async throws -> OpenedWorker {
        let inbound = BoundedMessagePipe<InferPeer_V1_WorkerSessionResponse>(
            capacity: configuration.streamBufferLimit
        )
        let outbound = BoundedMessagePipe<InferPeer_V1_WorkerSessionRequest>(
            capacity: configuration.streamBufferLimit
        )
        let latch = HandshakeLatch<HandshakeResult>()
        let connectionTask = startClient(client)
        let context = RPCContext(
            configuration: configuration,
            registry: registry,
            expectedFingerprint: expectedFingerprint,
            inbound: inbound,
            outbound: outbound,
            latch: latch
        )
        let rpcTask = startWorkerRPC(client: client, context: context)
        do {
            let handshake = try await latch.wait()
            let terminator = makeTerminator(
                client: client,
                connectionTask: connectionTask,
                rpcTask: rpcTask,
                inbound: inbound,
                outbound: outbound
            )
            let session = WorkerSessionAdapter(
                inbound: inbound,
                outbound: outbound,
                configuration: configuration,
                negotiatedProtocol: handshake.negotiatedProtocol,
                terminator: terminator
            )
            return OpenedWorker(session: session, terminator: terminator)
        } catch {
            connectionTask.cancel()
            rpcTask.cancel()
            throw GRPCErrorMapper.publicError(from: error)
        }
    }

    private static func startClient(
        _ client: GRPCClient<HTTP2ClientTransport.Posix>
    ) -> Task<Void, Never> {
        Task {
            try? await client.runConnections()
        }
    }

    private static func startCallerRPC(
        client: GRPCClient<HTTP2ClientTransport.Posix>,
        context: RPCContext<
            InferPeer_V1_ClientSessionResponse,
            InferPeer_V1_ClientSessionRequest
        >
    ) -> Task<Void, Never> {
        Task {
            defer { client.beginGracefulShutdown() }
            do {
                let service = InferPeer_V1_InferPeerService.Client(wrapping: client)
                try await service.clientSession(
                    options: callOptions(context.configuration.maximumMessageBytes),
                    requestProducer: { writer in
                        try await writer.write(
                            HandshakeMessageFactory.callerHello(
                                configuration: context.configuration
                            ))
                        for try await message in context.outbound.internalStream() {
                            try await writer.write(message)
                        }
                    },
                    onResponse: { response in
                        try await consumeCallerResponses(
                            response,
                            context: context
                        )
                    }
                )
                context.inbound.finish()
            } catch {
                failClientSession(
                    error,
                    inbound: context.inbound,
                    outbound: context.outbound,
                    latch: context.latch
                )
            }
        }
    }

    private static func startWorkerRPC(
        client: GRPCClient<HTTP2ClientTransport.Posix>,
        context: RPCContext<
            InferPeer_V1_WorkerSessionResponse,
            InferPeer_V1_WorkerSessionRequest
        >
    ) -> Task<Void, Never> {
        Task {
            defer { client.beginGracefulShutdown() }
            do {
                let service = InferPeer_V1_InferPeerService.Client(wrapping: client)
                try await service.workerSession(
                    options: callOptions(context.configuration.maximumMessageBytes),
                    requestProducer: { writer in
                        try await writer.write(
                            HandshakeMessageFactory.workerHello(
                                configuration: context.configuration
                            ))
                        for try await message in context.outbound.internalStream() {
                            try await writer.write(message)
                        }
                    },
                    onResponse: { response in
                        try await consumeWorkerResponses(
                            response,
                            context: context
                        )
                    }
                )
                context.inbound.finish()
            } catch {
                failClientSession(
                    error,
                    inbound: context.inbound,
                    outbound: context.outbound,
                    latch: context.latch
                )
            }
        }
    }
}
