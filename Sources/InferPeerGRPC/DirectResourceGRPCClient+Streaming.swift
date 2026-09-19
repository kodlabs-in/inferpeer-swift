import GRPCCore
import InferPeerProtocol

extension DirectResourceGRPCClient {
    /// Calls WatchResource and keeps the RPC alive for the response callback's duration.
    public func watchResource<Result: Sendable>(
        _ request: InferPeer_V2_WatchResourceRequest,
        onResponse:
            @Sendable @escaping (
                StreamingClientResponse<InferPeer_V2_WatchResourceResponse>
            ) async throws -> Result
    ) async throws -> Result {
        try await stream {
            try await client.watchResource(
                request: ClientRequest(message: request),
                options: options,
                onResponse: onResponse
            )
        }
    }

    /// Calls ReadAsset and keeps the RPC alive for the response callback's duration.
    public func readAsset<Result: Sendable>(
        _ request: InferPeer_V2_ReadAssetRequest,
        onResponse:
            @Sendable @escaping (
                StreamingClientResponse<InferPeer_V2_ReadAssetResponse>
            ) async throws -> Result
    ) async throws -> Result {
        try await stream {
            try await client.readAsset(
                request: ClientRequest(message: request),
                options: options,
                onResponse: onResponse
            )
        }
    }

    /// Calls PrepareModel and keeps the RPC alive for the response callback's duration.
    public func prepareModel<Result: Sendable>(
        _ request: InferPeer_V2_PrepareModelRequest,
        onResponse:
            @Sendable @escaping (
                StreamingClientResponse<InferPeer_V2_PrepareModelResponse>
            ) async throws -> Result
    ) async throws -> Result {
        try await stream {
            try await client.prepareModel(
                request: ClientRequest(message: request),
                options: options,
                onResponse: onResponse
            )
        }
    }

    /// Calls UploadAsset with a demand-aware request writer.
    public func uploadAsset(
        requestProducer:
            @Sendable @escaping (
                RPCWriter<InferPeer_V2_UploadAssetRequest>
            ) async throws -> Void
    ) async throws -> InferPeer_V2_UploadAssetResponse {
        try await unary {
            try await client.uploadAsset(
                request: StreamingClientRequest(producer: requestProducer),
                options: options
            )
        }
    }

    /// Calls WatchRun with demand-aware request and response streams.
    public func watchRun<Result: Sendable>(
        requestProducer:
            @Sendable @escaping (
                RPCWriter<InferPeer_V2_WatchRunRequest>
            ) async throws -> Void,
        onResponse:
            @Sendable @escaping (
                StreamingClientResponse<InferPeer_V2_WatchRunResponse>
            ) async throws -> Result
    ) async throws -> Result {
        try await stream {
            try await client.watchRun(
                request: StreamingClientRequest(producer: requestProducer),
                options: options,
                onResponse: onResponse
            )
        }
    }

    private func stream<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch {
            throw DirectRPCErrorMapper.publicError(from: error)
        }
    }
}
