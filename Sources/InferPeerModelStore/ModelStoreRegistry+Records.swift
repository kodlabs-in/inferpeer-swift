import Foundation
import GRDB
import InferPeerInference
import InferPeerProtocol

extension ModelStoreRegistry {
    func installationState(for key: ModelKey) async throws -> ModelInstallationState? {
        do {
            return try await database.read { database in
                guard
                    let rawValue = try String.fetchOne(
                        database,
                        sql: """
                            SELECT state FROM installations
                            WHERE model_id = ? AND manifest_revision = ?
                            """,
                        arguments: [key.modelID.rawValue, key.revision]
                    )
                else {
                    return nil
                }
                guard let state = ModelInstallationState(rawValue: rawValue) else {
                    throw ModelStoreRegistryError.corruptData
                }
                return state
            }
        } catch let error as ModelStoreRegistryError {
            throw error
        } catch {
            throw ModelStoreRegistryError.databaseFailure
        }
    }

    func updateInstallationState(_ state: ModelInstallationState, key: ModelKey) async throws {
        do {
            try await database.write { database in
                try database.execute(
                    sql: """
                        UPDATE installations SET state = ?
                        WHERE model_id = ? AND manifest_revision = ?
                        """,
                    arguments: [state.rawValue, key.modelID.rawValue, key.revision]
                )
            }
        } catch {
            throw ModelStoreRegistryError.databaseFailure
        }
    }

    static func installedModel(_ row: Row, installedDirectory: URL) throws -> InstalledModel {
        guard let modelID = ModelID(rawValue: row["model_id"]),
            let bytes = UInt64(row["installed_bytes"] as String)
        else {
            throw ModelStoreRegistryError.corruptData
        }
        let revision: String = row["manifest_revision"]
        let catalogVersion: String = row["catalog_version"]
        let key = try ModelReference(modelID: modelID, revision: revision)
        let manifest: ModelManifest = try decode(row["manifest_payload"])
        let directoryURL =
            installedDirectory
            .appendingPathComponent(modelID.rawValue, isDirectory: true)
            .appendingPathComponent(catalogVersion, isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
        return InstalledModel(
            key: key,
            manifest: manifest,
            directoryURL: directoryURL,
            installedByteCount: bytes
        )
    }

    static func upsertCatalogEntry(
        _ entry: ModelCatalogEntry,
        payload: Data,
        catalogRevision: String,
        database: Database
    ) throws {
        let key = entry.metadata.key
        let existing = try Data.fetchOne(
            database,
            sql: "SELECT payload FROM catalog_entries WHERE model_id = ? AND catalog_version = ?",
            arguments: [key.modelID.rawValue, key.version]
        )
        if let existing, existing != payload {
            throw ModelStoreRegistryError.immutableVersionChanged(key)
        }
        try database.execute(
            sql: """
                INSERT OR IGNORE INTO catalog_entries
                    (model_id, catalog_version, catalog_revision, status, payload)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                key.modelID.rawValue,
                key.version,
                catalogRevision,
                entry.metadata.status.rawValue,
                payload,
            ]
        )
    }

    static func insertVersion(
        _ model: InstalledModel,
        entry: ModelCatalogEntry,
        manifest: Data,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT OR REPLACE INTO model_versions
                    (model_id, catalog_version, manifest_revision, runtime_id,
                     format, quantization, manifest_payload, installed_bytes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                entry.metadata.key.modelID.rawValue,
                entry.metadata.key.version,
                model.key.revision,
                model.manifest.runtime.runtimeIdentifier,
                model.manifest.runtime.format,
                model.manifest.runtime.quantization,
                manifest,
                String(model.installedByteCount),
            ]
        )
    }

    static func replaceFiles(_ entry: ModelCatalogEntry, in database: Database) throws {
        let key = entry.metadata.key
        try database.execute(
            sql: "DELETE FROM model_files WHERE model_id = ? AND catalog_version = ?",
            arguments: [key.modelID.rawValue, key.version]
        )
        for file in entry.manifest.files {
            try database.execute(
                sql: """
                    INSERT INTO model_files
                        (model_id, catalog_version, relative_path, role, byte_count, sha256)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    key.modelID.rawValue,
                    key.version,
                    file.relativePath,
                    file.role.rawValue,
                    String(file.byteCount),
                    file.sha256.bytes,
                ]
            )
        }
    }

    static func upsertInstallation(
        _ model: InstalledModel,
        entry: ModelCatalogEntry,
        installedAt: Date,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT OR REPLACE INTO installations
                    (model_id, catalog_version, manifest_revision,
                     directory_path, state, installed_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                entry.metadata.key.modelID.rawValue,
                entry.metadata.key.version,
                model.key.revision,
                [
                    entry.metadata.key.modelID.rawValue,
                    entry.metadata.key.version,
                    model.key.revision,
                ].joined(separator: "/"),
                ModelInstallationState.installed.rawValue,
                installedAt.timeIntervalSince1970,
            ]
        )
    }

    static func replaceValidation(_ entry: ModelCatalogEntry, in database: Database) throws {
        let key = entry.metadata.key
        try database.execute(
            sql: "DELETE FROM validation_runs WHERE model_id = ? AND catalog_version = ?",
            arguments: [key.modelID.rawValue, key.version]
        )
        for record in entry.validation {
            try database.execute(
                sql: """
                    INSERT INTO validation_runs
                        (model_id, catalog_version, hardware_identifier,
                         os_version, adapter_version, passed_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    key.modelID.rawValue,
                    key.version,
                    record.hardwareIdentifier,
                    record.operatingSystemVersion,
                    record.adapterVersion,
                    record.passedAt.timeIntervalSince1970,
                ]
            )
        }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ModelStoreRegistryError.corruptData
        }
    }
}
