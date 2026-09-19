import GRDB

extension ModelStoreRegistry {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("model_store_v1") { database in
            try createCatalogEntries(in: database)
            try createModelVersions(in: database)
            try createModelFiles(in: database)
            try createInstallations(in: database)
            try createAdapterCompatibility(in: database)
            try createDownloadJobs(in: database)
            try createValidationRuns(in: database)
        }
        return migrator
    }

    private static func createCatalogEntries(in database: Database) throws {
        try database.create(table: "catalog_entries", options: .ifNotExists) { table in
            table.column("model_id", .text).notNull()
            table.column("catalog_version", .text).notNull()
            table.column("catalog_revision", .text).notNull()
            table.column("status", .text).notNull()
            table.column("payload", .blob).notNull()
            table.primaryKey(["model_id", "catalog_version"])
        }
    }

    private static func createModelVersions(in database: Database) throws {
        try database.create(table: "model_versions", options: .ifNotExists) { table in
            table.column("model_id", .text).notNull()
            table.column("catalog_version", .text).notNull()
            table.column("manifest_revision", .text).notNull().unique()
            table.column("runtime_id", .text).notNull()
            table.column("format", .text).notNull()
            table.column("quantization", .text).notNull()
            table.column("manifest_payload", .blob).notNull()
            table.column("installed_bytes", .text).notNull()
            table.primaryKey(["model_id", "catalog_version"])
        }
    }

    private static func createModelFiles(in database: Database) throws {
        try database.create(table: "model_files", options: .ifNotExists) { table in
            table.column("model_id", .text).notNull()
            table.column("catalog_version", .text).notNull()
            table.column("relative_path", .text).notNull()
            table.column("role", .text).notNull()
            table.column("byte_count", .text).notNull()
            table.column("sha256", .blob).notNull()
            table.primaryKey(["model_id", "catalog_version", "relative_path"])
        }
    }

    private static func createInstallations(in database: Database) throws {
        try database.create(table: "installations", options: .ifNotExists) { table in
            table.column("model_id", .text).notNull()
            table.column("catalog_version", .text).notNull()
            table.column("manifest_revision", .text).notNull()
            table.column("directory_path", .text).notNull()
            table.column("state", .text).notNull()
            table.column("installed_at", .double).notNull()
            table.primaryKey(["model_id", "catalog_version"])
        }
    }

    private static func createAdapterCompatibility(in database: Database) throws {
        try database.create(table: "adapter_compatibility", options: .ifNotExists) { table in
            table.column("model_id", .text).notNull()
            table.column("catalog_version", .text).notNull()
            table.column("runtime_id", .text).notNull()
            table.column("adapter_version", .text).notNull()
            table.column("support", .text).notNull()
            table.column("evaluated_at", .double).notNull()
            table.primaryKey(["model_id", "catalog_version", "runtime_id"])
        }
    }

    private static func createDownloadJobs(in database: Database) throws {
        try database.create(table: "download_jobs", options: .ifNotExists) { table in
            table.column("job_id", .text).primaryKey()
            table.column("model_id", .text).notNull()
            table.column("catalog_version", .text).notNull()
            table.column("state", .text).notNull()
            table.column("completed_bytes", .text).notNull()
            table.column("total_bytes", .text).notNull()
            table.column("updated_at", .double).notNull()
        }
    }

    private static func createValidationRuns(in database: Database) throws {
        try database.create(table: "validation_runs", options: .ifNotExists) { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("model_id", .text).notNull()
            table.column("catalog_version", .text).notNull()
            table.column("hardware_identifier", .text).notNull()
            table.column("os_version", .text).notNull()
            table.column("adapter_version", .text).notNull()
            table.column("passed_at", .double).notNull()
        }
    }
}
