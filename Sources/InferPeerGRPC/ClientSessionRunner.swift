import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import InferPeerCore
import InferPeerProtocol

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
}

extension ClientSessionRunner {
    static func openCaller(
        configuration: GRPCTransportConfiguration,
        registry: VerifiedPeerRegistry,
        expectedFingerprint: CertificateFingerprint,
        client: GRPCClient<HTTP2ClientTransport.Posix>
    ) async throws -> OpenedCaller {
        let inbound = BoundedMessagePipe<InferPeer_V1_ClientSessionResponse>(
            capacity: configuration.streamBufferLimit,
            isControl: MessagePriority.clientResponse
        )
        let outbound = BoundedMessagePipe<InferPeer_V1_ClientSessionRequest>(
            capacity: configuration.streamBufferLimit,
            isControl: MessagePriority.clientRequest
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
            let handshake = try await waitForHandshake(
                latch,
                timeout: configuration.handshakeTimeout
            )
            return makeOpenedCaller(
                context: context,
                client: client,
                connectionTask: connectionTask,
                rpcTask: rpcTask,
                handshake: handshake
            )
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
            capacity: configuration.streamBufferLimit,
            isControl: MessagePriority.workerResponse
        )
        let outbound = BoundedMessagePipe<InferPeer_V1_WorkerSessionRequest>(
            capacity: configuration.streamBufferLimit,
            isControl: MessagePriority.workerRequest
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
            let handshake = try await waitForHandshake(
                latch,
                timeout: configuration.handshakeTimeout
            )
            return makeOpenedWorker(
                context: context,
                client: client,
                connectionTask: connectionTask,
                rpcTask: rpcTask,
                handshake: handshake
            )
        } catch {
            connectionTask.cancel()
            rpcTask.cancel()
            throw GRPCErrorMapper.publicError(from: error)
        }
    }

    private static func makeOpenedCaller(
        context: RPCContext<
            InferPeer_V1_ClientSessionResponse,
            InferPeer_V1_ClientSessionRequest
        >,
        client: GRPCClient<HTTP2ClientTransport.Posix>,
        connectionTask: Task<Void, Never>,
        rpcTask: Task<Void, Never>,
        handshake: HandshakeResult
    ) -> OpenedCaller {
        let terminator = makeTerminator(
            client: client,
            connectionTask: connectionTask,
            rpcTask: rpcTask,
            inbound: context.inbound,
            outbound: context.outbound
        )
        let session = CallerSessionAdapter(
            inbound: context.inbound,
            outbound: context.outbound,
            configuration: context.configuration,
            negotiatedProtocol: handshake.negotiatedProtocol,
            terminator: terminator
        )
        return OpenedCaller(session: session, terminator: terminator)
    }

    private static func makeOpenedWorker(
        context: RPCContext<
            InferPeer_V1_WorkerSessionResponse,
            InferPeer_V1_WorkerSessionRequest
        >,
        client: GRPCClient<HTTP2ClientTransport.Posix>,
        connectionTask: Task<Void, Never>,
        rpcTask: Task<Void, Never>,
        handshake: HandshakeResult
    ) -> OpenedWorker {
        let terminator = makeTerminator(
            client: client,
            connectionTask: connectionTask,
            rpcTask: rpcTask,
            inbound: context.inbound,
            outbound: context.outbound
        )
        let session = WorkerSessionAdapter(
            inbound: context.inbound,
            outbound: context.outbound,
            configuration: context.configuration,
            negotiatedProtocol: handshake.negotiatedProtocol,
            terminator: terminator
        )
        return OpenedWorker(session: session, terminator: terminator)
    }

    private static func startClient(
        _ client: GRPCClient<HTTP2ClientTransport.Posix>
    ) -> Task<Void, Never> {
        Task {
            try? await client.runConnections()
        }
    }

    static func waitForHandshake<Value: Sendable>(
        _ latch: HandshakeLatch<Value>,
        timeout: Duration
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await latch.wait() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw InferPeerGRPCError.deadlineExceeded
            }
            guard let value = try await group.next() else {
                throw InferPeerGRPCError.internalFailure
            }
            group.cancelAll()
            return value
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
