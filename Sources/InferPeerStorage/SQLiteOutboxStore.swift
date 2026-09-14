import Foundation
import GRDB
import InferPeerCore
import InferPeerProtocol

/// One immutable request retained until a coordinator durably accepts it.
public struct StoredOutboxRequest: Hashable, Sendable {
    /// The stable caller-owned request submission.
    public let submission: RequestSubmission

    /// The time the request entered the local outbox.
    public let enqueuedAt: Date

    /// Creates a stored outbox entry.
    public init(submission: RequestSubmission, enqueuedAt: Date) {
        self.submission = submission
        self.enqueuedAt = enqueuedAt
    }
}

/// The idempotent result of adding a request to the caller outbox.
public enum OutboxEnqueueResult: Sendable {
    /// A new outbox entry was committed.
    case enqueued(StoredOutboxRequest)

    /// The same immutable request was already pending.
    case duplicate(StoredOutboxRequest)
}

/// A durable SQLite caller outbox for submission across connection loss.
public final class SQLiteOutboxStore: Sendable {
    private let database: DatabasePool
    private let configuration: SQLiteStorageConfiguration
    private let dateProvider: any StorageDateProvider

    /// Opens, configures, and migrates a file-backed caller outbox.
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

    /// Adds an immutable request or returns its identical existing entry.
    public func enqueue(_ submission: RequestSubmission) async throws -> OutboxEnqueueResult {
        let timestamp = dateProvider.now()
        return try await withMappedStorageErrors {
            try await database.write { database in
                try Self.enqueue(
                    submission,
                    at: timestamp,
                    maximumDatabaseBytes: configuration.maximumDatabaseBytes,
                    in: database
                )
            }
        }
    }

    /// Returns a bounded, deterministic batch of pending requests for one caller.
    public func pending(callerID: PeerID, limit: Int) async throws -> [StoredOutboxRequest] {
        guard (1...configuration.maximumOutboxBatchSize).contains(limit) else {
            throw SQLiteStorageError.invalidOutboxLimit
        }
        return try await withMappedStorageErrors {
            try await database.read { database in
                let records = try OutboxRecord.fetchAll(
                    database,
                    sql: """
                        SELECT * FROM callerOutbox
                        WHERE callerID = ?
                        ORDER BY enqueuedAt, requestID
                        LIMIT ?
                        """,
                    arguments: [callerID.rawValue, limit]
                )
                return try records.map { try $0.storedRequest() }
            }
        }
    }

    /// Removes a request only after coordinator acceptance or local cancellation.
    public func remove(requestID: RequestID, callerID: PeerID) async throws {
        try await withMappedStorageErrors {
            try await database.write { database in
                guard let record = try OutboxRecord.fetchOne(database, key: requestID.rawValue)
                else {
                    return
                }
                try Self.requireOwner(callerID, storedCallerID: record.callerID)
                _ = try record.delete(database)
            }
        }
    }

    /// Closes all SQLite connections after outstanding operations finish.
    public func close() throws {
        try database.close()
    }

    private static func enqueue(
        _ submission: RequestSubmission,
        at timestamp: Date,
        maximumDatabaseBytes: UInt64,
        in database: Database
    ) throws -> OutboxEnqueueResult {
        if let existing = try OutboxRecord.fetchOne(database, key: submission.requestID.rawValue) {
            return try duplicateResult(for: submission, existing: existing)
        }
        var record = try OutboxRecord(submission: submission, enqueuedAt: timestamp)
        try record.insert(database)
        try DatabaseQuota.enforce(maximumDatabaseBytes, in: database)
        return .enqueued(try record.storedRequest())
    }

    private static func duplicateResult(
        for submission: RequestSubmission,
        existing: OutboxRecord
    ) throws -> OutboxEnqueueResult {
        try requireOwner(submission.callerID, storedCallerID: existing.callerID)
        let requestData = try StoredSubmissionCodec.encodeRequest(submission.request)
        guard existing.contentDigest == submission.contentDigest.bytes,
            existing.requestData == requestData
        else {
            throw RequestPersistenceError.requestConflict
        }
        return .duplicate(try existing.storedRequest())
    }

    private static func requireOwner(_ callerID: PeerID, storedCallerID: String) throws {
        guard callerID.rawValue == storedCallerID else {
            throw RequestPersistenceError.accessDenied
        }
    }
}
