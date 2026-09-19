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

@Suite("Foreground direct resource host")
struct DirectResourceHostHandlerTests {
    @Test("Pairing authorizes hello and advertises only installed text and vision models")
    func pairingAndHello() async throws {
        let fixture = try await DirectHostFixture()
        defer { fixture.remove() }
        let invitation = try await fixture.invitations.issue(
            resourceID: fixture.resourceID,
            endpoint: try PeerEndpoint(host: "192.168.1.40", port: 9_443),
            certificateFingerprint: CertificateFingerprint(bytes: Data(repeating: 3, count: 32))
        )
        let response = try await fixture.handler.pair(
            InferPeer_V2_PairRequest.with {
                $0.protocolMajor = 2
                $0.invitationID = invitation.invitationID?.rawValue ?? ""
                $0.expectedResourceID = fixture.resourceID.rawValue
                $0.invitationSecret = invitation.secret
            }
        )
        let principal = try await fixture.access.authorize(response.credential)

        let hello = try await withPrincipal(principal.rawValue) {
            try await fixture.handler.hello(
                InferPeer_V2_HelloRequest.with {
                    $0.protocolMajor = 2
                    $0.minimumMinor = 0
                    $0.maximumMinor = 0
                }
            )
        }

        #expect(hello.resourceID == fixture.resourceID.rawValue)
        #expect(hello.supportedTasks == [.text])
        #expect(!hello.optionalFeatures.contains("audio"))
    }

    @Test("A text run executes once and replays its terminal outcome")
    func runsAndReplaysText() async throws {
        let fixture = try await DirectHostFixture()
        defer { fixture.remove() }
        let codec = DefaultDirectResourceWireCodec()
        let requestID = try #require(RequestID(rawValue: "host-run-1"))
        let query = InferenceQuery.text(
            model: .exact(fixture.installed.key),
            messages: [.user("Run on this resource")]
        )
        let encoded = try codec.encode(query, options: RunOptions(requestID: requestID))
        let request = InferPeer_V2_StartRunRequest.with {
            $0.requestID = requestID.rawValue
            $0.specificationBytes = encoded.bytes
            $0.attachmentReceipts = encoded.attachmentReceipts
            $0.remainingTimeoutMilliseconds = 5_000
        }

        let first = try await withPrincipal("owner-one") {
            try await fixture.handler.startRun(request)
        }
        let terminal = try await completedRun(
            handler: fixture.handler,
            requestID: requestID,
            principal: "owner-one"
        )
        let replay = try await withPrincipal("owner-one") {
            try await fixture.handler.startRun(request)
        }
        let event = try codec.decode(terminal.terminalEvent)

        #expect(first.requestID == requestID.rawValue)
        #expect(replay.requestID == first.requestID)
        #expect(replay.state == .completed)
        guard case .completed(let result) = event else {
            Issue.record("Expected a completed terminal event")
            return
        }
        #expect(result.text == "offline")
    }

    @Test("Uploaded image receipts are isolated to their paired owner")
    func isolatesUploadedAssets() async throws {
        let fixture = try await DirectHostFixture()
        defer { fixture.remove() }
        let bytes = Data("image-fixture".utf8)
        let receipt = try await uploadAsset(bytes, handler: fixture.handler)

        await #expect(throws: InferPeerError.self) {
            _ = try await withPrincipal("owner-two") {
                try await fixture.handler.releaseAsset(
                    InferPeer_V2_ReleaseAssetRequest.with { $0.receipt = receipt.receipt }
                )
            }
        }
        let released = try await withPrincipal("owner-one") {
            try await fixture.handler.releaseAsset(
                InferPeer_V2_ReleaseAssetRequest.with { $0.receipt = receipt.receipt }
            )
        }
        #expect(released.released)
    }

    @Test("Resource watches stay live and publish bounded heartbeats")
    func resourceWatchHeartbeats() async throws {
        let fixture = try await DirectHostFixture()
        defer { fixture.remove() }
        let stream = try await withPrincipal("owner-one") {
            try await fixture.handler.watchResource(
                InferPeer_V2_WatchResourceRequest.with { $0.knownRevision = 0 }
            )
        }
        var iterator = stream.makeAsyncIterator()
        let snapshot = try #require(try await iterator.next())
        let heartbeat = try #require(try await iterator.next())

        guard case .snapshot? = snapshot.payload else {
            Issue.record("Expected the initial resource snapshot")
            return
        }
        guard case .heartbeatRevision(let revision)? = heartbeat.payload else {
            Issue.record("Expected a resource heartbeat")
            return
        }
        #expect(revision == 1)
    }
}

private func uploadAsset(
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

private struct DirectHostFixture {
    let modelFixture: ModelStoreFixture
    let store: InferPeerModelStore
    let installed: InstalledModel
    let invitations: DirectResourceInvitationAuthority
    let access: DirectResourceAccessController
    let handler: DirectResourceHostHandler
    let resourceID = ResourceID(rawValue: "fixture-resource")

    init() async throws {
        let modelFixture = try ModelStoreFixture()
        let store = try await InferPeerModelStore.open(
            configuration: modelFixture.configuration(
                downloader: MemoryModelDownloader(data: modelFixture.data),
                adapters: [TestRuntimeAdapter()]
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
        let handler = try DirectResourceHostHandler(
            resourceID: resourceID,
            displayName: "Fixture iPhone",
            platform: makeDevice().platform,
            store: store,
            deviceProfile: makeDevice(),
            accessController: access,
            assetRoot: modelFixture.root.appendingPathComponent("assets", isDirectory: true),
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

private func completedRun(
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

private func withPrincipal<Value: Sendable>(
    _ principal: String,
    operation: () async throws -> Value
) async rethrows -> Value {
    try await DirectResourceRequestContext.$principalID.withValue(principal) {
        try await operation()
    }
}
