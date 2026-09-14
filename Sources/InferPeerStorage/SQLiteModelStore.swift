import Foundation
import GRDB
import InferPeerInference

/// One verified local model registration and its durable registration time.
public struct StoredModelRegistration: Hashable, Sendable {
    /// The exact model descriptor and local file directory.
    public let artifact: LocalModelArtifact

    /// The time this registration was first committed.
    public let registeredAt: Date

    /// Creates a stored model registration.
    public init(artifact: LocalModelArtifact, registeredAt: Date) {
        self.artifact = artifact
        self.registeredAt = registeredAt
    }
}

/// The idempotent result of registering a verified local model.
public enum ModelRegistrationResult: Sendable {
    /// A new exact model revision was registered.
    case registered(StoredModelRegistration)

    /// The identical descriptor and local directory were registered previously.
    case duplicate(StoredModelRegistration)
}

/// SQLite persistence for verified local model descriptors and locations.
public final class SQLiteModelStore: Sendable {
    private let database: DatabasePool
    private let configuration: SQLiteStorageConfiguration
    private let dateProvider: any StorageDateProvider

    /// Opens, configures, and migrates a file-backed model registry.
    public init(
        databaseURL: URL,
        configuration: SQLiteStorageConfiguration = .standard,
        dateProvider: any StorageDateProvider = SystemStorageDateProvider()
    ) throws {
        database = try StorageConnection.open(
            databaseURL: databaseURL,
            configuration: configuration
        )
        self.configuration = configuration
        self.dateProvider = dateProvider
    }

    /// Registers an exact verified model or returns its identical existing registration.
    public func register(_ artifact: LocalModelArtifact) async throws -> ModelRegistrationResult {
        let timestamp = dateProvider.now()
        return try await withMappedStorageErrors {
            try await database.write { database in
                if let existing = try Self.record(
                    reference: artifact.descriptor.reference,
                    in: database
                ) {
                    return try Self.duplicateResult(for: artifact, existing: existing)
                }
                var record = try ModelRecord(artifact: artifact, registeredAt: timestamp)
                try record.insert(database)
                try DatabaseQuota.enforce(
                    configuration.maximumDatabaseBytes,
                    in: database
                )
                return .registered(try record.registration())
            }
        }
    }

    /// Loads one exact registered model revision.
    public func model(reference: ModelReference) async throws -> StoredModelRegistration? {
        try await withMappedStorageErrors {
            try await database.read { database in
                try Self.record(reference: reference, in: database)?.registration()
            }
        }
    }

    /// Returns all model registrations in stable identifier and revision order.
    public func models() async throws -> [StoredModelRegistration] {
        try await withMappedStorageErrors {
            try await database.read { database in
                let records = try ModelRecord.fetchAll(
                    database,
                    sql: "SELECT * FROM registeredModel ORDER BY modelID, revision"
                )
                return try records.map { try $0.registration() }
            }
        }
    }

    /// Removes one exact model registration without deleting model files.
    public func remove(reference: ModelReference) async throws {
        try await withMappedStorageErrors {
            try await database.write { database in
                try database.execute(
                    sql: "DELETE FROM registeredModel WHERE modelID = ? AND revision = ?",
                    arguments: [reference.modelID.rawValue, reference.revision]
                )
            }
        }
    }

    /// Closes all SQLite connections after outstanding operations finish.
    public func close() throws {
        try database.close()
    }

    private static func record(
        reference: ModelReference,
        in database: Database
    ) throws -> ModelRecord? {
        try ModelRecord.fetchOne(
            database,
            sql: "SELECT * FROM registeredModel WHERE modelID = ? AND revision = ?",
            arguments: [reference.modelID.rawValue, reference.revision]
        )
    }

    private static func duplicateResult(
        for artifact: LocalModelArtifact,
        existing: ModelRecord
    ) throws -> ModelRegistrationResult {
        let candidate = try ModelRecord(
            artifact: artifact,
            registeredAt: existing.registeredAt
        )
        guard candidate.descriptorData == existing.descriptorData,
            candidate.directoryPath == existing.directoryPath
        else {
            throw SQLiteStorageError.modelRegistrationConflict
        }
        return .duplicate(try existing.registration())
    }
}
