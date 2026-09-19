import GRPCCore
import InferPeerCore
@testable import InferPeerGRPC
import InferPeerProtocol
import Testing

@Suite("v2 direct gRPC service")
struct DirectResourceGRPCServiceTests {
    @Test("service rejects an unbounded stream configuration")
    func invalidBufferLimit() {
        #expect(throws: InferPeerGRPCError.invalidBufferLimit) {
            _ = try DirectResourceGRPCService(
                handler: DirectServiceTestHandler(),
                streamBufferLimit: 0
            )
        }
    }

    @Test("unary RPC delegates to the application handler")
    func helloDelegates() async throws {
        let service = try DirectResourceGRPCService(handler: DirectServiceTestHandler())
        let request = InferPeer_V2_HelloRequest.with { $0.protocolMajor = 2 }

        let response = try await withServerContextRPCCancellationHandle { cancellation in
            try await service.hello(request: request, context: helloContext(cancellation))
        }

        #expect(response.protocolMajor == 2)
        #expect(response.resourceID == "resource-1")
    }

    @Test("application errors become classified gRPC status")
    func typedErrorMapping() async throws {
        let error = InferPeerError(code: .queueFull, isRetryable: true)
        let service = try DirectResourceGRPCService(
            handler: DirectServiceTestHandler(helloError: error)
        )

        await #expect(throws: RPCError.self) {
            try await withServerContextRPCCancellationHandle { cancellation in
                try await service.hello(
                    request: InferPeer_V2_HelloRequest(),
                    context: helloContext(cancellation)
                )
            }
        }
    }

    private func helloContext(
        _ cancellation: ServerContext.RPCCancellationHandle
    ) -> ServerContext {
        ServerContext(
            descriptor: InferPeer_V2_DirectResourceService.Method.Hello.descriptor,
            remotePeer: "in-process:caller",
            localPeer: "in-process:resource",
            cancellation: cancellation
        )
    }
}

private struct DirectServiceTestHandler: DirectResourceServiceHandling {
    let helloError: InferPeerError?

    init(helloError: InferPeerError? = nil) {
        self.helloError = helloError
    }

    func pair(_: InferPeer_V2_PairRequest) async throws -> InferPeer_V2_PairResponse {
        try await unavailable()
    }

    func hello(_ request: InferPeer_V2_HelloRequest) async throws -> InferPeer_V2_HelloResponse {
        await Task.yield()
        if let helloError { throw helloError }
        return InferPeer_V2_HelloResponse.with {
            $0.protocolMajor = request.protocolMajor
            $0.resourceID = "resource-1"
        }
    }

    func watchResource(
        _: InferPeer_V2_WatchResourceRequest
    ) async throws -> DirectRPCStream<InferPeer_V2_WatchResourceResponse> {
        try await unavailable()
    }

    func prepareAssets(
        _: InferPeer_V2_PrepareAssetsRequest
    ) async throws -> InferPeer_V2_PrepareAssetsResponse {
        try await unavailable()
    }

    func uploadAsset(
        _: DirectRPCStream<InferPeer_V2_UploadAssetRequest>
    ) async throws -> InferPeer_V2_UploadAssetResponse {
        try await unavailable()
    }

    func getUploadStatus(
        _: InferPeer_V2_GetUploadStatusRequest
    ) async throws -> InferPeer_V2_GetUploadStatusResponse {
        try await unavailable()
    }

    func readAsset(
        _: InferPeer_V2_ReadAssetRequest
    ) async throws -> DirectRPCStream<InferPeer_V2_ReadAssetResponse> {
        try await unavailable()
    }

    func prepareModel(
        _: InferPeer_V2_PrepareModelRequest
    ) async throws -> DirectRPCStream<InferPeer_V2_PrepareModelResponse> {
        try await unavailable()
    }

    func startRun(
        _: InferPeer_V2_StartRunRequest
    ) async throws -> InferPeer_V2_StartRunResponse {
        try await unavailable()
    }

    func watchRun(
        _: DirectRPCStream<InferPeer_V2_WatchRunRequest>
    ) async throws -> DirectRPCStream<InferPeer_V2_WatchRunResponse> {
        try await unavailable()
    }

    func getRun(_: InferPeer_V2_GetRunRequest) async throws -> InferPeer_V2_GetRunResponse {
        try await unavailable()
    }

    func cancelRun(
        _: InferPeer_V2_CancelRunRequest
    ) async throws -> InferPeer_V2_CancelRunResponse {
        try await unavailable()
    }

    func releaseAsset(
        _: InferPeer_V2_ReleaseAssetRequest
    ) async throws -> InferPeer_V2_ReleaseAssetResponse {
        try await unavailable()
    }

    private func unavailable<Value: Sendable>() async throws -> Value {
        await Task.yield()
        throw InferPeerError(code: .internal, isRetryable: false)
    }
}
