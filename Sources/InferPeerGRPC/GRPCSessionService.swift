import GRPCCore
import GRPCNIOTransportHTTP2Posix
import InferPeerCore
import InferPeerProtocol

typealias ContextIdentityExtractor = @Sendable (ServerContext) throws -> PresentedPeerIdentity

struct GRPCSessionService: InferPeer_V1_InferPeerService.SimpleServiceProtocol {
    let configuration: GRPCTransportConfiguration
    let inboundSessions: BoundedMessagePipe<InboundPeerSession>
    let identityExtractor: ContextIdentityExtractor

    func clientSession(
        request: RPCAsyncSequence<InferPeer_V1_ClientSessionRequest, any Error>,
        response: RPCWriter<InferPeer_V1_ClientSessionResponse>,
        context: ServerContext
    ) async throws {
        do {
            let identity = try identityExtractor(context)
            let latch = HandshakeLatch<CoordinatorCallerSessionAdapter>()
            try await race(
                {
                    try await consumeCallerRequests(
                        request,
                        response: response,
                        identity: identity,
                        latch: latch
                    )
                },
                { try await writeCallerResponses(to: response, latch: latch) }
            )
        } catch {
            throw GRPCErrorMapper.rpcError(from: error)
        }
    }

    func workerSession(
        request: RPCAsyncSequence<InferPeer_V1_WorkerSessionRequest, any Error>,
        response: RPCWriter<InferPeer_V1_WorkerSessionResponse>,
        context: ServerContext
    ) async throws {
        do {
            let identity = try identityExtractor(context)
            let latch = HandshakeLatch<CoordinatorWorkerSessionAdapter>()
            try await race(
                {
                    try await consumeWorkerRequests(
                        request,
                        response: response,
                        identity: identity,
                        latch: latch
                    )
                },
                { try await writeWorkerResponses(to: response, latch: latch) }
            )
        } catch {
            throw GRPCErrorMapper.rpcError(from: error)
        }
    }
}

extension GRPCSessionService {
    private func consumeCallerRequests(
        _ request: RPCAsyncSequence<InferPeer_V1_ClientSessionRequest, any Error>,
        response: RPCWriter<InferPeer_V1_ClientSessionResponse>,
        identity: PresentedPeerIdentity,
        latch: HandshakeLatch<CoordinatorCallerSessionAdapter>
    ) async throws {
        do {
            var iterator = request.makeAsyncIterator()
            let first = try await requiredFirstMessage(from: &iterator)
            guard case .hello(let hello) = first.payload else {
                throw InferPeerGRPCError.invalidMessage
            }
            let negotiated = try await admitCaller(
                first,
                hello: hello,
                identity: identity,
                response: response
            )
            let session = makeCallerSession(identity: identity, negotiated: negotiated)
            try await response.write(
                HandshakeMessageFactory.callerAccepted(
                    configuration: configuration,
                    negotiated: negotiated
                )
            )
            try inboundSessions.send(.caller(session))
            await latch.succeed(session)
            try await consumeCallerApplicationMessages(
                from: &iterator,
                identity: identity,
                negotiated: negotiated,
                session: session
            )
        } catch {
            await latch.fail(error)
            throw error
        }
    }

    private func consumeWorkerRequests(
        _ request: RPCAsyncSequence<InferPeer_V1_WorkerSessionRequest, any Error>,
        response: RPCWriter<InferPeer_V1_WorkerSessionResponse>,
        identity: PresentedPeerIdentity,
        latch: HandshakeLatch<CoordinatorWorkerSessionAdapter>
    ) async throws {
        do {
            var iterator = request.makeAsyncIterator()
            let first = try await requiredFirstMessage(from: &iterator)
            guard case .hello(let hello) = first.payload else {
                throw InferPeerGRPCError.invalidMessage
            }
            let negotiated = try await admitWorker(
                first,
                hello: hello,
                identity: identity,
                response: response
            )
            let session = makeWorkerSession(identity: identity, negotiated: negotiated)
            try await response.write(
                HandshakeMessageFactory.workerAccepted(
                    configuration: configuration,
                    negotiated: negotiated
                )
            )
            try inboundSessions.send(.worker(session))
            await latch.succeed(session)
            try await consumeWorkerApplicationMessages(
                from: &iterator,
                identity: identity,
                negotiated: negotiated,
                session: session
            )
        } catch {
            await latch.fail(error)
            throw error
        }
    }

    private func admitCaller(
        _ first: InferPeer_V1_ClientSessionRequest,
        hello: InferPeer_V1_SessionHello,
        identity: PresentedPeerIdentity,
        response: RPCWriter<InferPeer_V1_ClientSessionResponse>
    ) async throws -> InferPeer_V1_NegotiatedProtocol {
        do {
            return try await ServerHandshakeValidator(configuration: configuration).validate(
                metadata: first.metadata,
                hello: hello,
                identity: identity,
                role: .caller
            )
        } catch {
            try? await response.write(
                HandshakeMessageFactory.callerRejected(configuration: configuration, error: error)
            )
            throw error
        }
    }

    private func admitWorker(
        _ first: InferPeer_V1_WorkerSessionRequest,
        hello: InferPeer_V1_SessionHello,
        identity: PresentedPeerIdentity,
        response: RPCWriter<InferPeer_V1_WorkerSessionResponse>
    ) async throws -> InferPeer_V1_NegotiatedProtocol {
        do {
            return try await ServerHandshakeValidator(configuration: configuration).validate(
                metadata: first.metadata,
                hello: hello,
                identity: identity,
                role: .worker
            )
        } catch {
            try? await response.write(
                HandshakeMessageFactory.workerRejected(configuration: configuration, error: error)
            )
            throw error
        }
    }

    private func requiredFirstMessage<Iterator: AsyncIteratorProtocol>(
        from iterator: inout Iterator
    ) async throws -> Iterator.Element {
        guard let first = try await iterator.next(isolation: nil) else {
            throw InferPeerGRPCError.invalidMessage
        }
        return first
    }

    private func consumeCallerApplicationMessages<Iterator: AsyncIteratorProtocol>(
        from iterator: inout Iterator,
        identity: PresentedPeerIdentity,
        negotiated: InferPeer_V1_NegotiatedProtocol,
        session: CoordinatorCallerSessionAdapter
    ) async throws where Iterator.Element == InferPeer_V1_ClientSessionRequest {
        var validator = metadataValidator(identity: identity, negotiated: negotiated)
        while let message = try await iterator.next(isolation: nil) {
            guard isCallerApplicationMessage(message) else {
                throw InferPeerGRPCError.invalidMessage
            }
            try validator.validate(message.metadata)
            try session.inbound.send(message)
        }
        session.finish()
    }

    private func consumeWorkerApplicationMessages<Iterator: AsyncIteratorProtocol>(
        from iterator: inout Iterator,
        identity: PresentedPeerIdentity,
        negotiated: InferPeer_V1_NegotiatedProtocol,
        session: CoordinatorWorkerSessionAdapter
    ) async throws where Iterator.Element == InferPeer_V1_WorkerSessionRequest {
        var validator = metadataValidator(identity: identity, negotiated: negotiated)
        while let message = try await iterator.next(isolation: nil) {
            guard isWorkerApplicationMessage(message) else {
                throw InferPeerGRPCError.invalidMessage
            }
            try validator.validate(message.metadata)
            try session.inbound.send(message)
        }
        session.finish()
    }

    private func metadataValidator(
        identity: PresentedPeerIdentity,
        negotiated: InferPeer_V1_NegotiatedProtocol
    ) -> OrderedMetadataValidator {
        OrderedMetadataValidator(
            clusterID: configuration.clusterID,
            senderID: identity.peerID,
            protocolVersion: negotiated.version,
            nextSequence: 2
        )
    }

    private func makeCallerSession(
        identity: PresentedPeerIdentity,
        negotiated: InferPeer_V1_NegotiatedProtocol
    ) -> CoordinatorCallerSessionAdapter {
        CoordinatorCallerSessionAdapter(
            authenticatedPeerID: identity.peerID,
            clusterID: configuration.clusterID,
            coordinatorID: configuration.credentials.identity.peerID,
            negotiatedProtocol: negotiated,
            capacity: configuration.streamBufferLimit
        )
    }

    private func makeWorkerSession(
        identity: PresentedPeerIdentity,
        negotiated: InferPeer_V1_NegotiatedProtocol
    ) -> CoordinatorWorkerSessionAdapter {
        CoordinatorWorkerSessionAdapter(
            authenticatedPeerID: identity.peerID,
            clusterID: configuration.clusterID,
            coordinatorID: configuration.credentials.identity.peerID,
            negotiatedProtocol: negotiated,
            capacity: configuration.streamBufferLimit
        )
    }
}

extension GRPCSessionService {
    private func writeCallerResponses(
        to writer: RPCWriter<InferPeer_V1_ClientSessionResponse>,
        latch: HandshakeLatch<CoordinatorCallerSessionAdapter>
    ) async throws {
        let session = try await latch.wait()
        for try await response in session.outbound.internalStream() {
            try await writer.write(response)
        }
    }

    private func writeWorkerResponses(
        to writer: RPCWriter<InferPeer_V1_WorkerSessionResponse>,
        latch: HandshakeLatch<CoordinatorWorkerSessionAdapter>
    ) async throws {
        let session = try await latch.wait()
        for try await response in session.outbound.internalStream() {
            try await writer.write(response)
        }
    }

    private func race(
        _ first: @escaping @Sendable () async throws -> Void,
        _ second: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask(operation: first)
            group.addTask(operation: second)
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func isCallerApplicationMessage(_ message: InferPeer_V1_ClientSessionRequest) -> Bool {
        switch message.payload {
        case .submit, .cancel, .resume, .acknowledgeEvents: true
        default: false
        }
    }

    private func isWorkerApplicationMessage(_ message: InferPeer_V1_WorkerSessionRequest) -> Bool {
        switch message.payload {
        case .status, .attemptAccepted, .attemptRejected, .leaseRenewal, .generationEvent: true
        default: false
        }
    }
}
