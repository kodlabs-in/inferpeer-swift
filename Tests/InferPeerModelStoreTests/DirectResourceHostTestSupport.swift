import Crypto
import Foundation
@testable import InferPeer
import InferPeerCore
import InferPeerGRPC
import InferPeerInference
import InferPeerModelStore
import InferPeerProtocol
import InferPeerSecurity
import Testing

func uploadAsset(
    _ bytes: Data,
    handler: DirectResourceHostHandler
) async throws -> InferPeer_V2_UploadAssetResponse {
    let prepared = try await withPrincipal("owner-one") {
        try await handler.prepareAssets(
            InferPeer_V2_PrepareAssetsRequest.with {
                $0.assets = [
                    InferPeer_V2_AssetDeclaration.with {
                        $0.clientAssetID = "image-one"
                        $0.byteCount = UInt64(bytes.count)
                        $0.sha256 = Data(SHA256.hash(data: bytes))
                        $0.mediaType = "image/jpeg"
                    }
                ]
            }
        )
    }
    let ticket = try #require(prepared.tickets.first?.ticket)
    let upload = DirectRPCStream<InferPeer_V2_UploadAssetRequest>.makeStream()
    upload.continuation.yield(
        InferPeer_V2_UploadAssetRequest.with {
            $0.ticket = ticket
            $0.offset = 0
            $0.data = bytes
        }
    )
    upload.continuation.finish()
    return try await withPrincipal("owner-one") {
        try await handler.uploadAsset(upload.stream)
    }
}

struct DirectHostFixture {
    let modelFixture: ModelStoreFixture
    let store: InferPeerModelStore
    let installed: InstalledModel
    let invitations: DirectResourceInvitationAuthority
    let access: DirectResourceAccessController
    let handler: DirectResourceHostHandler
    let resourceID = ResourceID(rawValue: "fixture-resource")

    init(
        runtimeAdapter: any InferPeerRuntimeAdapter = TestRuntimeAdapter(),
        seedOrphanAsset: Bool = false
    ) async throws {
        let modelFixture = try ModelStoreFixture()
        let store = try await InferPeerModelStore.open(
            configuration: modelFixture.configuration(
                downloader: MemoryModelDownloader(data: modelFixture.data),
                adapters: [runtimeAdapter]
            )
        )
        let installation = try await store.install(
            modelFixture.entry.metadata.key,
            task: .textGeneration,
            on: makeDevice(),
            authorization: ModelDownloadAuthorization(resourceID: .local)
        )
        let installed = try await installedModel(from: installation)
        let secrets = HostMemorySecretStore()
        let invitations = DirectResourceInvitationAuthority(secretStore: secrets)
        let access = try DirectResourceAccessController(
            secretStore: secrets,
            invitations: invitations
        )
        let assetRoot = modelFixture.root.appendingPathComponent("assets", isDirectory: true)
        if seedOrphanAsset {
            try seedOrphan(in: assetRoot)
        }
        let handler = try DirectResourceHostHandler(
            resourceID: resourceID,
            displayName: "Fixture iPhone",
            platform: makeDevice().platform,
            store: store,
            deviceProfile: makeDevice(),
            accessController: access,
            assetRoot: assetRoot,
            resourceHeartbeatInterval: .milliseconds(5)
        )
        self.modelFixture = modelFixture
        self.store = store
        self.installed = installed
        self.invitations = invitations
        self.access = access
        self.handler = handler
    }

    func remove() { modelFixture.remove() }
}

private func seedOrphan(in assetRoot: URL) throws {
    try FileManager.default.createDirectory(
        at: assetRoot,
        withIntermediateDirectories: true
    )
    try Data("orphan".utf8).write(to: assetRoot.appendingPathComponent("old-receipt"))
}

private final class HostMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) throws -> Data? {
        lock.withLock { values[key] }
    }

    func setData(_ data: Data, forKey key: String) throws {
        lock.withLock { values[key] = data }
    }

    func removeData(forKey key: String) throws {
        lock.withLock { values[key] = nil }
    }
}

private func installedModel(from installation: ModelInstallation) async throws -> InstalledModel {
    for try await event in installation.events {
        if case .installed(let model) = event { return model }
    }
    throw InferPeerError(code: .modelUnavailable, isRetryable: false)
}

func completedRun(
    handler: DirectResourceHostHandler,
    requestID: RequestID,
    principal: String
) async throws -> InferPeer_V2_GetRunResponse {
    for _ in 0..<100 {
        let response = try await withPrincipal(principal) {
            try await handler.getRun(
                InferPeer_V2_GetRunRequest.with { $0.requestID = requestID.rawValue }
            )
        }
        if response.state == .completed { return response }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw InferPeerError(code: .deadlineExceeded, isRetryable: false)
}

func terminalRun(
    handler: DirectResourceHostHandler,
    requestID: RequestID,
    principal: String
) async throws -> InferPeer_V2_GetRunResponse {
    for _ in 0..<100 {
        let response = try await withPrincipal(principal) {
            try await handler.getRun(
                InferPeer_V2_GetRunRequest.with { $0.requestID = requestID.rawValue }
            )
        }
        switch response.state {
        case .completed, .failed, .cancelled, .expired, .interrupted:
            return response
        default:
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    throw InferPeerError(code: .deadlineExceeded, isRetryable: false)
}

func textRunRequest(
    model: ModelKey,
    requestID: String,
    timeoutMilliseconds: UInt64 = 5_000
) throws -> InferPeer_V2_StartRunRequest {
    let requestID = try #require(RequestID(rawValue: requestID))
    let query = InferenceQuery.text(
        model: .exact(model),
        messages: [.user("Run on this resource")]
    )
    let encoded = try DefaultDirectResourceWireCodec().encode(
        query,
        options: RunOptions(requestID: requestID)
    )
    return InferPeer_V2_StartRunRequest.with {
        $0.requestID = requestID.rawValue
        $0.specificationBytes = encoded.bytes
        $0.attachmentReceipts = encoded.attachmentReceipts
        $0.remainingTimeoutMilliseconds = timeoutMilliseconds
    }
}

func helloRequest() -> InferPeer_V2_HelloRequest {
    InferPeer_V2_HelloRequest.with {
        $0.protocolMajor = 2
        $0.minimumMinor = 0
        $0.maximumMinor = 0
    }
}

extension RunEvent {
    var isTestTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .expired, .interrupted: true
        default: false
        }
    }
}

struct EmptyRuntimeAdapter: InferPeerRuntimeAdapter {
    let runtimeID = RuntimeID(rawValue: "llama.cpp")
    let runtimeVersion = "1.0.0"

    func support(
        for _: ModelManifest,
        on _: ModelStoreDeviceProfile
    ) async -> ModelSupport {
        await Task.yield()
        return .supported
    }

    func load(
        model: InstalledModel,
        configuration _: ModelLoadConfiguration
    ) async throws -> any InferPeerModelSession {
        await Task.yield()
        return EmptyModelSession(modelKey: model.key)
    }
}

private struct EmptyModelSession: InferPeerModelSession {
    let modelKey: ModelKey
    let capabilities: Set<InferenceTask> = [.textGeneration]

    func run(_: InferenceQuery) -> DirectRuntimeEventStream {
        AsyncThrowingStream { $0.finish() }
    }

    func unload() async { await Task.yield() }
}

struct HangingRuntimeAdapter: InferPeerRuntimeAdapter {
    let runtimeID = RuntimeID(rawValue: "llama.cpp")
    let runtimeVersion = "1.0.0"

    func support(
        for _: ModelManifest,
        on _: ModelStoreDeviceProfile
    ) async -> ModelSupport {
        await Task.yield()
        return .supported
    }

    func load(
        model: InstalledModel,
        configuration _: ModelLoadConfiguration
    ) async throws -> any InferPeerModelSession {
        await Task.yield()
        return HangingModelSession(modelKey: model.key)
    }
}

private struct HangingModelSession: InferPeerModelSession {
    let modelKey: ModelKey
    let capabilities: Set<InferenceTask> = [.textGeneration]

    func run(_: InferenceQuery) -> DirectRuntimeEventStream {
        AsyncThrowingStream { _ in }
    }

    func unload() async { await Task.yield() }
}

func withPrincipal<Value: Sendable>(
    _ principal: String,
    operation: () async throws -> Value
) async rethrows -> Value {
    try await DirectResourceRequestContext.$principalID.withValue(principal) {
        try await operation()
    }
}
