import Foundation
import GRDB
import InferPeerCore
import InferPeerProtocol

struct PeerRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "peerMembership"

    var peerID: String
    var certificateFingerprint: Data
    var allowsCaller: Bool
    var allowsCoordinator: Bool
    var allowsWorker: Bool
    var approvedAt: Date
    var revokedAt: Date?

    init(identity: PresentedPeerIdentity, roles: Set<NodeRole>, approvedAt: Date) {
        peerID = identity.peerID.rawValue
        certificateFingerprint = identity.certificateFingerprint.bytes
        allowsCaller = roles.contains(.caller)
        allowsCoordinator = roles.contains(.coordinator)
        allowsWorker = roles.contains(.worker)
        self.approvedAt = approvedAt
        revokedAt = nil
    }

    func membership() throws -> StoredPeerMembership {
        do {
            guard let peerID = PeerID(rawValue: peerID) else {
                throw SQLiteStorageError.corruptData
            }
            let fingerprint = try CertificateFingerprint(bytes: certificateFingerprint)
            return StoredPeerMembership(
                identity: PresentedPeerIdentity(
                    peerID: peerID,
                    certificateFingerprint: fingerprint
                ),
                roles: roles,
                approvedAt: approvedAt,
                revokedAt: revokedAt
            )
        } catch let error as SQLiteStorageError {
            throw error
        } catch {
            throw SQLiteStorageError.corruptData
        }
    }

    var roles: Set<NodeRole> {
        var roles: Set<NodeRole> = []
        if allowsCaller { roles.insert(.caller) }
        if allowsCoordinator { roles.insert(.coordinator) }
        if allowsWorker { roles.insert(.worker) }
        return roles
    }
}
