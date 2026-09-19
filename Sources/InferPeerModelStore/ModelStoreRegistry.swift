import Foundation
import GRDB
import InferPeerInference
import InferPeerProtocol

/// Durable lifecycle state for catalog, download, load, and removal workflows.
public enum ModelInstallationState: String, Codable, Hashable, Sendable {
    case catalogued
    case queued
    case downloading
    case importing
    case verifying
    case installed
    case loading
    case ready
    case paused
    case incompatible
    case corrupt
    case failed
    case removing
    case removed
}

struct ModelDownloadJobRecord: Hashable, Sendable {
    let id: UUID
    let key: ModelCatalogKey
    let state: ModelInstallationState
    let completedBytes: UInt64
    let totalBytes: UInt64
    let updatedAt: Date
}

enum ModelStoreRegistryError: Error, Equatable, Sendable {
    case databaseFailure
    case corruptData
    case immutableVersionChanged(ModelCatalogKey)
}

/// GRDB-backed metadata registry. Model bytes always stay in the filesystem.
actor ModelStoreRegistry {
    let database: DatabasePool
    let installedDirectory: URL

    init(databaseURL: URL, installedDirectory: URL) throws {
        guard databaseURL.isFileURL, installedDirectory.isFileURL else {
            throw ModelStoreRegistryError.databaseFailure
        }
        self.installedDirectory = installedDirectory.standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            database = try DatabasePool(path: databaseURL.path)
            try Self.migrator.migrate(database)
            try database.write { database in
                try database.execute(
                    sql: "UPDATE download_jobs SET state = ? WHERE state IN (?, ?)",
                    arguments: [
                        ModelInstallationState.paused.rawValue,
                        ModelInstallationState.queued.rawValue,
                        ModelInstallationState.downloading.rawValue,
                    ]
                )
                try database.execute(
                    sql: "UPDATE installations SET state = ? WHERE state IN (?, ?)",
                    arguments: [
                        ModelInstallationState.installed.rawValue,
                        ModelInstallationState.loading.rawValue,
                        ModelInstallationState.ready.rawValue,
                    ]
                )
            }
        } catch {
            throw ModelStoreRegistryError.databaseFailure
        }
    }

    func replaceCatalog(_ catalog: ModelCatalog) async throws {
        let encoded = try catalog.entries.map { entry in
            (entry, try Self.encode(entry))
        }
        do {
            try await database.write { database in
                for (entry, payload) in encoded {
                    try Self.upsertCatalogEntry(
                        entry,
                        payload: payload,
                        catalogRevision: catalog.revision,
                        database: database
                    )
                }
            }
        } catch let error as ModelStoreRegistryError {
            throw error
        } catch {
            throw ModelStoreRegistryError.databaseFailure
        }
    }

    func recordJob(_ job: ModelDownloadJobRecord) async throws {
        do {
            try await database.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO download_jobs
                            (job_id, model_id, catalog_version, state,
                             completed_bytes, total_bytes, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(job_id) DO UPDATE SET
                            state = excluded.state,
                            completed_bytes = excluded.completed_bytes,
                            total_bytes = excluded.total_bytes,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [
                        job.id.uuidString,
                        job.key.modelID.rawValue,
                        job.key.version,
                        job.state.rawValue,
                        String(job.completedBytes),
                        String(job.totalBytes),
                        job.updatedAt.timeIntervalSince1970,
                    ]
                )
            }
        } catch {
            throw ModelStoreRegistryError.databaseFailure
        }
    }

    func recordCompatibility(
        entry: ModelCatalogEntry,
        adapterVersion: String,
        support: ModelSupport
    ) async throws {
        do {
            try await database.write { database in
                try database.execute(
                    sql: """
                        INSERT OR REPLACE INTO adapter_compatibility
                            (model_id, catalog_version, runtime_id,
                             adapter_version, support, evaluated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        entry.metadata.key.modelID.rawValue,
                        entry.metadata.key.version,
                        entry.manifest.runtime.runtimeIdentifier,
                        adapterVersion,
                        Self.supportName(support),
                        Date().timeIntervalSince1970,
                    ]
                )
            }
        } catch {
            throw ModelStoreRegistryError.databaseFailure
        }
    }

    func recordInstallation(
        _ model: InstalledModel,
        entry: ModelCatalogEntry,
        installedAt: Date = Date()
    ) async throws {
        let manifest = try Self.encode(model.manifest)
        let entryPayload = try Self.encode(entry)
        do {
            try await database.write { database in
                try Self.upsertCatalogEntry(
                    entry,
                    payload: entryPayload,
                    catalogRevision: "imported-or-installed",
                    database: database
                )
                try Self.insertVersion(model, entry: entry, manifest: manifest, in: database)
                try Self.replaceFiles(entry, in: database)
                try Self.upsertInstallation(
                    model, entry: entry, installedAt: installedAt, in: database)
                try Self.replaceValidation(entry, in: database)
            }
        } catch {
            throw ModelStoreRegistryError.databaseFailure
        }
    }

    func installedModels() async throws -> [InstalledModel] {
        try await models(includingCorrupt: false)
    }

    func reconcilableModels() async throws -> [InstalledModel] {
        try await models(includingCorrupt: true)
    }

    private func models(includingCorrupt: Bool) async throws -> [InstalledModel] {
        var states = [
            ModelInstallationState.installed,
            ModelInstallationState.loading,
            ModelInstallationState.ready,
        ]
        if includingCorrupt { states.append(.corrupt) }
        let placeholders = states.map { _ in "?" }.joined(separator: ", ")
        let stateValues = states.map(\.rawValue)
        let installedDirectory = installedDirectory
        do {
            return try await database.read { database in
                let rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT v.model_id, v.catalog_version, i.manifest_revision,
                               v.manifest_payload, v.installed_bytes
                        FROM installations i
                        JOIN model_versions v
                          ON v.model_id = i.model_id
                         AND v.catalog_version = i.catalog_version
                        WHERE i.state IN (\(placeholders))
                        ORDER BY v.model_id, v.catalog_version
                        """,
                    arguments: StatementArguments(stateValues)
                )
                return try rows.map {
                    try Self.installedModel($0, installedDirectory: installedDirectory)
                }
            }
        } catch let error as ModelStoreRegistryError {
            throw error
        } catch {
            throw ModelStoreRegistryError.databaseFailure
        }
    }

    func catalogEntry(for key: ModelKey) async throws -> ModelCatalogEntry? {
        do {
            return try await database.read { database in
                let payload = try Data.fetchOne(
                    database,
                    sql: """
                        SELECT c.payload
                        FROM installations i
                        JOIN catalog_entries c
                          ON c.model_id = i.model_id
                         AND c.catalog_version = i.catalog_version
                        WHERE i.model_id = ? AND i.manifest_revision = ?
                        """,
                    arguments: [key.modelID.rawValue, key.revision]
                )
                guard let payload else { return nil }
                return try Self.decode(payload)
            }
        } catch let error as ModelStoreRegistryError {
            throw error
        } catch {
            throw ModelStoreRegistryError.databaseFailure
        }
    }

    func removeInstallation(key: ModelKey) async throws {
        do {
            try await database.write { database in
                try database.execute(
                    sql: """
                        UPDATE installations SET state = ?
                        WHERE model_id = ? AND manifest_revision = ?
                        """,
                    arguments: [
                        ModelInstallationState.removed.rawValue,
                        key.modelID.rawValue,
                        key.revision,
                    ]
                )
            }
        } catch {
            throw ModelStoreRegistryError.databaseFailure
        }
    }

    private static func supportName(_ support: ModelSupport) -> String {
        switch support {
        case .supported:
            "supported"
        case .experimental:
            "experimental"
        case .unsupported:
            "unsupported"
        }
    }

}
