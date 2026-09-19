import Foundation
import GRDB
import InferPeerInference

/// One durable, verified model-manifest registration.
public struct StoredVerifiedModelManifest: Hashable, Sendable {
    /// Verified manifest and installed directory.
    public let verified: VerifiedModelManifest

    /// Time the registration was first committed.
    public let registeredAt: Date

    /// Creates a durable registration value.
    public init(verified: VerifiedModelManifest, registeredAt: Date) {
        self.verified = verified
        self.registeredAt = registeredAt
    }
}

/// Idempotent result of importing a verified manifest.
public enum VerifiedModelRegistrationResult: Sendable {
    /// Staging was atomically renamed and a new database row committed.
    case registered(StoredVerifiedModelManifest)

    /// The exact manifest was already registered; staging was left untouched.
    case duplicate(StoredVerifiedModelManifest)
}

/// Local-only registration contract. Implementations must never download model content.
public protocol VerifiedModelManifestStoring: Sendable {
    /// Verifies and atomically imports one staging directory below `installRoot`.
    func register(
        _ manifest: ModelManifest,
        stagingDirectory: URL,
        installRoot: URL
    ) async throws -> VerifiedModelRegistrationResult

    /// Loads one exact manifest-derived model key.
    func model(key: ModelKey) async throws -> StoredVerifiedModelManifest?
}

/// SQLite-backed, actor-serialized manifest verifier and atomic local importer.
public actor SQLiteVerifiedModelManifestStore: VerifiedModelManifestStoring {
    private let database: DatabasePool
    private let configuration: SQLiteStorageConfiguration
    private let dateProvider: any StorageDateProvider
    private let verifier: ModelManifestVerifier
    private let modelRootDirectory: URL?

    /// Opens and migrates the manifest registry without touching model files.
    public init(
        databaseURL: URL,
        configuration: SQLiteStorageConfiguration = .standard,
        dateProvider: any StorageDateProvider = SystemStorageDateProvider(),
        verifier: ModelManifestVerifier = .init(),
        modelRootDirectory: URL? = nil
    ) throws {
        guard modelRootDirectory?.isFileURL != false else {
            throw ModelManifestRegistrationError.localFileURLRequired
        }
        database = try StorageConnection.open(
            databaseURL: databaseURL,
            configuration: configuration
        )
        self.configuration = configuration
        self.dateProvider = dateProvider
        self.verifier = verifier
        self.modelRootDirectory = modelRootDirectory?.standardizedFileURL
    }

    /// Verifies every staged byte before atomically renaming and committing registration.
    public func register(
        _ manifest: ModelManifest,
        stagingDirectory: URL,
        installRoot: URL
    ) async throws -> VerifiedModelRegistrationResult {
        let locations = try Self.validatedLocations(
            stagingDirectory: stagingDirectory,
            installRoot: installRoot
        )
        let staged = try verifier.verify(manifest, in: locations.staging)
        let manifestData = try ModelManifestCodec.encode(manifest)
        if let existing = try await record(key: staged.key) {
            return try Self.duplicate(
                staged: staged,
                manifestData: manifestData,
                existing: existing,
                modelRootDirectory: modelRootDirectory
            )
        }
        return try await install(staged, manifestData: manifestData, locations: locations)
    }

    private func install(
        _ staged: VerifiedModelManifest,
        manifestData: Data,
        locations: (staging: URL, root: URL)
    ) async throws -> VerifiedModelRegistrationResult {
        let destination = locations.root.appendingPathComponent(
            staged.key.revision,
            isDirectory: true
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ModelManifestRegistrationError.destinationAlreadyExists
        }
        do {
            try FileManager.default.moveItem(at: locations.staging, to: destination)
        } catch {
            throw ModelManifestRegistrationError.fileSystemFailure
        }

        let installed = VerifiedModelManifest(
            key: staged.key,
            manifestDigest: staged.manifestDigest,
            manifest: staged.manifest,
            directoryURL: destination
        )
        do {
            let registration = try await insert(installed, manifestData: manifestData)
            return .registered(registration)
        } catch {
            do {
                try FileManager.default.moveItem(at: destination, to: locations.staging)
            } catch {
                throw ModelManifestRegistrationError.fileSystemFailure
            }
            throw error
        }
    }

    /// Loads one exact manifest-derived model registration.
    public func model(key: ModelKey) async throws -> StoredVerifiedModelManifest? {
        try await record(key: key)?.registration(modelRootDirectory: modelRootDirectory)
    }

    /// Returns registrations in stable logical-model and manifest-revision order.
    public func models() async throws -> [StoredVerifiedModelManifest] {
        let modelRootDirectory = modelRootDirectory
        do {
            return try await database.read { database in
                try VerifiedModelManifestRecord.fetchAll(
                    database,
                    sql: "SELECT * FROM modelManifest ORDER BY modelID, revision"
                ).map {
                    try $0.registration(modelRootDirectory: modelRootDirectory)
                }
            }
        } catch let error as ModelManifestRegistrationError {
            throw error
        } catch {
            throw ModelManifestRegistrationError.databaseFailure
        }
    }

    /// Removes registry metadata without deleting host-owned installed files.
    public func remove(key: ModelKey) async throws {
        do {
            try await database.write { database in
                try database.execute(
                    sql: "DELETE FROM modelManifest WHERE modelID = ? AND revision = ?",
                    arguments: [key.modelID.rawValue, key.revision]
                )
            }
        } catch {
            throw ModelManifestRegistrationError.databaseFailure
        }
    }

    /// Closes database connections after pending operations finish.
    public func close() throws {
        try database.close()
    }

    private func record(key: ModelKey) async throws -> VerifiedModelManifestRecord? {
        do {
            return try await database.read { database in
                try VerifiedModelManifestRecord.fetchOne(
                    database,
                    sql: "SELECT * FROM modelManifest WHERE modelID = ? AND revision = ?",
                    arguments: [key.modelID.rawValue, key.revision]
                )
            }
        } catch {
            throw ModelManifestRegistrationError.databaseFailure
        }
    }

    private func insert(
        _ verified: VerifiedModelManifest,
        manifestData: Data
    ) async throws -> StoredVerifiedModelManifest {
        let timestamp = dateProvider.now().timeIntervalSinceReferenceDate
        let registeredAt = Date(
            timeIntervalSinceReferenceDate: (timestamp * 1_000).rounded() / 1_000
        )
        let modelRootDirectory = modelRootDirectory
        do {
            return try await database.write { database in
                var record = VerifiedModelManifestRecord(
                    verified: verified,
                    manifestData: manifestData,
                    registeredAt: registeredAt,
                    modelRootDirectory: modelRootDirectory
                )
                try record.insert(database)
                try DatabaseQuota.enforce(configuration.maximumDatabaseBytes, in: database)
                return try record.registration(modelRootDirectory: modelRootDirectory)
            }
        } catch let error as ModelManifestRegistrationError {
            throw error
        } catch {
            throw ModelManifestRegistrationError.databaseFailure
        }
    }

    private static func duplicate(
        staged: VerifiedModelManifest,
        manifestData: Data,
        existing: VerifiedModelManifestRecord,
        modelRootDirectory: URL?
    ) throws -> VerifiedModelRegistrationResult {
        guard existing.manifestDigest == staged.manifestDigest.bytes,
            existing.manifestData == manifestData
        else {
            throw ModelManifestRegistrationError.registrationConflict
        }
        return .duplicate(
            try existing.registration(modelRootDirectory: modelRootDirectory)
        )
    }

    private static func validatedLocations(
        stagingDirectory: URL,
        installRoot: URL
    ) throws -> (staging: URL, root: URL) {
        guard stagingDirectory.isFileURL, installRoot.isFileURL else {
            throw ModelManifestRegistrationError.localFileURLRequired
        }
        let staging = stagingDirectory.standardizedFileURL
        let root = installRoot.standardizedFileURL
        guard staging.deletingLastPathComponent() == root else {
            throw ModelManifestRegistrationError.stagingMustBeInsideInstallRoot
        }
        let values: URLResourceValues
        do {
            values = try root.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ])
        } catch {
            throw ModelManifestRegistrationError.fileSystemFailure
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ModelManifestRegistrationError.fileSystemFailure
        }
        return (staging, root)
    }
}
