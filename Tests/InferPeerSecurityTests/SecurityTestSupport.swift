import Foundation
import InferPeerCore
import InferPeerProtocol
import InferPeerSecurity
import Testing

final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) throws -> Data? {
        lock.withLock { values[key] }
    }

    func setData(_ data: Data, forKey key: String) throws {
        lock.withLock { values[key] = data }
    }

    func removeData(forKey key: String) throws {
        _ = lock.withLock { values.removeValue(forKey: key) }
    }

    func replaceAllValues(with data: Data) {
        lock.withLock {
            for key in Array(values.keys) {
                values[key] = data
            }
        }
    }
}

final class MutableSecurityDateProvider: SecurityDateProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(date: Date = Date(timeIntervalSince1970: 10_000)) {
        self.date = date
    }

    func now() -> Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}

actor MemoryTrustRepository: PeerTrustRepository {
    private var records: [PeerID: PeerTrustRecord] = [:]
    private(set) var approvedRoles: Set<NodeRole> = []

    func trustRecord(peerID: PeerID) -> PeerTrustRecord? {
        records[peerID]
    }

    func recordApproval(
        _ identity: PresentedPeerIdentity,
        roles: Set<NodeRole>
    ) {
        records[identity.peerID] = PeerTrustRecord(identity: identity, revokedAt: nil)
        approvedRoles = roles
    }

    func recordRevocation(peerID: PeerID) throws {
        guard let record = records[peerID] else {
            throw SecurityTestError.missingTrustRecord
        }
        records[peerID] = PeerTrustRecord(identity: record.identity, revokedAt: Date())
    }

    func approvedRoleSet() -> Set<NodeRole> {
        approvedRoles
    }
}

func makePairingCoordinator() throws -> PairingCoordinator {
    PairingCoordinator(
        clusterID: try #require(ClusterID(rawValue: "cluster-1")),
        endpoint: try PeerEndpoint(host: "coordinator.local", port: 50_051),
        certificateFingerprint: try CertificateFingerprint(
            bytes: Data(repeating: 0xA5, count: CertificateFingerprint.byteCount)
        )
    )
}

func makePresentedIdentity(
    peerID: String = "peer-remote",
    fingerprintByte: UInt8 = 0xB6
) throws -> PresentedPeerIdentity {
    PresentedPeerIdentity(
        peerID: try #require(PeerID(rawValue: peerID)),
        certificateFingerprint: try CertificateFingerprint(
            bytes: Data(repeating: fingerprintByte, count: CertificateFingerprint.byteCount)
        )
    )
}

enum SecurityTestError: Error {
    case missingTrustRecord
}
