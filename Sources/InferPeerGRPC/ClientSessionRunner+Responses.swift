import GRPCCore
import GRPCNIOTransportHTTP2Posix
import InferPeerProtocol

extension ClientSessionRunner {
    static func consumeCallerResponses(
        _ response: StreamingClientResponse<InferPeer_V1_ClientSessionResponse>,
        context: RPCContext<
            InferPeer_V1_ClientSessionResponse,
            InferPeer_V1_ClientSessionRequest
        >
    ) async throws {
        var iterator = response.messages.makeAsyncIterator()
        guard let first = try await iterator.next(isolation: nil) else {
            throw InferPeerGRPCError.invalidMessage
        }
        let identity = try context.registry.identity(matching: context.expectedFingerprint)
        let handshake = try ClientHandshakeValidator(configuration: context.configuration)
            .validateAccepted(first, identity: identity)
        await context.latch.succeed(handshake)
        var validator = remoteMetadataValidator(context.configuration, handshake: handshake)
        while let message = try await iterator.next(isolation: nil) {
            guard isCallerApplicationResponse(message) else {
                throw InferPeerGRPCError.invalidMessage
            }
            try validator.validate(message.metadata)
            try await context.inbound.send(message)
        }
    }

    static func consumeWorkerResponses(
        _ response: StreamingClientResponse<InferPeer_V1_WorkerSessionResponse>,
        context: RPCContext<
            InferPeer_V1_WorkerSessionResponse,
            InferPeer_V1_WorkerSessionRequest
        >
    ) async throws {
        var iterator = response.messages.makeAsyncIterator()
        guard let first = try await iterator.next(isolation: nil) else {
            throw InferPeerGRPCError.invalidMessage
        }
        let identity = try context.registry.identity(matching: context.expectedFingerprint)
        let handshake = try ClientHandshakeValidator(configuration: context.configuration)
            .validateAccepted(first, identity: identity)
        await context.latch.succeed(handshake)
        var validator = remoteMetadataValidator(context.configuration, handshake: handshake)
        while let message = try await iterator.next(isolation: nil) {
            guard isWorkerApplicationResponse(message) else {
                throw InferPeerGRPCError.invalidMessage
            }
            try validator.validate(message.metadata)
            try await context.inbound.send(message)
        }
    }

    static func remoteMetadataValidator(
        _ configuration: GRPCTransportConfiguration,
        handshake: HandshakeResult
    ) -> OrderedMetadataValidator {
        OrderedMetadataValidator(
            clusterID: configuration.clusterID,
            senderID: handshake.remoteIdentity.peerID,
            protocolVersion: handshake.negotiatedProtocol.version,
            nextSequence: 2
        )
    }

    static func callOptions(_ maximumMessageBytes: Int) -> CallOptions {
        var options = CallOptions.defaults
        options.maxRequestMessageBytes = maximumMessageBytes
        options.maxResponseMessageBytes = maximumMessageBytes
        return options
    }

    static func makeTerminator<Input: Sendable, Output: Sendable>(
        client: GRPCClient<HTTP2ClientTransport.Posix>,
        connectionTask: Task<Void, Never>,
        rpcTask: Task<Void, Never>,
        inbound: BoundedMessagePipe<Input>,
        outbound: BoundedMessagePipe<Output>
    ) -> SessionTerminator {
        SessionTerminator {
            inbound.finish()
            outbound.finish()
            client.beginGracefulShutdown()
            rpcTask.cancel()
            connectionTask.cancel()
        }
    }

    static func failClientSession<Input: Sendable, Output: Sendable>(
        _ error: any Error,
        inbound: BoundedMessagePipe<Input>,
        outbound: BoundedMessagePipe<Output>,
        latch: HandshakeLatch<HandshakeResult>
    ) {
        let mapped = GRPCErrorMapper.publicError(from: error)
        inbound.fail(mapped)
        outbound.fail(mapped)
        Task { await latch.fail(mapped) }
    }

    static func isCallerApplicationResponse(
        _ response: InferPeer_V1_ClientSessionResponse
    ) -> Bool {
        switch response.payload {
        case .requestAccepted, .requestStateChanged, .generationEvent, .cancellationUpdated,
            .requestFailed:
            true
        default:
            false
        }
    }

    static func isWorkerApplicationResponse(
        _ response: InferPeer_V1_WorkerSessionResponse
    ) -> Bool {
        switch response.payload {
        case .assignment, .cancelAttempt, .leaseExtended: true
        default: false
        }
    }
}
