import InferPeerCore
import InferPeerProtocol

/// A demand-aware stream used by v2 service implementations.
public typealias DirectRPCStream<Element: Sendable> = TransportMessageStream<Element>

/// Application-owned implementation of all v2 direct-resource operations.
public protocol DirectResourceServiceHandling: Sendable {
    /// Consumes one invitation and returns scoped credentials.
    func pair(_ request: InferPeer_V2_PairRequest) async throws -> InferPeer_V2_PairResponse
    /// Negotiates protocol and endpoint capabilities.
    func hello(_ request: InferPeer_V2_HelloRequest) async throws -> InferPeer_V2_HelloResponse
    /// Produces revisioned resource updates.
    func watchResource(
        _ request: InferPeer_V2_WatchResourceRequest
    ) async throws -> DirectRPCStream<InferPeer_V2_WatchResourceResponse>
    /// Declares asset uploads before bytes are accepted.
    func prepareAssets(
        _ request: InferPeer_V2_PrepareAssetsRequest
    ) async throws -> InferPeer_V2_PrepareAssetsResponse
    /// Consumes one ordered asset upload.
    func uploadAsset(
        _ requests: DirectRPCStream<InferPeer_V2_UploadAssetRequest>
    ) async throws -> InferPeer_V2_UploadAssetResponse
    /// Reports the durable upload offset.
    func getUploadStatus(
        _ request: InferPeer_V2_GetUploadStatusRequest
    ) async throws -> InferPeer_V2_GetUploadStatusResponse
    /// Produces one authorized output-asset range.
    func readAsset(
        _ request: InferPeer_V2_ReadAssetRequest
    ) async throws -> DirectRPCStream<InferPeer_V2_ReadAssetResponse>
    /// Produces exact-model preparation progress.
    func prepareModel(
        _ request: InferPeer_V2_PrepareModelRequest
    ) async throws -> DirectRPCStream<InferPeer_V2_PrepareModelResponse>
    /// Durably admits one immutable run.
    func startRun(
        _ request: InferPeer_V2_StartRunRequest
    ) async throws -> InferPeer_V2_StartRunResponse
    /// Consumes replay control and produces ordered run events.
    func watchRun(
        _ requests: DirectRPCStream<InferPeer_V2_WatchRunRequest>
    ) async throws -> DirectRPCStream<InferPeer_V2_WatchRunResponse>
    /// Reconciles one durable run.
    func getRun(_ request: InferPeer_V2_GetRunRequest) async throws -> InferPeer_V2_GetRunResponse
    /// Idempotently requests run cancellation.
    func cancelRun(
        _ request: InferPeer_V2_CancelRunRequest
    ) async throws -> InferPeer_V2_CancelRunResponse
    /// Idempotently releases an asset receipt.
    func releaseAsset(
        _ request: InferPeer_V2_ReleaseAssetRequest
    ) async throws -> InferPeer_V2_ReleaseAssetResponse
}
