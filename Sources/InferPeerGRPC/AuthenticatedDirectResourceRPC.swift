import Foundation
import GRPCCore
import InferPeerCore
import InferPeerInference
import InferPeerProtocol

/// One pinned v2 RPC channel, optionally authorized with a paired credential.
public protocol AuthenticatedDirectResourceRPC: Sendable {
    func pair(_ request: InferPeer_V2_PairRequest) async throws -> InferPeer_V2_PairResponse
    func hello(_ request: InferPeer_V2_HelloRequest) async throws -> InferPeer_V2_HelloResponse
    func resourceSnapshot(knownRevision: UInt64) async throws -> ResourceSnapshot?
    func prepareAssets(
        _ request: InferPeer_V2_PrepareAssetsRequest
    ) async throws -> InferPeer_V2_PrepareAssetsResponse
    func uploadAsset(
        requestProducer:
            @Sendable @escaping (
                RPCWriter<InferPeer_V2_UploadAssetRequest>
            ) async throws -> Void
    ) async throws -> InferPeer_V2_UploadAssetResponse
    func prepareModel(
        _ request: InferPeer_V2_PrepareModelRequest,
        onUpdate: @escaping @Sendable (InferPeer_V2_PrepareModelResponse) async throws -> Void
    ) async throws
    func startRun(
        _ request: InferPeer_V2_StartRunRequest
    ) async throws -> InferPeer_V2_StartRunResponse
    func getRun(_ request: InferPeer_V2_GetRunRequest) async throws -> InferPeer_V2_GetRunResponse
    func watchRun(
        requestID: RequestID,
        resumeAfterSequence: UInt64,
        onEvent: @escaping @Sendable (InferPeer_V2_RunEvent) async throws -> UInt64
    ) async throws
    func cancelRun(
        _ request: InferPeer_V2_CancelRunRequest
    ) async throws -> InferPeer_V2_CancelRunResponse
    func releaseAsset(
        _ request: InferPeer_V2_ReleaseAssetRequest
    ) async throws -> InferPeer_V2_ReleaseAssetResponse
    func close() async
}

public extension AuthenticatedDirectResourceRPC {
    // Defaults preserve source compatibility for clients that do not upload assets.
    // swiftlint:disable async_without_await
    func prepareAssets(
        _: InferPeer_V2_PrepareAssetsRequest
    ) async throws -> InferPeer_V2_PrepareAssetsResponse {
        throw InferPeerError(code: .unsupportedTask, isRetryable: false)
    }

    func uploadAsset(
        requestProducer _:
            @Sendable @escaping (
                RPCWriter<InferPeer_V2_UploadAssetRequest>
            ) async throws -> Void
    ) async throws -> InferPeer_V2_UploadAssetResponse {
        throw InferPeerError(code: .unsupportedTask, isRetryable: false)
    }

    func releaseAsset(
        _: InferPeer_V2_ReleaseAssetRequest
    ) async throws -> InferPeer_V2_ReleaseAssetResponse {
        throw InferPeerError(code: .unsupportedTask, isRetryable: false)
    }

    func resourceSnapshot(knownRevision _: UInt64) async throws -> ResourceSnapshot? {
        nil
    }
    // swiftlint:enable async_without_await
}

/// Opens TLS channels pinned to the exact endpoint selected during pairing.
public protocol AuthenticatedDirectResourceRPCFactory: Sendable {
    /// Opens one channel. A non-`nil` credential must be attached to every RPC.
    func open(
        endpoint: PeerEndpoint,
        certificateFingerprint: CertificateFingerprint,
        credential: Data?
    ) async throws -> any AuthenticatedDirectResourceRPC
}

/// Immutable encoded request bytes and owner-bound attachment receipts.
public struct EncodedDirectRunSpecification: Sendable {
    /// Exact bytes reused for every lost-ack retry.
    public let bytes: Data
    /// Resource-issued receipts referenced by the immutable request.
    public let attachmentReceipts: [String]

    /// Creates one frozen transport specification.
    public init(bytes: Data, attachmentReceipts: [String] = []) {
        self.bytes = bytes
        self.attachmentReceipts = attachmentReceipts
    }
}

/// Owns deterministic request encoding and bounded event-payload decoding.
public protocol DirectRunWireCoding: Sendable {
    func encode(_ query: InferenceQuery, options: RunOptions) throws
        -> EncodedDirectRunSpecification
    func decode(_ event: InferPeer_V2_RunEvent) throws -> RunEvent
}

/// Decoded immutable run inputs used by a direct-resource host.
public struct DecodedDirectRunSpecification: Sendable {
    /// Validated query that the selected host must execute.
    public let query: InferenceQuery
    /// Validated delivery and admission options for the run.
    public let options: RunOptions

    /// Creates decoded host inputs from a validated query and options.
    public init(query: InferenceQuery, options: RunOptions) {
        self.query = query
        self.options = options
    }
}

/// Bidirectional production wire contract shared by clients and resource hosts.
public protocol DirectResourceWireCoding: DirectRunWireCoding {
    func decode(
        _ specification: EncodedDirectRunSpecification
    ) throws -> DecodedDirectRunSpecification
    func encode(
        _ event: RunEvent,
        requestID: RequestID,
        incarnation: String,
        sequence: UInt64
    ) throws -> InferPeer_V2_RunEvent
}

/// Bounded reconnect attempts used for ambiguous acceptance and initial connection.
public struct DirectSessionReconnectPolicy: Hashable, Sendable {
    /// Default is three attempts against the same paired endpoint.
    public static let standard = Self(maximumAttempts: 3)

    /// Total connection attempts including the first.
    public let maximumAttempts: Int

    /// Creates an attempt bound. Values below one are normalized to one.
    public init(maximumAttempts: Int) {
        self.maximumAttempts = max(1, maximumAttempts)
    }
}

/// Supplies bounded jitter/backoff between same-endpoint reconnect attempts.
public protocol DirectReconnectDelayProviding: Sendable {
    func delay(beforeAttempt attempt: Int) -> Duration
}

/// Fixed delay provider useful for deterministic policies and tests.
public struct FixedDirectReconnectDelayProvider: DirectReconnectDelayProviding, Sendable {
    /// Delay returned before every retry.
    public let delay: Duration

    /// Creates a fixed bounded delay provider.
    public init(delay: Duration) {
        self.delay = delay
    }

    /// Returns the configured delay.
    public func delay(beforeAttempt _: Int) -> Duration { delay }
}

/// Suspends reconnect work without coupling the manager to wall-clock sleeps in tests.
public protocol DirectSessionSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

/// Production monotonic task sleeper.
public struct SystemDirectSessionSleeper: DirectSessionSleeping, Sendable {
    /// Creates a system task sleeper.
    public init() {}

    /// Suspends the current task for the requested duration.
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Generated-client adapter that keeps WatchRun acknowledgements on its bidirectional stream.
public struct GRPCDirectResourceRPCConnection<
    Client: InferPeer_V2_DirectResourceService.ClientProtocol
>: AuthenticatedDirectResourceRPC, Sendable {
    private let client: DirectResourceGRPCClient<Client>
    private let closeOperation: @Sendable () async -> Void

    /// Wraps an authenticated generated client and its channel shutdown operation.
    public init(
        client: DirectResourceGRPCClient<Client>,
        close: @escaping @Sendable () async -> Void = {}
    ) {
        self.client = client
        closeOperation = close
    }

    /// Exchanges a one-time invitation for an authenticated resource credential.
    public func pair(_ request: InferPeer_V2_PairRequest) async throws
        -> InferPeer_V2_PairResponse
    {
        try await client.pair(request)
    }

    /// Negotiates v2 capabilities and returns the current resource incarnation.
    public func hello(_ request: InferPeer_V2_HelloRequest) async throws
        -> InferPeer_V2_HelloResponse
    {
        try await client.hello(request)
    }

    /// Reads the first resource update newer than the supplied revision.
    public func resourceSnapshot(knownRevision: UInt64) async throws -> ResourceSnapshot? {
        try await client.watchResource(
            InferPeer_V2_WatchResourceRequest.with { $0.knownRevision = knownRevision }
        ) { response in
            for try await update in response.messages {
                guard case .snapshot(let snapshot)? = update.payload else { continue }
                return try DirectWireMapper.resource(snapshot)
            }
            return nil
        }
    }

    /// Requests owner-scoped upload tickets for declared input assets.
    public func prepareAssets(
        _ request: InferPeer_V2_PrepareAssetsRequest
    ) async throws -> InferPeer_V2_PrepareAssetsResponse {
        try await client.prepareAssets(request)
    }

    /// Streams one declared asset and returns its owner-scoped receipt.
    public func uploadAsset(
        requestProducer:
            @Sendable @escaping (
                RPCWriter<InferPeer_V2_UploadAssetRequest>
            ) async throws -> Void
    ) async throws -> InferPeer_V2_UploadAssetResponse {
        try await client.uploadAsset(requestProducer: requestProducer)
    }

    /// Streams model preparation updates to the supplied observer.
    public func prepareModel(
        _ request: InferPeer_V2_PrepareModelRequest,
        onUpdate: @escaping @Sendable (InferPeer_V2_PrepareModelResponse) async throws -> Void
    ) async throws {
        try await client.prepareModel(request) { response in
            for try await update in response.messages {
                try await onUpdate(update)
            }
        }
    }

    /// Submits one immutable run request.
    public func startRun(_ request: InferPeer_V2_StartRunRequest) async throws
        -> InferPeer_V2_StartRunResponse
    {
        try await client.startRun(request)
    }

    /// Reconciles the current state and retained replay range of one run.
    public func getRun(_ request: InferPeer_V2_GetRunRequest) async throws
        -> InferPeer_V2_GetRunResponse
    {
        try await client.getRun(request)
    }

    /// Watches a run from a cursor and acknowledges each locally accepted event.
    public func watchRun(
        requestID: RequestID,
        resumeAfterSequence: UInt64,
        onEvent: @escaping @Sendable (InferPeer_V2_RunEvent) async throws -> UInt64
    ) async throws {
        let pipe = BoundedMessagePipe<InferPeer_V2_WatchRunRequest>(capacity: 2)
        try await pipe.send(Self.resumeRequest(requestID, after: resumeAfterSequence))
        defer { pipe.finish() }
        try await client.watchRun(
            requestProducer: { writer in
                for try await request in pipe.internalStream() {
                    try await writer.write(request)
                }
            },
            onResponse: { response in
                for try await message in response.messages {
                    guard message.hasEvent else { throw InferPeerGRPCError.invalidMessage }
                    let acknowledged = try await onEvent(message.event)
                    try await pipe.send(Self.acknowledgementRequest(requestID, acknowledged))
                }
            }
        )
    }

    /// Requests cancellation of one run.
    public func cancelRun(_ request: InferPeer_V2_CancelRunRequest) async throws
        -> InferPeer_V2_CancelRunResponse
    {
        try await client.cancelRun(request)
    }

    /// Releases one owner-scoped remote asset receipt.
    public func releaseAsset(
        _ request: InferPeer_V2_ReleaseAssetRequest
    ) async throws -> InferPeer_V2_ReleaseAssetResponse {
        try await client.releaseAsset(request)
    }

    /// Closes the underlying channel through its injected shutdown operation.
    public func close() async {
        await closeOperation()
    }

    private static func resumeRequest(
        _ requestID: RequestID,
        after sequence: UInt64
    ) -> InferPeer_V2_WatchRunRequest {
        InferPeer_V2_WatchRunRequest.with {
            $0.requestID = requestID.rawValue
            $0.resumeAfterSequence = sequence
        }
    }

    private static func acknowledgementRequest(
        _ requestID: RequestID,
        _ sequence: UInt64
    ) -> InferPeer_V2_WatchRunRequest {
        InferPeer_V2_WatchRunRequest.with {
            $0.requestID = requestID.rawValue
            $0.acknowledgeSequence = sequence
        }
    }
}
