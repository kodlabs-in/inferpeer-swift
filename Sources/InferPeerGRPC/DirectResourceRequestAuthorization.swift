import Foundation
import GRPCCore
import InferPeerCore
import InferPeerProtocol

/// Authorizes one bearer credential and returns its opaque owner identity.
public struct DirectResourceRequestAuthorizer: Sendable {
    private let operation: @Sendable (Data) async throws -> String

    /// Creates an authorizer around the host's credential validation operation.
    public init(_ operation: @escaping @Sendable (Data) async throws -> String) {
        self.operation = operation
    }

    func authorize(_ credential: Data) async throws -> String {
        try await operation(credential)
    }
}

/// Owner context visible to a resource handler for credential-scoped state.
public enum DirectResourceRequestContext {
    /// Owner identity authorized for the current host-service task.
    @TaskLocal public static var principalID: String?
}

extension DirectResourceGRPCService {
    /// Handles unauthenticated single-use invitation exchange.
    public func pair(
        request: ServerRequest<InferPeer_V2_PairRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<InferPeer_V2_PairResponse> {
        ServerResponse(
            message: try await pair(request: request.message, context: context)
        )
    }

    /// Authenticates and negotiates the direct protocol session.
    public func hello(
        request: ServerRequest<InferPeer_V2_HelloRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<InferPeer_V2_HelloResponse> {
        try await authenticated(request.metadata) { principal in
            ServerResponse(
                message: try await DirectResourceRequestContext.$principalID.withValue(
                    principal
                ) {
                    try await hello(request: request.message, context: context)
                }
            )
        }
    }

    /// Authenticates and streams resource snapshots and heartbeats.
    public func watchResource(
        request: ServerRequest<InferPeer_V2_WatchResourceRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<InferPeer_V2_WatchResourceResponse> {
        let principal = try await authorizedPrincipal(request.metadata)
        return StreamingServerResponse(metadata: [:]) { writer in
            try await DirectResourceRequestContext.$principalID.withValue(principal) {
                try await watchResource(
                    request: request.message,
                    response: writer,
                    context: context
                )
            }
            return [:]
        }
    }

    /// Authenticates and creates owner-scoped asset upload tickets.
    public func prepareAssets(
        request: ServerRequest<InferPeer_V2_PrepareAssetsRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<InferPeer_V2_PrepareAssetsResponse> {
        try await authenticated(request.metadata) { principal in
            ServerResponse(
                message: try await DirectResourceRequestContext.$principalID.withValue(
                    principal
                ) {
                    try await prepareAssets(request: request.message, context: context)
                }
            )
        }
    }

    /// Authenticates and receives one owner-scoped asset stream.
    public func uploadAsset(
        request: StreamingServerRequest<InferPeer_V2_UploadAssetRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<InferPeer_V2_UploadAssetResponse> {
        try await authenticated(request.metadata) { principal in
            ServerResponse(
                message: try await DirectResourceRequestContext.$principalID.withValue(
                    principal
                ) {
                    try await uploadAsset(request: request.messages, context: context)
                }
            )
        }
    }

    /// Authenticates and reports the current upload offset.
    public func getUploadStatus(
        request: ServerRequest<InferPeer_V2_GetUploadStatusRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<InferPeer_V2_GetUploadStatusResponse> {
        try await authenticated(request.metadata) { principal in
            ServerResponse(
                message: try await DirectResourceRequestContext.$principalID.withValue(
                    principal
                ) {
                    try await getUploadStatus(request: request.message, context: context)
                }
            )
        }
    }

    /// Authenticates and streams one owner-scoped retained asset.
    public func readAsset(
        request: ServerRequest<InferPeer_V2_ReadAssetRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<InferPeer_V2_ReadAssetResponse> {
        let principal = try await authorizedPrincipal(request.metadata)
        return StreamingServerResponse(metadata: [:]) { writer in
            try await DirectResourceRequestContext.$principalID.withValue(principal) {
                try await readAsset(
                    request: request.message,
                    response: writer,
                    context: context
                )
            }
            return [:]
        }
    }

    /// Authenticates and streams exact-model preparation progress.
    public func prepareModel(
        request: ServerRequest<InferPeer_V2_PrepareModelRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<InferPeer_V2_PrepareModelResponse> {
        let principal = try await authorizedPrincipal(request.metadata)
        return StreamingServerResponse(metadata: [:]) { writer in
            try await DirectResourceRequestContext.$principalID.withValue(principal) {
                try await prepareModel(
                    request: request.message,
                    response: writer,
                    context: context
                )
            }
            return [:]
        }
    }

    /// Authenticates and admits one immutable run specification.
    public func startRun(
        request: ServerRequest<InferPeer_V2_StartRunRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<InferPeer_V2_StartRunResponse> {
        try await authenticated(request.metadata) { principal in
            ServerResponse(
                message: try await DirectResourceRequestContext.$principalID.withValue(
                    principal
                ) {
                    try await startRun(request: request.message, context: context)
                }
            )
        }
    }

    /// Authenticates and streams replayable run events with acknowledgements.
    public func watchRun(
        request: StreamingServerRequest<InferPeer_V2_WatchRunRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<InferPeer_V2_WatchRunResponse> {
        let principal = try await authorizedPrincipal(request.metadata)
        return StreamingServerResponse(metadata: [:]) { writer in
            try await DirectResourceRequestContext.$principalID.withValue(principal) {
                try await watchRun(
                    request: request.messages,
                    response: writer,
                    context: context
                )
            }
            return [:]
        }
    }

    /// Authenticates and reconciles one run's current state.
    public func getRun(
        request: ServerRequest<InferPeer_V2_GetRunRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<InferPeer_V2_GetRunResponse> {
        try await authenticated(request.metadata) { principal in
            ServerResponse(
                message: try await DirectResourceRequestContext.$principalID.withValue(
                    principal
                ) {
                    try await getRun(request: request.message, context: context)
                }
            )
        }
    }

    /// Authenticates and requests cancellation of one run.
    public func cancelRun(
        request: ServerRequest<InferPeer_V2_CancelRunRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<InferPeer_V2_CancelRunResponse> {
        try await authenticated(request.metadata) { principal in
            ServerResponse(
                message: try await DirectResourceRequestContext.$principalID.withValue(
                    principal
                ) {
                    try await cancelRun(request: request.message, context: context)
                }
            )
        }
    }

    /// Authenticates and releases one owner-scoped asset receipt.
    public func releaseAsset(
        request: ServerRequest<InferPeer_V2_ReleaseAssetRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<InferPeer_V2_ReleaseAssetResponse> {
        try await authenticated(request.metadata) { principal in
            ServerResponse(
                message: try await DirectResourceRequestContext.$principalID.withValue(
                    principal
                ) {
                    try await releaseAsset(request: request.message, context: context)
                }
            )
        }
    }

    private func authenticated<Value: Sendable>(
        _ metadata: Metadata,
        operation: (String) async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation(try await authorizedPrincipal(metadata))
        } catch {
            throw DirectRPCErrorMapper.rpcError(from: error)
        }
    }

    private func authorizedPrincipal(_ metadata: Metadata) async throws -> String {
        guard let authorizer,
            let bytes = Array(metadata[binaryValues: DirectResourceGRPCClientCredential.key]).only
        else {
            throw InferPeerError(code: .unauthenticated, isRetryable: false)
        }
        return try await authorizer.authorize(Data(bytes))
    }
}

private enum DirectResourceGRPCClientCredential {
    static let key = "inferpeer-credential-bin"
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
