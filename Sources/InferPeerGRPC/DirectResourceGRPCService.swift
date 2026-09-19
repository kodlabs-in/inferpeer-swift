import GRPCCore
import InferPeerProtocol

/// Generated-service adapter for an application-owned v2 resource handler.
public struct DirectResourceGRPCService: InferPeer_V2_DirectResourceService.ServiceProtocol {
    private let handler: any DirectResourceServiceHandling
    private let streamBufferLimit: Int
    let authorizer: DirectResourceRequestAuthorizer?

    /// Creates a service whose inbound streams apply bounded backpressure.
    public init(
        handler: any DirectResourceServiceHandling,
        authorizer: DirectResourceRequestAuthorizer? = nil,
        streamBufferLimit: Int = 32
    ) throws {
        guard streamBufferLimit > 0 else { throw InferPeerGRPCError.invalidBufferLimit }
        self.handler = handler
        self.authorizer = authorizer
        self.streamBufferLimit = streamBufferLimit
    }

    /// Handles one invitation-bound pairing request.
    public func pair(
        request: InferPeer_V2_PairRequest,
        context _: ServerContext
    ) async throws -> InferPeer_V2_PairResponse {
        try await mapped { try await handler.pair(request) }
    }

    /// Negotiates direct-resource protocol support.
    public func hello(
        request: InferPeer_V2_HelloRequest,
        context _: ServerContext
    ) async throws -> InferPeer_V2_HelloResponse {
        try await mapped { try await handler.hello(request) }
    }

    /// Streams revisioned resource state and heartbeats.
    public func watchResource(
        request: InferPeer_V2_WatchResourceRequest,
        response: RPCWriter<InferPeer_V2_WatchResourceResponse>,
        context _: ServerContext
    ) async throws {
        try await mapped {
            try await write(try await handler.watchResource(request), to: response)
        }
    }

    /// Admits bounded asset declarations and returns upload tickets.
    public func prepareAssets(
        request: InferPeer_V2_PrepareAssetsRequest,
        context _: ServerContext
    ) async throws -> InferPeer_V2_PrepareAssetsResponse {
        try await mapped { try await handler.prepareAssets(request) }
    }

    /// Consumes an ordered, backpressured asset upload stream.
    public func uploadAsset(
        request: RPCAsyncSequence<InferPeer_V2_UploadAssetRequest, any Error>,
        context _: ServerContext
    ) async throws -> InferPeer_V2_UploadAssetResponse {
        try await mapped {
            try await withInboundStream(request) { stream in
                try await handler.uploadAsset(stream)
            }
        }
    }

    /// Returns the durable offset for one upload ticket.
    public func getUploadStatus(
        request: InferPeer_V2_GetUploadStatusRequest,
        context _: ServerContext
    ) async throws -> InferPeer_V2_GetUploadStatusResponse {
        try await mapped { try await handler.getUploadStatus(request) }
    }

    /// Streams one authorized bounded output-asset range.
    public func readAsset(
        request: InferPeer_V2_ReadAssetRequest,
        response: RPCWriter<InferPeer_V2_ReadAssetResponse>,
        context _: ServerContext
    ) async throws {
        try await mapped {
            try await write(try await handler.readAsset(request), to: response)
        }
    }

    /// Streams preparation progress for one exact model artifact.
    public func prepareModel(
        request: InferPeer_V2_PrepareModelRequest,
        response: RPCWriter<InferPeer_V2_PrepareModelResponse>,
        context _: ServerContext
    ) async throws {
        try await mapped {
            try await write(try await handler.prepareModel(request), to: response)
        }
    }

    /// Durably admits or reconciles one immutable run specification.
    public func startRun(
        request: InferPeer_V2_StartRunRequest,
        context _: ServerContext
    ) async throws -> InferPeer_V2_StartRunResponse {
        try await mapped { try await handler.startRun(request) }
    }

    /// Exchanges replay cursors, acknowledgements, and ordered run events.
    public func watchRun(
        request: RPCAsyncSequence<InferPeer_V2_WatchRunRequest, any Error>,
        response: RPCWriter<InferPeer_V2_WatchRunResponse>,
        context _: ServerContext
    ) async throws {
        try await mapped {
            try await withInboundStream(request) { stream in
                try await write(try await handler.watchRun(stream), to: response)
            }
        }
    }

    /// Reconciles durable run state and its replayable sequence range.
    public func getRun(
        request: InferPeer_V2_GetRunRequest,
        context _: ServerContext
    ) async throws -> InferPeer_V2_GetRunResponse {
        try await mapped { try await handler.getRun(request) }
    }

    /// Idempotently requests cancellation for one admitted run.
    public func cancelRun(
        request: InferPeer_V2_CancelRunRequest,
        context _: ServerContext
    ) async throws -> InferPeer_V2_CancelRunResponse {
        try await mapped { try await handler.cancelRun(request) }
    }

    /// Idempotently releases one owner-bound asset receipt.
    public func releaseAsset(
        request: InferPeer_V2_ReleaseAssetRequest,
        context _: ServerContext
    ) async throws -> InferPeer_V2_ReleaseAssetResponse {
        try await mapped { try await handler.releaseAsset(request) }
    }
}

extension DirectResourceGRPCService {
    private func mapped<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch {
            throw DirectRPCErrorMapper.rpcError(from: error)
        }
    }

    private func write<Element: Sendable>(
        _ stream: DirectRPCStream<Element>,
        to writer: RPCWriter<Element>
    ) async throws {
        for try await value in stream {
            try await writer.write(value)
        }
    }

    private func withInboundStream<Input: Sendable, Output: Sendable>(
        _ source: RPCAsyncSequence<Input, any Error>,
        operation: @escaping @Sendable (DirectRPCStream<Input>) async throws -> Output
    ) async throws -> Output {
        let pipe = BoundedMessagePipe<Input>(capacity: streamBufferLimit)
        return try await withThrowingTaskGroup(of: InboundStreamResult<Output>.self) { group in
            group.addTask {
                do {
                    for try await value in source {
                        try await pipe.send(value)
                    }
                    pipe.finish()
                    return .producerFinished
                } catch {
                    pipe.fail(error)
                    throw error
                }
            }
            group.addTask {
                .output(try await operation(pipe.internalStream()))
            }
            while let result = try await group.next() {
                guard case .output(let output) = result else { continue }
                group.cancelAll()
                pipe.finish()
                return output
            }
            throw InferPeerGRPCError.sessionClosed
        }
    }
}

private enum InboundStreamResult<Output: Sendable>: Sendable {
    case producerFinished
    case output(Output)
}
