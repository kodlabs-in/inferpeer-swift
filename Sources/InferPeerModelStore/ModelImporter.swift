import Foundation
import InferPeerInference
import InferPeerStorage

/// Optional archive implementation. The package still performs exact-tree verification afterward.
public protocol ModelArchiveExtracting: Sendable {
    func extract(_ archiveURL: URL, to destinationURL: URL) async throws
}

enum ModelImporter {
    static func stage(
        sourceURL: URL,
        entry: ModelCatalogEntry,
        stagingURL: URL,
        archiveExtractor: (any ModelArchiveExtracting)?
    ) async throws {
        let source = sourceURL.standardizedFileURL
        guard source.isFileURL, stagingURL.isFileURL else {
            throw InferPeerModelStoreError.unsafeImportLocation
        }
        let scopedAccess = source.startAccessingSecurityScopedResource()
        defer {
            if scopedAccess { source.stopAccessingSecurityScopedResource() }
        }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw InferPeerModelStoreError.unsafeImportLocation
        }
        try reset(stagingURL)
        if values.isDirectory == true {
            _ = try ModelManifestVerifier().verify(entry.manifest, in: source)
            try FileManager.default.copyItem(at: source, to: stagingURL)
            return
        }
        guard let archiveExtractor else {
            throw InferPeerModelStoreError.archiveImporterRequired
        }
        try FileManager.default.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false
        )
        try await archiveExtractor.extract(source, to: stagingURL)
        _ = try ModelManifestVerifier().verify(entry.manifest, in: stagingURL)
    }

    private static func reset(_ stagingURL: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                try FileManager.default.removeItem(at: stagingURL)
            }
        } catch {
            throw InferPeerModelStoreError.fileSystemFailure
        }
    }
}
