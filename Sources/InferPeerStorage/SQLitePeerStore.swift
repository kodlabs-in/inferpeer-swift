import Foundation
import GRDB
import InferPeerCore
import InferPeerProtocol

/// One durable peer approval and its explicitly allowed roles.
public struct StoredPeerMembership: Hashable, Sendable {
    /// The approved certificate-bound peer identity.
    public let identity: PresentedPeerIdentity

    /// Roles the peer is authorized to perform.
    public let roles: Set<NodeRole>

    /// The latest explicit approval time.
    public let approvedAt: Date

    /// The revocation time, or `nil` while the membership is active.
    public let revokedAt: Date?

    /// Creates a durable peer membership snapshot.
    public init(
        identity: PresentedPeerIdentity,
        roles: Set<NodeRole>,
        approvedAt: Date,
        revokedAt: Date?
    ) {
        self.identity = identity
        self.roles = roles
        self.approvedAt = approvedAt
        self.revokedAt = revokedAt
    }
}

/// SQLite persistence for approved and revoked cluster peer identities.
public final class SQLitePeerStore: Sendable {
    private let database: DatabasePool
    private let configuration: SQLiteStorageConfiguration
    private let dateProvider: any StorageDateProvider

    /// Opens, configures, and migrates a file-backed peer store.
    public init(
        databaseURL: URL,
        configuration: SQLiteStorageConfiguration = .standard,
        dateProvider: any StorageDateProvider = SystemStorageDateProvider()
    ) throws {
        database = try StorageConnection.open(
            databaseURL: databaseURL,
            configuration: configuration
        )
        self.configuration = configuration
        self.dateProvider = dateProvider
    }

    /// Persists an explicit peer approval without silently replacing an active certificate.
    public func approve(
        _ identity: PresentedPeerIdentity,
        roles: Set<NodeRole>
    ) async throws -> StoredPeerMembership {
        guard !roles.isEmpty else { throw SQLiteStorageError.emptyPeerRoles }
        let timestamp = dateProvider.now()
        return try await withMappedStorageErrors {
            try await database.write { database in
                var record = try Self.approvedRecord(
                    identity: identity,
                    roles: roles,
                    timestamp: timestamp,
                    in: database
                )
                try record.save(database)
                try DatabaseQuota.enforce(
                    configuration.maximumDatabaseBytes,
                    in: database
                )
                return try record.membership()
            }
        }
    }

    /// Loads a peer membership by stable identity.
    public func membership(peerID: PeerID) async throws -> StoredPeerMembership? {
        try await withMappedStorageErrors {
            try await database.read { database in
                try PeerRecord.fetchOne(database, key: peerID.rawValue)?.membership()
            }
        }
    }

    /// Returns all non-revoked memberships in stable peer-identifier order.
    public func activeMemberships() async throws -> [StoredPeerMembership] {
        try await withMappedStorageErrors {
            try await database.read { database in
                let records = try PeerRecord.fetchAll(
                    database,
                    sql: "SELECT * FROM peerMembership WHERE revokedAt IS NULL ORDER BY peerID"
                )
                return try records.map { try $0.membership() }
            }
        }
    }

    /// Revokes future access for an approved peer.
    public func revoke(peerID: PeerID) async throws {
        let timestamp = dateProvider.now()
        try await withMappedStorageErrors {
            try await database.write { database in
                guard var record = try PeerRecord.fetchOne(database, key: peerID.rawValue) else {
                    throw SQLiteStorageError.peerNotFound
                }
                record.revokedAt = timestamp
                try record.update(database, columns: ["revokedAt"])
            }
        }
    }

    /// Permanently removes one stored peer membership.
    public func forget(peerID: PeerID) async throws {
        try await withMappedStorageErrors {
            try await database.write { database in
                _ = try PeerRecord.deleteOne(database, key: peerID.rawValue)
            }
        }
    }

    /// Closes all SQLite connections after outstanding operations finish.
    public func close() throws {
        try database.close()
    }

    private static func approvedRecord(
        identity: PresentedPeerIdentity,
        roles: Set<NodeRole>,
        timestamp: Date,
        in database: Database
    ) throws -> PeerRecord {
        guard let existing = try PeerRecord.fetchOne(database, key: identity.peerID.rawValue) else {
            return PeerRecord(identity: identity, roles: roles, approvedAt: timestamp)
        }
        guard
            existing.revokedAt != nil
                || existing.certificateFingerprint == identity.certificateFingerprint.bytes
        else {
            throw SQLiteStorageError.peerIdentityConflict
        }
        return PeerRecord(identity: identity, roles: roles, approvedAt: timestamp)
    }
}
