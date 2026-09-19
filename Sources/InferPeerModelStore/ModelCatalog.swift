import Foundation
import InferPeerInference
import InferPeerProtocol

/// Release-gate state for one immutable catalog version.
public enum ModelCatalogStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case stable
    case beta
    case experimental
    case blocked
}

/// Stable model identity paired with a semantic catalog version.
public struct ModelCatalogKey: Codable, Hashable, Sendable {
    /// Stable logical model identifier.
    public let modelID: ModelID
    /// Immutable semantic catalog version.
    public let version: String

    /// Creates an exact catalog identity.
    public init(modelID: ModelID, version: String) {
        self.modelID = modelID
        self.version = version
    }
}

/// User-facing identity and release status for a catalog entry.
public struct ModelCatalogMetadata: Codable, Hashable, Sendable {
    /// Exact catalog identity.
    public let key: ModelCatalogKey
    /// Name suitable for display before installation.
    public let displayName: String
    /// Artifact publisher.
    public let publisher: String
    /// Current release-gate status.
    public let status: ModelCatalogStatus
    /// Preferred device tier, never a compatibility lock.
    public let recommendedTier: ModelDeviceTier

    /// Creates catalog metadata.
    public init(
        key: ModelCatalogKey,
        displayName: String,
        publisher: String,
        status: ModelCatalogStatus,
        recommendedTier: ModelDeviceTier
    ) {
        self.key = key
        self.displayName = displayName
        self.publisher = publisher
        self.status = status
        self.recommendedTier = recommendedTier
    }
}

/// License information displayed and accepted before installation.
public struct ModelLicense: Codable, Hashable, Sendable {
    /// SPDX identifier or publisher license expression.
    public let identifier: String
    /// Auditable license document.
    public let url: URL
    /// Whether explicit acceptance is required.
    public let acceptanceRequired: Bool

    /// Creates license metadata.
    public init(identifier: String, url: URL, acceptanceRequired: Bool) {
        self.identifier = identifier
        self.url = url
        self.acceptanceRequired = acceptanceRequired
    }
}

/// One immutable HTTPS file source matching a manifest declaration.
public struct ModelDownloadFile: Codable, Hashable, Sendable {
    /// Safe relative path within the model package.
    public let relativePath: String
    /// Immutable HTTPS source URL.
    public let url: URL
    /// Exact expected byte count.
    public let byteCount: UInt64
    /// Exact expected SHA-256 digest.
    public let sha256: ModelContentDigest

    /// Creates an HTTPS-only download declaration.
    public init(
        relativePath: String,
        url: URL,
        byteCount: UInt64,
        sha256: ModelContentDigest
    ) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw ModelCatalogError.insecureDownloadURL
        }
        self.relativePath = relativePath
        self.url = url
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// Apple operating-system family supported by a catalog entry.
public enum CatalogOperatingSystem: String, Codable, CaseIterable, Hashable, Sendable {
    case iOS
    case iPadOS
    case macOS
}

/// Minimum version for one supported operating-system family.
public struct MinimumOperatingSystem: Codable, Hashable, Sendable {
    /// Supported operating-system family.
    public let operatingSystem: CatalogOperatingSystem
    /// Minimum dotted numeric version.
    public let version: String

    /// Creates one platform requirement.
    public init(operatingSystem: CatalogOperatingSystem, version: String) {
        self.operatingSystem = operatingSystem
        self.version = version
    }
}

/// Memory and storage requirements evaluated from actual resource measurements.
public struct ModelResourceRequirements: Codable, Hashable, Sendable {
    /// Required installed memory, when constrained.
    public let minimumPhysicalMemoryBytes: UInt64?
    /// Required currently available memory, when constrained.
    public let minimumAvailableMemoryBytes: UInt64?
    /// Required free storage including staging headroom.
    public let minimumFreeStorageBytes: UInt64

    /// Creates resource requirements.
    public init(
        minimumPhysicalMemoryBytes: UInt64? = nil,
        minimumAvailableMemoryBytes: UInt64? = nil,
        minimumFreeStorageBytes: UInt64
    ) {
        self.minimumPhysicalMemoryBytes = minimumPhysicalMemoryBytes
        self.minimumAvailableMemoryBytes = minimumAvailableMemoryBytes
        self.minimumFreeStorageBytes = minimumFreeStorageBytes
    }
}

/// Complete OS, hardware, and resource requirements.
public struct ModelRequirements: Codable, Hashable, Sendable {
    /// Supported operating-system families and minimum versions.
    public let minimumOperatingSystems: [MinimumOperatingSystem]
    /// Optional hardware identifier prefixes.
    public let supportedDeviceFamilies: [String]
    /// Required host-reported chip capabilities.
    public let requiredChipFeatures: [String]
    /// Memory and storage thresholds.
    public let resources: ModelResourceRequirements

    /// Creates compatibility requirements.
    public init(
        minimumOperatingSystems: [MinimumOperatingSystem],
        supportedDeviceFamilies: [String] = [],
        requiredChipFeatures: [String] = [],
        resources: ModelResourceRequirements
    ) {
        self.minimumOperatingSystems = minimumOperatingSystems
        self.supportedDeviceFamilies = supportedDeviceFamilies
        self.requiredChipFeatures = requiredChipFeatures
        self.resources = resources
    }
}

/// Reproducible record of one successful physical-device validation.
public struct ModelValidationRecord: Codable, Hashable, Sendable {
    /// Exact tested hardware identifier.
    public let hardwareIdentifier: String
    /// Tested operating-system version.
    public let operatingSystemVersion: String
    /// Tested adapter version.
    public let adapterVersion: String
    /// Completion time of the passing run.
    public let passedAt: Date

    /// Creates a validation record.
    public init(
        hardwareIdentifier: String,
        operatingSystemVersion: String,
        adapterVersion: String,
        passedAt: Date
    ) {
        self.hardwareIdentifier = hardwareIdentifier
        self.operatingSystemVersion = operatingSystemVersion
        self.adapterVersion = adapterVersion
        self.passedAt = passedAt
    }
}

/// Exact installable model version and all metadata shown before download.
public struct ModelCatalogEntry: Codable, Hashable, Sendable {
    /// User-facing identity and release status.
    public let metadata: ModelCatalogMetadata
    /// Canonical artifact manifest.
    public let manifest: ModelManifest
    /// HTTPS sources corresponding exactly to manifest files.
    public let downloadFiles: [ModelDownloadFile]
    /// License and acceptance requirements.
    public let license: ModelLicense
    /// Device and resource requirements.
    public let requirements: ModelRequirements
    /// Passing physical-device validations.
    public let validation: [ModelValidationRecord]

    /// Creates an entry after checking identity, license, files, sizes, and hashes.
    public init(
        metadata: ModelCatalogMetadata,
        manifest: ModelManifest,
        downloadFiles: [ModelDownloadFile],
        license: ModelLicense,
        requirements: ModelRequirements,
        validation: [ModelValidationRecord] = []
    ) throws {
        try Self.validate(
            EntryValidationInput(
                metadata: metadata,
                manifest: manifest,
                downloadFiles: downloadFiles,
                license: license,
                requirements: requirements,
                validation: validation
            )
        )
        self.metadata = metadata
        self.manifest = manifest
        self.downloadFiles = downloadFiles.sorted { $0.relativePath < $1.relativePath }
        self.license = license
        self.requirements = requirements
        self.validation = validation
    }

    /// Total transfer size before protocol overhead.
    public var approximateDownloadBytes: UInt64 {
        downloadFiles.reduce(0) { $0 + $1.byteCount }
    }

    private static func validate(_ input: EntryValidationInput) throws {
        let metadata = input.metadata
        let manifest = input.manifest
        let downloadFiles = input.downloadFiles
        let license = input.license
        guard metadata.key.modelID == manifest.modelID else {
            throw ModelCatalogError.identityMismatch
        }
        guard license.identifier == manifest.license else {
            throw ModelCatalogError.licenseMismatch
        }
        guard !metadata.key.version.isEmpty, !metadata.displayName.isEmpty,
            !metadata.publisher.isEmpty
        else {
            throw ModelCatalogError.invalidMetadata
        }
        guard license.url.scheme?.lowercased() == "https" else {
            throw ModelCatalogError.invalidLicenseURL
        }
        guard URL(string: manifest.source)?.scheme?.lowercased() == "https" else {
            throw ModelCatalogError.invalidSourceURL
        }
        let manifestFiles = Dictionary(
            uniqueKeysWithValues: manifest.files.map {
                ($0.relativePath, FileIdentity(byteCount: $0.byteCount, digest: $0.sha256))
            })
        let downloads = Dictionary(
            uniqueKeysWithValues: downloadFiles.map {
                ($0.relativePath, FileIdentity(byteCount: $0.byteCount, digest: $0.sha256))
            })
        guard manifestFiles == downloads else {
            throw ModelCatalogError.downloadManifestMismatch
        }
        let downloadBytes = downloadFiles.reduce(0) { $0 + $1.byteCount }
        guard input.requirements.resources.minimumFreeStorageBytes >= downloadBytes else {
            throw ModelCatalogError.insufficientStorageRequirement
        }
        guard metadata.status != .stable || !input.validation.isEmpty else {
            throw ModelCatalogError.stableEntryRequiresValidation
        }
    }

    private struct EntryValidationInput {
        let metadata: ModelCatalogMetadata
        let manifest: ModelManifest
        let downloadFiles: [ModelDownloadFile]
        let license: ModelLicense
        let requirements: ModelRequirements
        let validation: [ModelValidationRecord]
    }

    private struct FileIdentity: Equatable {
        let byteCount: UInt64
        let digest: ModelContentDigest
    }
}

/// Signed catalog payload containing immutable model versions.
public struct ModelCatalog: Codable, Hashable, Sendable {
    /// Only catalog schema currently accepted.
    public static let currentFormatVersion: UInt32 = 1

    /// Catalog schema version.
    public let formatVersion: UInt32
    /// Immutable publisher revision.
    public let revision: String
    /// Publisher generation time used for rollback protection.
    public let generatedAt: Date
    /// Canonically ordered model entries.
    public let entries: [ModelCatalogEntry]

    /// Creates a canonical catalog with unique model versions.
    public init(
        formatVersion: UInt32 = Self.currentFormatVersion,
        revision: String,
        generatedAt: Date,
        entries: [ModelCatalogEntry]
    ) throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw ModelCatalogError.unsupportedFormatVersion
        }
        guard !revision.isEmpty else { throw ModelCatalogError.invalidRevision }
        let keys = entries.map(\.metadata.key)
        guard Set(keys).count == keys.count else { throw ModelCatalogError.duplicateEntry }
        self.formatVersion = formatVersion
        self.revision = revision
        self.generatedAt = generatedAt
        self.entries = entries.sorted { lhs, rhs in
            if lhs.metadata.key.modelID == rhs.metadata.key.modelID {
                return lhs.metadata.key.version < rhs.metadata.key.version
            }
            return lhs.metadata.key.modelID.rawValue < rhs.metadata.key.modelID.rawValue
        }
    }
}

/// Catalog structure, transport, signature, and immutability failures.
public enum ModelCatalogError: Error, Equatable, Sendable {
    case unsupportedFormatVersion
    case invalidRevision
    case duplicateEntry
    case identityMismatch
    case invalidMetadata
    case licenseMismatch
    case invalidLicenseURL
    case invalidSourceURL
    case downloadManifestMismatch
    case insufficientStorageRequirement
    case stableEntryRequiresValidation
    case insecureDownloadURL
    case untrustedSigningKey
    case invalidSignature
    case invalidPayload
    case catalogRollback
    case immutableVersionChanged(ModelCatalogKey)
}
