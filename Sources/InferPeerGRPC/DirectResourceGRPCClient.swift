import Foundation
import GRPCCore
import InferPeerProtocol

/// Typed client facade over the generated v2 direct-resource client.
public struct DirectResourceGRPCClient<Client: InferPeer_V2_DirectResourceService.ClientProtocol>:
    Sendable
{
    /// Binary metadata key carrying a resource-scoped bearer credential.
    public static var credentialMetadataKey: String { "inferpeer-credential-bin" }

    let client: Client
    let options: CallOptions
    let metadata: Metadata

    /// Creates a client with symmetric bounded Protobuf message limits.
    public init(
        client: Client,
        maximumMessageBytes: Int = 4 * 1_024 * 1_024,
        credential: Data? = nil
    ) throws {
        guard maximumMessageBytes > 0 else { throw InferPeerGRPCError.invalidConfiguration }
        self.client = client
        var options = CallOptions.defaults
        options.maxRequestMessageBytes = maximumMessageBytes
        options.maxResponseMessageBytes = maximumMessageBytes
        self.options = options
        var metadata = Metadata()
        if let credential {
            guard !credential.isEmpty else { throw InferPeerGRPCError.invalidConfiguration }
            metadata.addBinary(Array(credential), forKey: Self.credentialMetadataKey)
        }
        self.metadata = metadata
    }

    /// Calls Pair.
    public func pair(_ request: InferPeer_V2_PairRequest) async throws
        -> InferPeer_V2_PairResponse
    {
        try await unary {
            try await client.pair(
                request: ClientRequest(message: request, metadata: metadata),
                options: options
            )
        }
    }

    /// Calls Hello.
    public func hello(_ request: InferPeer_V2_HelloRequest) async throws
        -> InferPeer_V2_HelloResponse
    {
        try await unary {
            try await client.hello(
                request: ClientRequest(message: request, metadata: metadata),
                options: options
            )
        }
    }

    /// Calls PrepareAssets.
    public func prepareAssets(_ request: InferPeer_V2_PrepareAssetsRequest) async throws
        -> InferPeer_V2_PrepareAssetsResponse
    {
        try await unary {
            try await client.prepareAssets(
                request: ClientRequest(message: request, metadata: metadata), options: options)
        }
    }

    /// Calls GetUploadStatus.
    public func getUploadStatus(_ request: InferPeer_V2_GetUploadStatusRequest) async throws
        -> InferPeer_V2_GetUploadStatusResponse
    {
        try await unary {
            try await client.getUploadStatus(
                request: ClientRequest(message: request, metadata: metadata), options: options)
        }
    }

    /// Calls StartRun.
    public func startRun(_ request: InferPeer_V2_StartRunRequest) async throws
        -> InferPeer_V2_StartRunResponse
    {
        try await unary {
            try await client.startRun(
                request: ClientRequest(message: request, metadata: metadata),
                options: options
            )
        }
    }

    /// Calls GetRun.
    public func getRun(_ request: InferPeer_V2_GetRunRequest) async throws
        -> InferPeer_V2_GetRunResponse
    {
        try await unary {
            try await client.getRun(
                request: ClientRequest(message: request, metadata: metadata),
                options: options
            )
        }
    }

    /// Calls CancelRun.
    public func cancelRun(_ request: InferPeer_V2_CancelRunRequest) async throws
        -> InferPeer_V2_CancelRunResponse
    {
        try await unary {
            try await client.cancelRun(
                request: ClientRequest(message: request, metadata: metadata),
                options: options
            )
        }
    }

    /// Calls ReleaseAsset.
    public func releaseAsset(_ request: InferPeer_V2_ReleaseAssetRequest) async throws
        -> InferPeer_V2_ReleaseAssetResponse
    {
        try await unary {
            try await client.releaseAsset(
                request: ClientRequest(message: request, metadata: metadata), options: options)
        }
    }

    func unary<Value: Sendable>(_ operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch {
            throw DirectRPCErrorMapper.publicError(from: error)
        }
    }
}
