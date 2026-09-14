/// A SQLite adapter failure that is not already represented by `RequestPersistenceError`.
public enum SQLiteStorageError: Error, Equatable, Sendable {
    /// The supplied database URL was not a file URL.
    case invalidDatabaseURL

    /// A storage configuration value was outside its supported range.
    case invalidConfiguration

    /// Durable bytes or columns could not be decoded into valid domain state.
    case corruptData

    /// A replay page limit was zero, negative, or above the configured maximum.
    case invalidReplayLimit

    /// An outbox batch limit was zero, negative, or above the configured maximum.
    case invalidOutboxLimit

    /// A durable cursor exceeded SQLite's signed integer range.
    case cursorOutOfRange

    /// A request revision exhausted SQLite's signed integer range.
    case revisionExhausted

    /// A peer was approved without any enabled role.
    case emptyPeerRoles

    /// A peer identifier was reused with a different certificate identity.
    case peerIdentityConflict

    /// An exact model identifier was reused with different immutable metadata or files.
    case modelRegistrationConflict

    /// The requested peer membership does not exist.
    case peerNotFound

    /// SQLite failed for a reason that is not safe to expose publicly.
    case databaseFailure
}
