import Foundation
import InferPeerProtocol

/// Durable direct-resource request state. Payloads are intentionally not represented here.
public enum DirectRequestState: String, Hashable, Sendable {
    case accepted
    case queued
    case preparing
    case running
    case cancelRequested
    case completed
    case failed
    case cancelled
    case expired
    case interrupted
}

/// Metadata required to admit and deduplicate one direct-resource request.
public struct DirectRequestAdmission: Hashable, Sendable {
    /// Authenticated app identity owning the request.
    public let principalID: String
    /// Stable caller-supplied logical request identity.
    public let requestID: RequestID
    /// Exact endpoint admitting the request.
    public let resourceID: String
    /// SHA-256 digest of the immutable encoded specification.
    public let specificationDigest: Data
    /// Exact model identifier.
    public let modelID: String
    /// Exact model revision.
    public let modelRevision: String
    /// Resource process that accepted the request.
    public let processIncarnation: String
    /// Original timeout budget, which retries never extend.
    public let originalTimeoutMilliseconds: UInt64

    /// Creates validated payload-free admission metadata.
    public init(
        principalID: String,
        requestID: RequestID,
        resourceID: String,
        specificationDigest: Data,
        modelID: String,
        modelRevision: String,
        processIncarnation: String,
        originalTimeoutMilliseconds: UInt64
    ) throws {
        guard
            !principalID.isEmpty,
            !resourceID.isEmpty,
            specificationDigest.count == 32,
            !modelID.isEmpty,
            !modelRevision.isEmpty,
            !processIncarnation.isEmpty,
            originalTimeoutMilliseconds > 0
        else {
            throw DirectRequestStoreError.invalidAdmission
        }
        self.principalID = principalID
        self.requestID = requestID
        self.resourceID = resourceID
        self.specificationDigest = specificationDigest
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.processIncarnation = processIncarnation
        self.originalTimeoutMilliseconds = originalTimeoutMilliseconds
    }
}

/// Restored request metadata without raw prompt, media, or generated output.
public struct StoredDirectRequest: Hashable, Sendable {
    /// Immutable admission metadata.
    public let admission: DirectRequestAdmission
    /// Latest durably committed lifecycle state.
    public let state: DirectRequestState
    /// Diagnostic wall-clock acceptance time.
    public let acceptedAt: Date
    /// Diagnostic wall-clock latest transition time.
    public let updatedAt: Date

    /// Authenticated owner identity.
    public var principalID: String { admission.principalID }
    /// Stable logical request identity.
    public var requestID: RequestID { admission.requestID }
    /// Digest used for lost-ack deduplication.
    public var specificationDigest: Data { admission.specificationDigest }
    /// Process incarnation that originally accepted the request.
    public var processIncarnation: String { admission.processIncarnation }
}

/// Idempotent direct-request admission result.
public enum DirectRequestAcceptance: Sendable {
    case accepted(StoredDirectRequest)
    case duplicate(StoredDirectRequest)
}

/// Safe direct-request persistence failures.
public enum DirectRequestStoreError: Error, Equatable, Sendable {
    case invalidAdmission
    case accessDenied
    case requestConflict
    case invalidTransition
    case corruptData
    case resourceExhausted
    case databaseFailure
}
