import Foundation
import InferPeerInference
import InferPeerProtocol

/// Invalid out-of-band data rejected before a direct resource session starts.
public enum ResourcePairingInvitationError: Error, Equatable, Sendable {
    case incompatibleProtocolMajor
    case invalidResourceID
    case invalidSecretLength
}

/// Out-of-band identity and proof for one directly addressable resource.
public struct ResourcePairingInvitation: Hashable, Sendable {
    /// The protocol major supported by this SDK generation.
    public static let supportedProtocolMajor = 2

    /// The required random pairing-secret byte count.
    public static let secretByteCount = 32

    /// Protocol major asserted by the invitation.
    public let protocolMajor: Int

    /// Stable single-use invitation identity sent with its opaque proof.
    public let invitationID: InvitationID?

    /// Stable identity of the remote resource.
    public let resourceID: ResourceID

    /// LAN endpoint used only to establish the pinned session.
    public let endpoint: PeerEndpoint

    /// Expected SHA-256 certificate fingerprint.
    public let certificateFingerprint: CertificateFingerprint

    /// Opaque single-use pairing proof.
    public let secret: Data

    /// Wall-clock expiry supplied by the invitation issuer.
    public let expiresAt: Date

    /// Creates a structurally valid v2 direct-resource invitation.
    public init(
        protocolMajor: Int,
        invitationID: InvitationID? = nil,
        resourceID: ResourceID,
        endpoint: PeerEndpoint,
        certificateFingerprint: CertificateFingerprint,
        secret: Data,
        expiresAt: Date
    ) throws {
        guard protocolMajor == Self.supportedProtocolMajor else {
            throw ResourcePairingInvitationError.incompatibleProtocolMajor
        }
        guard resourceID != .local,
            !resourceID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ResourcePairingInvitationError.invalidResourceID
        }
        guard secret.count == Self.secretByteCount else {
            throw ResourcePairingInvitationError.invalidSecretLength
        }
        self.protocolMajor = protocolMajor
        self.invitationID = invitationID
        self.resourceID = resourceID
        self.endpoint = endpoint
        self.certificateFingerprint = certificateFingerprint
        self.secret = secret
        self.expiresAt = expiresAt
    }
}

/// Transport and trust boundary used by the direct-resource facade.
public protocol ResourceSessionManaging: Sendable {
    /// Consumes one invitation and returns the authenticated resource's first snapshot.
    func pair(_ invitation: ResourcePairingInvitation) async throws -> ResourceSnapshot

    /// Reconnects remembered pairings and returns their authenticated current snapshots.
    func reconnectPairedResources() async -> [ResourceSnapshot]

    /// Closes one active session while retaining its paired identity.
    func disconnect(_ resourceID: ResourceID) async

    /// Revokes and removes one paired identity.
    func forget(_ resourceID: ResourceID) async throws

    /// Prepares one exact model on one exact remote resource.
    func prepareModel(_ model: ModelKey, on resourceID: ResourceID) async throws

    /// Starts or joins one immutable run on one exact authenticated resource.
    func run(
        _ query: InferenceQuery,
        resourceID: ResourceID,
        options: RunOptions
    ) async throws -> RemoteRunExecution

    /// Stops all active sessions owned by this manager.
    func stop() async
}

public extension ResourceSessionManaging {
    // Async is required by the session protocol; the compatibility default has no I/O.
    // swiftlint:disable async_without_await
    /// Preserves source compatibility for custom session managers without persistence.
    func reconnectPairedResources() async -> [ResourceSnapshot] { [] }
    // swiftlint:enable async_without_await
}

/// Transport-owned remote execution exposed without leaking RPC implementation types.
public struct RemoteRunExecution: Sendable {
    /// Stable logical request identity accepted by the remote endpoint.
    public let requestID: RequestID
    /// Exact remote endpoint executing this request.
    public let resourceID: ResourceID
    /// Ordered bounded remote event stream.
    public let events: RunEventStream

    private let resultOperation: @Sendable () async throws -> RunResult
    private let cancelOperation: @Sendable () async -> Void
    private let statusOperation: @Sendable () async -> RunStatus

    /// Creates an adapter-neutral remote execution handle.
    public init(
        requestID: RequestID,
        resourceID: ResourceID,
        events: RunEventStream,
        result: @escaping @Sendable () async throws -> RunResult,
        cancel: @escaping @Sendable () async -> Void,
        status: @escaping @Sendable () async -> RunStatus
    ) {
        self.requestID = requestID
        self.resourceID = resourceID
        self.events = events
        resultOperation = result
        cancelOperation = cancel
        statusOperation = status
    }

    /// Awaits terminal success independently from event iteration.
    public func result() async throws -> RunResult {
        try await resultOperation()
    }

    /// Sends an idempotent cancellation request to the selected endpoint.
    public func cancel() async {
        await cancelOperation()
    }

    /// Returns the latest reconciled remote status.
    public func status() async -> RunStatus {
        await statusOperation()
    }
}
