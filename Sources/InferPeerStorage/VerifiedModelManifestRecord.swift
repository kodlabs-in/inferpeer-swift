import Crypto
import Foundation
import GRDB
import InferPeerInference

struct VerifiedModelManifestRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "modelManifest"

    var modelID: String
    var revision: String
    var manifestDigest: Data
    var manifestData: Data
    var directoryPath: String
    var registeredAt: Date

    init(
        verified: VerifiedModelManifest,
        manifestData: Data,
        registeredAt: Date,
        modelRootDirectory: URL?
    ) {
        modelID = verified.key.modelID.rawValue
        revision = verified.key.revision
        manifestDigest = verified.manifestDigest.bytes
        self.manifestData = manifestData
        directoryPath = Self.storedPath(
            for: verified.directoryURL,
            relativeTo: modelRootDirectory
        )
        self.registeredAt = registeredAt
    }

    func registration(modelRootDirectory: URL? = nil) throws -> StoredVerifiedModelManifest {
        let manifest = try ModelManifestCodec.decode(manifestData)
        let digest = try ModelContentDigest(bytes: manifestDigest)
        let computedDigest = Data(SHA256.hash(data: manifestData))
        let expectedRevision = "manifest-v\(manifest.formatVersion)-\(Self.hex(computedDigest))"
        let key = try ModelReference(modelID: manifest.modelID, revision: revision)
        let verified = VerifiedModelManifest(
            key: key,
            manifestDigest: digest,
            manifest: manifest,
            directoryURL: try resolvedDirectory(relativeTo: modelRootDirectory)
        )
        guard try ModelManifestCodec.encode(manifest) == manifestData,
            manifest.modelID.rawValue == modelID,
            manifestDigest == computedDigest,
            revision == expectedRevision
        else {
            throw ModelManifestRegistrationError.corruptManifest
        }
        return StoredVerifiedModelManifest(verified: verified, registeredAt: registeredAt)
    }

    private func resolvedDirectory(relativeTo root: URL?) throws -> URL {
        guard let root else {
            return URL(fileURLWithPath: directoryPath, isDirectory: true)
        }
        let stored = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let components: ArraySlice<String>
        if stored.path.hasPrefix("/"),
            let modelIndex = stored.pathComponents.lastIndex(of: modelID)
        {
            components = stored.pathComponents[modelIndex...]
        } else if stored.path.hasPrefix("/") {
            components = [revision][...]
        } else {
            components = directoryPath.split(separator: "/").map(String.init)[...]
        }
        guard !components.isEmpty, components.last == revision else {
            throw ModelManifestRegistrationError.corruptManifest
        }
        return components.reduce(root) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }

    private static func storedPath(for directory: URL, relativeTo root: URL?) -> String {
        guard let root else { return directory.path }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard directory.path.hasPrefix(rootPath) else { return directory.path }
        return String(directory.path.dropFirst(rootPath.count))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
