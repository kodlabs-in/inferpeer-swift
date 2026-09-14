import Foundation
import GRDB
import InferPeerCore
import InferPeerProtocol

/// A WAL-mode SQLite implementation of the durable Core job-store contract.
public final class SQLiteJobStore: JobStore, Sendable {
    private let database: DatabasePool
    private let configuration: SQLiteStorageConfiguration
    private let dateProvider: any StorageDateProvider

    /// Opens, configures, and migrates a file-backed SQLite job store.
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

    /// Atomically admits a request and its first replay event.
    public func accept(_ submission: RequestSubmission) async throws -> RequestAcceptance {
        let timestamp = dateProvider.now()
        return try await withMappedStorageErrors {
            try await database.write { database in
                try JobStoreDatabase.accept(
                    submission,
                    at: timestamp,
                    maximumDatabaseBytes: configuration.maximumDatabaseBytes,
                    in: database
                )
            }
        }
    }

    /// Loads a request only after verifying its authenticated owner.
    public func request(requestID: RequestID, callerID: PeerID) async throws -> StoredRequest? {
        try await withMappedStorageErrors {
            try await database.read { database in
                try JobStoreDatabase.request(
                    requestID: requestID,
                    callerID: callerID,
                    in: database
                )
            }
        }
    }

    /// Atomically commits a lifecycle revision and all accompanying replay events.
    public func commit(_ mutation: RequestMutation) async throws -> StoredRequest {
        let timestamp = dateProvider.now()
        return try await withMappedStorageErrors {
            try await database.write { database in
                try JobStoreDatabase.commit(
                    mutation,
                    at: timestamp,
                    maximumDatabaseBytes: configuration.maximumDatabaseBytes,
                    in: database
                )
            }
        }
    }

    /// Returns one validated, bounded page of replay events in cursor order.
    public func replay(
        requestID: RequestID,
        callerID: PeerID,
        after cursor: UInt64?,
        limit: Int
    ) async throws -> [PersistedRequestEvent] {
        guard (1...configuration.maximumReplayPageSize).contains(limit) else {
            throw SQLiteStorageError.invalidReplayLimit
        }
        return try await withMappedStorageErrors {
            try await database.read { database in
                try JobStoreDatabase.replay(
                    requestID: requestID,
                    callerID: callerID,
                    after: cursor,
                    limit: limit,
                    in: database
                )
            }
        }
    }

    /// Monotonically records a caller's observed replay cursor.
    public func acknowledge(
        requestID: RequestID,
        callerID: PeerID,
        through cursor: UInt64
    ) async throws {
        try await withMappedStorageErrors {
            try await database.write { database in
                try JobStoreDatabase.acknowledge(
                    requestID: requestID,
                    callerID: callerID,
                    through: cursor,
                    in: database
                )
            }
        }
    }

    /// Replaces old terminal requests with compact deduplication tombstones.
    public func pruneTerminalRequests(before date: Date) async throws {
        let timestamp = dateProvider.now()
        try await withMappedStorageErrors {
            try await database.write { database in
                try JobStoreDatabase.pruneTerminalRequests(
                    before: date,
                    prunedAt: timestamp,
                    in: database
                )
            }
        }
    }

    /// Closes all SQLite connections after outstanding operations finish.
    public func close() throws {
        try database.close()
    }
}

func withMappedStorageErrors<Value: Sendable>(
    _ operation: () async throws -> Value
) async throws -> Value {
    do {
        return try await operation()
    } catch let error as RequestPersistenceError {
        throw error
    } catch let error as SQLiteStorageError {
        throw error
    } catch let error as DatabaseError
        where error.resultCode == .SQLITE_FULL || error.resultCode == .SQLITE_NOMEM
    {
        throw RequestPersistenceError.resourceExhausted
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw SQLiteStorageError.databaseFailure
    }
}
