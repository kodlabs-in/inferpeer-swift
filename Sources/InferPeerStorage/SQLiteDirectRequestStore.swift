import Foundation
import GRDB
import InferPeerCore
import InferPeerProtocol

/// SQLite metadata store for direct-resource admission and restart interruption.
public final class SQLiteDirectRequestStore: Sendable {
    private let database: DatabasePool
    private let configuration: SQLiteStorageConfiguration
    private let dateProvider: any StorageDateProvider

    /// Opens or migrates a durable direct-request metadata database.
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

    /// Atomically accepts new immutable metadata or returns its exact duplicate.
    public func accept(_ admission: DirectRequestAdmission) async throws
        -> DirectRequestAcceptance
    {
        let timestamp = dateProvider.now()
        return try await withMappedErrors {
            try await database.write { database in
                if let existing = try DirectRequestMetadataRecord.fetchOne(
                    database,
                    key: admission.requestID.rawValue
                ) {
                    return try existing.acceptance(for: admission)
                }
                let record = try DirectRequestMetadataRecord(
                    admission: admission,
                    timestamp: timestamp
                )
                try record.insert(database)
                try DatabaseQuota.enforce(configuration.maximumDatabaseBytes, in: database)
                return .accepted(try record.storedRequest())
            }
        }
    }

    /// Reads one request only for its authenticated owner.
    public func request(
        principalID: String,
        requestID: RequestID
    ) async throws -> StoredDirectRequest? {
        try await withMappedErrors {
            try await database.read { database in
                guard
                    let record = try DirectRequestMetadataRecord.fetchOne(
                        database,
                        key: requestID.rawValue
                    )
                else {
                    return nil
                }
                guard record.principalID == principalID else {
                    throw DirectRequestStoreError.accessDenied
                }
                return try record.storedRequest()
            }
        }
    }

    /// Serializes one lifecycle transition; the first terminal state remains authoritative.
    public func transition(
        principalID: String,
        requestID: RequestID,
        to newState: DirectRequestState
    ) async throws -> StoredDirectRequest {
        let timestamp = dateProvider.now()
        return try await withMappedErrors {
            try await database.write { database in
                try Self.transition(
                    principalID: principalID,
                    requestID: requestID,
                    to: newState,
                    timestamp: timestamp,
                    database: database
                )
            }
        }
    }

    /// Marks prior-incarnation nonterminal requests interrupted without restarting compute.
    public func interruptNonterminalRequests(preceding processIncarnation: String) async throws
        -> Int
    {
        guard !processIncarnation.isEmpty else {
            throw DirectRequestStoreError.invalidAdmission
        }
        let timestamp = dateProvider.now()
        return try await withMappedErrors {
            try await database.write { database in
                try database.execute(
                    sql: """
                        UPDATE directRequestMetadata
                        SET state = ?, updatedAt = ?, terminalAt = ?
                        WHERE processIncarnation != ?
                          AND state IN (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        DirectRequestState.interrupted.rawValue,
                        timestamp,
                        timestamp,
                        processIncarnation,
                        DirectRequestState.accepted.rawValue,
                        DirectRequestState.queued.rawValue,
                        DirectRequestState.preparing.rawValue,
                        DirectRequestState.running.rawValue,
                        DirectRequestState.cancelRequested.rawValue,
                    ]
                )
                return database.changesCount
            }
        }
    }

    /// Closes the underlying database pool.
    public func close() throws {
        try database.close()
    }

    private static func transition(
        principalID: String,
        requestID: RequestID,
        to newState: DirectRequestState,
        timestamp: Date,
        database: Database
    ) throws -> StoredDirectRequest {
        let record = try ownedRecord(
            principalID: principalID,
            requestID: requestID,
            database: database
        )
        guard let currentState = DirectRequestState(rawValue: record.state) else {
            throw DirectRequestStoreError.corruptData
        }
        if currentState.isTerminal || currentState == newState {
            return try record.storedRequest()
        }
        guard currentState.canTransition(to: newState) else {
            throw DirectRequestStoreError.invalidTransition
        }
        try database.execute(
            sql: """
                UPDATE directRequestMetadata
                SET state = ?, updatedAt = ?, terminalAt = ?
                WHERE requestID = ?
                """,
            arguments: [
                newState.rawValue,
                timestamp,
                newState.isTerminal ? timestamp : nil,
                requestID.rawValue,
            ]
        )
        return try ownedRecord(
            principalID: principalID,
            requestID: requestID,
            database: database
        ).storedRequest()
    }

    private static func ownedRecord(
        principalID: String,
        requestID: RequestID,
        database: Database
    ) throws -> DirectRequestMetadataRecord {
        guard
            let record = try DirectRequestMetadataRecord.fetchOne(
                database,
                key: requestID.rawValue
            )
        else {
            throw DirectRequestStoreError.corruptData
        }
        guard record.principalID == principalID else {
            throw DirectRequestStoreError.accessDenied
        }
        return record
    }

    private func withMappedErrors<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch let error as DirectRequestStoreError {
            throw error
        } catch let error as RequestPersistenceError where error == .resourceExhausted {
            throw DirectRequestStoreError.resourceExhausted
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_FULL || error.resultCode == .SQLITE_NOMEM
        {
            throw DirectRequestStoreError.resourceExhausted
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DirectRequestStoreError.databaseFailure
        }
    }
}

private extension DirectRequestState {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .expired, .interrupted:
            true
        case .accepted, .queued, .preparing, .running, .cancelRequested:
            false
        }
    }

    func canTransition(to next: DirectRequestState) -> Bool {
        switch self {
        case .accepted:
            [
                .queued, .preparing, .running, .cancelRequested, .cancelled, .expired, .interrupted,
                .failed,
            ].contains(next)
        case .queued:
            [.preparing, .cancelRequested, .cancelled, .expired, .interrupted, .failed].contains(
                next)
        case .preparing:
            [.running, .cancelRequested, .cancelled, .expired, .interrupted, .failed].contains(next)
        case .running:
            [.cancelRequested, .completed, .cancelled, .expired, .interrupted, .failed].contains(
                next)
        case .cancelRequested:
            [.cancelled, .expired, .interrupted, .failed].contains(next)
        case .completed, .failed, .cancelled, .expired, .interrupted:
            false
        }
    }
}

private struct DirectRequestMetadataRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "directRequestMetadata"

    let requestID: String
    let principalID: String
    let resourceID: String
    let specificationDigest: Data
    let modelID: String
    let modelRevision: String
    let state: String
    let processIncarnation: String
    let originalTimeoutMilliseconds: String
    let acceptedAt: Date
    let updatedAt: Date
    let terminalAt: Date?

    init(admission: DirectRequestAdmission, timestamp: Date) throws {
        requestID = admission.requestID.rawValue
        principalID = admission.principalID
        resourceID = admission.resourceID
        specificationDigest = admission.specificationDigest
        modelID = admission.modelID
        modelRevision = admission.modelRevision
        state = DirectRequestState.accepted.rawValue
        processIncarnation = admission.processIncarnation
        originalTimeoutMilliseconds = String(admission.originalTimeoutMilliseconds)
        acceptedAt = timestamp
        updatedAt = timestamp
        terminalAt = nil
    }

    func acceptance(for admission: DirectRequestAdmission) throws -> DirectRequestAcceptance {
        guard principalID == admission.principalID else {
            throw DirectRequestStoreError.accessDenied
        }
        guard immutableFieldsMatch(admission) else {
            throw DirectRequestStoreError.requestConflict
        }
        return .duplicate(try storedRequest())
    }

    func storedRequest() throws -> StoredDirectRequest {
        guard
            let requestID = RequestID(rawValue: requestID),
            let timeout = UInt64(originalTimeoutMilliseconds),
            let state = DirectRequestState(rawValue: state)
        else {
            throw DirectRequestStoreError.corruptData
        }
        let admission = try DirectRequestAdmission(
            principalID: principalID,
            requestID: requestID,
            resourceID: resourceID,
            specificationDigest: specificationDigest,
            modelID: modelID,
            modelRevision: modelRevision,
            processIncarnation: processIncarnation,
            originalTimeoutMilliseconds: timeout
        )
        return StoredDirectRequest(
            admission: admission,
            state: state,
            acceptedAt: acceptedAt,
            updatedAt: updatedAt
        )
    }

    private func immutableFieldsMatch(_ admission: DirectRequestAdmission) -> Bool {
        resourceID == admission.resourceID
            && specificationDigest == admission.specificationDigest
            && modelID == admission.modelID
            && modelRevision == admission.modelRevision
            && processIncarnation == admission.processIncarnation
            && originalTimeoutMilliseconds == String(admission.originalTimeoutMilliseconds)
    }
}
