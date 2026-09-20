import Foundation

struct ModelStoreLayout: Sendable {
    let root: URL
    let databaseURL: URL
    let catalogDirectory: URL
    let stagingDirectory: URL
    let installedDirectory: URL

    init(root: URL) throws {
        guard root.isFileURL else { throw InferPeerModelStoreError.fileSystemFailure }
        self.root = root.standardizedFileURL
        databaseURL = self.root.appendingPathComponent("registry.sqlite")
        catalogDirectory = self.root.appendingPathComponent("catalog", isDirectory: true)
        stagingDirectory = self.root.appendingPathComponent("staging", isDirectory: true)
        installedDirectory = self.root.appendingPathComponent("installed", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: catalogDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: installedDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw InferPeerModelStoreError.fileSystemFailure
        }
    }

    func versionRoot(for key: ModelCatalogKey) throws -> URL {
        guard Self.safe(key.modelID.rawValue), Self.safe(key.version) else {
            throw InferPeerModelStoreError.fileSystemFailure
        }
        return
            installedDirectory
            .appendingPathComponent(key.modelID.rawValue, isDirectory: true)
            .appendingPathComponent(key.version, isDirectory: true)
    }

    func downloadStaging(for key: ModelCatalogKey) throws -> URL {
        try versionRoot(for: key).appendingPathComponent("download.staging", isDirectory: true)
    }

    func importStaging(for key: ModelCatalogKey) throws -> URL {
        try versionRoot(for: key).appendingPathComponent("import.staging", isDirectory: true)
    }

    private static func safe(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".."
            && !component.contains("/") && !component.contains("\\")
            && !component.contains("\0")
    }
}
