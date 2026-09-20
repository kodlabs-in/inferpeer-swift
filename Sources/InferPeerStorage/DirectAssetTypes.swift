import Crypto
import Foundation
import InferPeerInference

/// Metadata declared before a bounded direct asset upload begins.
public struct DirectAssetUploadDescriptor: Hashable, Sendable {
    /// Initial authenticated input-asset quota.
    public static let maximumByteCount: UInt64 = 256 * 1_024 * 1_024

    /// Authenticated app identity owning this asset.
    public let ownerID: String
    /// Exact declared content length.
    public let byteCount: UInt64
    /// Expected SHA-256 content digest.
    public let sha256: Data
    /// Declared media type validated by the consuming adapter.
    public let mediaType: String
    /// Independent upload/retention expiry.
    public let expiresAt: Date

    /// Creates validated upload metadata without allocating its declared content.
    public init(
        ownerID: String,
        byteCount: UInt64,
        sha256: Data,
        mediaType: String,
        expiresAt: Date
    ) throws {
        guard !ownerID.isEmpty,
            (1...Self.maximumByteCount).contains(byteCount),
            sha256.count == SHA256.byteCount,
            !mediaType.isEmpty
        else {
            throw DirectAssetStoreError.invalidDescriptor
        }
        self.ownerID = ownerID
        self.byteCount = byteCount
        self.sha256 = sha256
        self.mediaType = mediaType
        self.expiresAt = expiresAt
    }
}

/// Opaque authorization-bound ticket for one incomplete upload.
public struct DirectAssetUploadTicket: RawRepresentable, Hashable, Sendable {
    /// Opaque random ticket value.
    public let rawValue: String

    /// Restores an opaque ticket value.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Durable upload progress confirmed by the receiving resource.
public struct DirectAssetUploadStatus: Hashable, Sendable {
    /// Resource-confirmed contiguous offset safe to resume from.
    public let durableOffset: UInt64
    /// Exact declared final byte count.
    public let expectedByteCount: UInt64
    /// Published owner-bound receipt after verification, if complete.
    public let receipt: InferenceAssetReceipt?
}

/// Fail-closed direct asset persistence errors.
public enum DirectAssetStoreError: Error, Equatable, Sendable {
    case invalidDescriptor
    case ticketNotFound
    case accessDenied
    case assetExpired
    case uploadOffsetMismatch
    case chunkTooLarge
    case assetInvalid
    case readOutOfBounds
    case storageFailure
}
