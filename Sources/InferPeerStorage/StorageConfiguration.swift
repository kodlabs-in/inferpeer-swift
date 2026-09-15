import Foundation

/// Validated SQLite durability, concurrency, replay, and quota settings.
public struct SQLiteStorageConfiguration: Equatable, Sendable {
    /// The proposed demo configuration from the product requirements.
    public static let standard = Self(
        validatedMaximumDatabaseBytes: 256 * 1_024 * 1_024,
        maximumReplayPageSize: 1_000,
        maximumOutboxBatchSize: 100,
        maximumPendingRequests: 100,
        maximumPendingRequestsPerCaller: 10,
        terminalRetention: 24 * 60 * 60,
        busyTimeout: 5,
        maximumReaderCount: 5
    )

    /// Maximum logical SQLite page usage before a write is rolled back.
    public let maximumDatabaseBytes: UInt64

    /// Maximum number of replay events returned by one query.
    public let maximumReplayPageSize: Int

    /// Maximum number of pending outbox requests returned by one query.
    public let maximumOutboxBatchSize: Int

    /// Maximum nonterminal requests retained cluster-wide.
    public let maximumPendingRequests: Int

    /// Maximum nonterminal requests owned by one caller.
    public let maximumPendingRequestsPerCaller: Int

    /// Duration for which terminal request data remains replayable.
    public let terminalRetention: TimeInterval

    /// Time SQLite waits for a transient lock before failing.
    public let busyTimeout: TimeInterval

    /// Maximum number of concurrent pool readers.
    public let maximumReaderCount: Int

    /// Creates validated storage settings.
    public init(
        maximumDatabaseBytes: UInt64,
        maximumReplayPageSize: Int,
        maximumOutboxBatchSize: Int = 100,
        maximumPendingRequests: Int = 100,
        maximumPendingRequestsPerCaller: Int = 10,
        terminalRetention: TimeInterval = 24 * 60 * 60,
        busyTimeout: TimeInterval,
        maximumReaderCount: Int
    ) throws {
        guard maximumDatabaseBytes > 0 else {
            throw SQLiteStorageError.invalidConfiguration
        }
        guard maximumReplayPageSize > 0,
            maximumOutboxBatchSize > 0,
            maximumPendingRequests > 0,
            maximumPendingRequestsPerCaller > 0,
            maximumReaderCount > 0
        else {
            throw SQLiteStorageError.invalidConfiguration
        }
        guard busyTimeout.isFinite, busyTimeout >= 0,
            terminalRetention.isFinite, terminalRetention > 0
        else {
            throw SQLiteStorageError.invalidConfiguration
        }
        self.init(
            validatedMaximumDatabaseBytes: maximumDatabaseBytes,
            maximumReplayPageSize: maximumReplayPageSize,
            maximumOutboxBatchSize: maximumOutboxBatchSize,
            maximumPendingRequests: maximumPendingRequests,
            maximumPendingRequestsPerCaller: maximumPendingRequestsPerCaller,
            terminalRetention: terminalRetention,
            busyTimeout: busyTimeout,
            maximumReaderCount: maximumReaderCount
        )
    }

    private init(
        validatedMaximumDatabaseBytes: UInt64,
        maximumReplayPageSize: Int,
        maximumOutboxBatchSize: Int,
        maximumPendingRequests: Int,
        maximumPendingRequestsPerCaller: Int,
        terminalRetention: TimeInterval,
        busyTimeout: TimeInterval,
        maximumReaderCount: Int
    ) {
        maximumDatabaseBytes = validatedMaximumDatabaseBytes
        self.maximumReplayPageSize = maximumReplayPageSize
        self.maximumOutboxBatchSize = maximumOutboxBatchSize
        self.maximumPendingRequests = maximumPendingRequests
        self.maximumPendingRequestsPerCaller = maximumPendingRequestsPerCaller
        self.terminalRetention = terminalRetention
        self.busyTimeout = busyTimeout
        self.maximumReaderCount = maximumReaderCount
    }
}

/// Supplies deterministic wall-clock timestamps for durable records.
public protocol StorageDateProvider: Sendable {
    /// Returns the current diagnostic wall-clock time.
    func now() -> Date
}

/// The system wall clock used by production storage.
public struct SystemStorageDateProvider: StorageDateProvider, Sendable {
    /// Creates a system date provider.
    public init() {}

    /// Returns the current system date.
    public func now() -> Date {
        Date()
    }
}
