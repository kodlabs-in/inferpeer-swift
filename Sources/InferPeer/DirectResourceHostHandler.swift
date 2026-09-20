import Foundation
import InferPeerCore
import InferPeerGRPC
import InferPeerInference
import InferPeerModelStore
import InferPeerProtocol
import InferPeerSecurity

/// Foreground-only v2 resource host backed by the package model store.
public actor DirectResourceHostHandler: DirectResourceServiceHandling {
    struct HostedExecution {
        let query: InferenceQuery
        let model: InstalledModel
        let options: RunOptions
    }

    struct RunKey: Hashable, Sendable {
        let principalID: String
        let requestID: RequestID
    }

    struct AssetTicket: Sendable {
        let principalID: String
        let clientID: String
        let expectedBytes: UInt64
        let expectedDigest: Data
        let mediaType: String
        let expiresAt: Date
        var data: Data
    }

    struct AssetReceipt: Sendable {
        let principalID: String
        let url: URL
        let byteCount: UInt64
        let digest: Data
    }

    struct HostedRun {
        let specification: Data
        let attachmentReceipts: [String]
        let originalTimeoutMilliseconds: UInt64
        let model: InstalledModel
        var status: RunStatus
        var events: [InferPeer_V2_RunEvent]
        var terminalEvent: InferPeer_V2_RunEvent?
        var watchers: [UUID: DirectRPCStream<InferPeer_V2_WatchRunResponse>.Continuation]
        var task: Task<Void, Never>?
        var completedAt: Date?
    }

    struct PendingRunAdmission {
        let id: UUID
        let specification: Data
        let attachmentReceipts: [String]
        let originalTimeoutMilliseconds: UInt64
        let task: Task<InferPeer_V2_StartRunResponse, any Error>
    }

    struct ResourceWatcher {
        let principalID: String
        let continuation: DirectRPCStream<InferPeer_V2_WatchResourceResponse>.Continuation
        let task: Task<Void, Never>
    }

    static let supportedTasks: Set<InferenceTask> = [.textGeneration, .imageUnderstanding]
    static let maximumAssetBytes: UInt64 = 32 * 1_024 * 1_024
    static let maximumPrincipalAssetBytes: UInt64 = 128 * 1_024 * 1_024
    static let maximumHostAssetBytes: UInt64 = 256 * 1_024 * 1_024
    static let maximumPrincipalAssetObjects = 32
    static let maximumHostAssetObjects = 128
    static let maximumReplayEvents = 256
    static let maximumWatchersPerRun = 8
    static let maximumConcurrentRuns = 8
    static let maximumRetainedRuns = 256
    static let maximumRunTimeoutMilliseconds: UInt64 = 15 * 60 * 1_000
    static let runRetentionInterval: TimeInterval = 10 * 60
    static let maximumResourceWatchersPerPrincipal = 4
    static let maximumResourceWatchers = 32
    let resourceID: ResourceID
    let displayName: String
    let platform: PlatformDescriptor
    let telemetry: TelemetrySnapshot
    let store: InferPeerModelStore
    let deviceProfile: ModelStoreDeviceProfile
    let accessController: DirectResourceAccessController
    let wireCodec: any DirectResourceWireCoding
    let assetRoot: URL
    var incarnation: String
    let resourceHeartbeatInterval: Duration
    var resourceRevision: UInt64 = 1
    var advertisedModels: [ModelSummary]?
    var tickets: [String: AssetTicket] = [:]
    var receipts: [String: AssetReceipt] = [:]
    var runs: [RunKey: HostedRun] = [:]
    var pendingRunAdmissions: [RunKey: PendingRunAdmission] = [:]
    var resourceWatchers: [UUID: ResourceWatcher] = [:]

    /// Creates a stopped foreground host. The transport owns listener lifecycle.
    public init(
        resourceID: ResourceID,
        displayName: String,
        platform: PlatformDescriptor,
        telemetry: TelemetrySnapshot = .init(),
        store: InferPeerModelStore,
        deviceProfile: ModelStoreDeviceProfile,
        accessController: DirectResourceAccessController,
        assetRoot: URL,
        wireCodec: any DirectResourceWireCoding = DefaultDirectResourceWireCodec(),
        resourceHeartbeatInterval: Duration = .seconds(5)
    ) throws {
        guard resourceID != .local,
            !resourceID.rawValue.isEmpty,
            !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            assetRoot.isFileURL
        else {
            throw InferPeerError(code: .invalidRequest, isRetryable: false)
        }
        let assetRoot = assetRoot.standardizedFileURL
        try resetDirectResourceAssetRoot(assetRoot)
        self.resourceID = resourceID
        self.displayName = displayName
        self.platform = platform
        self.telemetry = telemetry
        self.store = store
        self.deviceProfile = deviceProfile
        self.accessController = accessController
        self.assetRoot = assetRoot
        self.wireCodec = wireCodec
        self.resourceHeartbeatInterval = resourceHeartbeatInterval
        incarnation = UUID().uuidString.lowercased()
    }

    // Cancels active work and clears ephemeral state when sharing is withdrawn.
    // swiftlint:disable:next async_without_await
    public func suspend() async {
        let interruption = InferPeerError(code: .interrupted, isRetryable: true)
        for key in runs.keys {
            runs[key]?.task?.cancel()
            if runs[key]?.status.isHostTerminal == false {
                try? append(.interrupted(interruption), to: key)
            }
        }
        for receipt in receipts.values {
            try? FileManager.default.removeItem(at: receipt.url)
        }
        pendingRunAdmissions.values.forEach { $0.task.cancel() }
        resourceWatchers.values.forEach {
            $0.task.cancel()
            $0.continuation.finish()
        }
        pendingRunAdmissions.removeAll(keepingCapacity: false)
        resourceWatchers.removeAll(keepingCapacity: false)
        tickets.removeAll(keepingCapacity: false)
        receipts.removeAll(keepingCapacity: false)
        runs.removeAll(keepingCapacity: false)
        incarnation = UUID().uuidString.lowercased()
    }

    /// Exchanges one valid invitation proof for an owner-scoped credential.
    public func pair(
        _ request: InferPeer_V2_PairRequest
    ) async throws -> InferPeer_V2_PairResponse {
        guard request.protocolMajor == UInt32(ResourcePairingInvitation.supportedProtocolMajor),
            request.expectedResourceID == resourceID.rawValue,
            let invitationID = InvitationID(rawValue: request.invitationID)
        else {
            throw InferPeerError(code: .protocolMismatch, isRetryable: false)
        }
        let grant = try await accessController.exchange(
            invitationID: invitationID,
            secret: request.invitationSecret,
            expectedResourceID: resourceID
        )
        let snapshot = try await currentSnapshot()
        return InferPeer_V2_PairResponse.with {
            $0.resourceID = resourceID.rawValue
            $0.credential = grant.credential
            $0.snapshot = DirectWireMapper.wireResource(snapshot)
        }
    }

    /// Negotiates protocol support and reports this host's current incarnation.
    public func hello(
        _ request: InferPeer_V2_HelloRequest
    ) async throws -> InferPeer_V2_HelloResponse {
        _ = try requirePrincipal()
        guard request.protocolMajor == 2,
            request.minimumMinor <= 0,
            request.maximumMinor >= 0
        else {
            throw InferPeerError(code: .protocolMismatch, isRetryable: false)
        }
        let snapshot = try await currentSnapshot()
        return InferPeer_V2_HelloResponse.with {
            $0.protocolMajor = 2
            $0.protocolMinor = 0
            $0.resourceID = resourceID.rawValue
            $0.incarnation = incarnation
            $0.supportedTasks = snapshot.capabilities.supportedTasks
                .map(DirectWireMapper.wireTask)
            $0.catalogRevision = resourceRevision
            $0.maximumMessageBytes = UInt64(
                DefaultDirectResourceWireCodec.maximumSpecificationBytes
            )
            $0.maximumAssetBytes = Self.maximumAssetBytes
            $0.optionalFeatures = ["asset-upload", "same-process-replay", "watch-run-ack"]
        }
    }

    /// Loads one already-installed exact model and streams preparation progress.
    public func prepareModel(
        _ request: InferPeer_V2_PrepareModelRequest
    ) async throws -> DirectRPCStream<InferPeer_V2_PrepareModelResponse> {
        _ = try requirePrincipal()
        let key = try DirectWireMapper.modelKey(request.model)
        guard try await installedModel(key) != nil else {
            throw InferPeerError(code: .modelNotInstalled, isRetryable: false)
        }
        return DirectRPCStream { continuation in
            let task = Task {
                continuation.yield(Self.preparationUpdate(.preparing, progress: 0))
                do {
                    if try await self.store.status(of: key)?.isLoaded != true {
                        try await self.store.load(key, on: self.deviceProfile)
                    }
                    continuation.yield(Self.preparationUpdate(.ready, progress: 1_000))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.publicError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func installedModel(_ key: ModelKey) async throws -> InstalledModel? {
        try await store.installedModels().first { $0.key == key }
    }

    func requirePrincipal() throws -> String {
        guard let principal = DirectResourceRequestContext.principalID else {
            throw InferPeerError(code: .unauthenticated, isRetryable: false)
        }
        return principal
    }

    static func publicError(_ error: any Error) -> InferPeerError {
        if let error = error as? InferPeerError { return error }
        if error is CancellationError {
            return InferPeerError(code: .cancelled, isRetryable: false)
        }
        if error is InferPeerModelStoreError {
            return InferPeerError(code: .modelLoadFailed, isRetryable: false)
        }
        return InferPeerError(code: .internal, isRetryable: false)
    }

    private static func preparationUpdate(
        _ readiness: ModelReadiness,
        progress: UInt32
    ) -> InferPeer_V2_PrepareModelResponse {
        InferPeer_V2_PrepareModelResponse.with {
            $0.readiness = wireReadiness(readiness)
            $0.progressPerMille = progress
        }
    }

    private static func wireReadiness(
        _ value: ModelReadiness
    ) -> InferPeer_V2_ModelReadiness {
        switch value {
        case .registered: .registered
        case .preparing: .preparing
        case .ready: .ready
        case .unloading: .unloading
        case .failed: .failed
        }
    }
}

private func resetDirectResourceAssetRoot(_ assetRoot: URL) throws {
    let files = FileManager.default
    try files.createDirectory(at: assetRoot, withIntermediateDirectories: true)
    for orphan in try files.contentsOfDirectory(
        at: assetRoot,
        includingPropertiesForKeys: nil
    ) {
        try files.removeItem(at: orphan)
    }
}
