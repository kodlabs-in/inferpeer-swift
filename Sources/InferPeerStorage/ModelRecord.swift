import Foundation
import GRDB
import InferPeerInference
import InferPeerProtocol
import SwiftProtobuf

struct ModelRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "registeredModel"

    var modelID: String
    var revision: String
    var descriptorData: Data
    var directoryPath: String
    var registeredAt: Date

    init(artifact: LocalModelArtifact, registeredAt: Date) throws {
        modelID = artifact.descriptor.reference.modelID.rawValue
        revision = artifact.descriptor.reference.revision
        descriptorData = try artifact.descriptor.wireValue.serializedData()
        directoryPath = artifact.directoryURL.path
        self.registeredAt = registeredAt
    }

    func registration() throws -> StoredModelRegistration {
        do {
            let wireDescriptor = try InferPeer_V1_ModelDescriptor(
                serializedBytes: descriptorData
            )
            let descriptor = try ModelDescriptor(wireValue: wireDescriptor)
            guard descriptor.reference.modelID.rawValue == modelID,
                descriptor.reference.revision == revision
            else {
                throw SQLiteStorageError.corruptData
            }
            let artifact = try LocalModelArtifact(
                descriptor: descriptor,
                directoryURL: URL(fileURLWithPath: directoryPath, isDirectory: true)
            )
            return StoredModelRegistration(artifact: artifact, registeredAt: registeredAt)
        } catch let error as SQLiteStorageError {
            throw error
        } catch {
            throw SQLiteStorageError.corruptData
        }
    }
}
