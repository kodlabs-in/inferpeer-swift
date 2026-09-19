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
        registeredAt: Date
    ) {
        modelID = verified.key.modelID.rawValue
        revision = verified.key.revision
        manifestDigest = verified.manifestDigest.bytes
        self.manifestData = manifestData
        directoryPath = verified.directoryURL.path
        self.registeredAt = registeredAt
    }

    func registration() throws -> StoredVerifiedModelManifest {
        let manifest = try ModelManifestCodec.decode(manifestData)
        let digest = try ModelContentDigest(bytes: manifestDigest)
        let computedDigest = Data(SHA256.hash(data: manifestData))
        let expectedRevision = "manifest-v\(manifest.formatVersion)-\(Self.hex(computedDigest))"
        let key = try ModelReference(modelID: manifest.modelID, revision: revision)
        let verified = VerifiedModelManifest(
            key: key,
            manifestDigest: digest,
            manifest: manifest,
            directoryURL: URL(fileURLWithPath: directoryPath, isDirectory: true)
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

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
