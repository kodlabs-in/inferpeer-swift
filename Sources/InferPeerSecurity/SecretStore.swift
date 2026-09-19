import Foundation

/// Device-local secret persistence used for identities and pairing authority state.
public protocol SecretStore: Sendable {
    /// Loads bytes for an exact logical key, or `nil` when absent.
    func data(forKey key: String) throws -> Data?

    /// Atomically adds or replaces bytes for an exact logical key.
    func setData(_ data: Data, forKey key: String) throws

    /// Removes bytes for an exact logical key when present.
    func removeData(forKey key: String) throws

    /// Atomically removes bytes only when they still equal the expected value.
    ///
    /// This operation lets multiple authority instances safely consume the same
    /// single-use record without a read-then-delete race.
    func removeData(forKey key: String, ifEqualTo expectedData: Data) throws -> Bool
}

public extension SecretStore {
    /// Provides process-wide atomicity for stores that do not supply a stronger implementation.
    func removeData(forKey key: String, ifEqualTo expectedData: Data) throws -> Bool {
        try SecretStoreAtomicity.lock.withLock {
            guard try data(forKey: key) == expectedData else { return false }
            try removeData(forKey: key)
            return true
        }
    }
}

private enum SecretStoreAtomicity {
    static let lock = NSLock()
}

enum SecuritySecretKey {
    static let deviceCredentials = "device-credentials-v1"
    static let pairingAuthority = "pairing-authority-v1"
    static let directPairingAuthority = "direct-pairing-authority-v1"
    static let directResourceCredentials = "direct-resource-access-v1"

    static func invitation(_ invitationID: String) -> String {
        "pairing-invitation-v1.\(invitationID)"
    }

    static func directInvitation(_ invitationID: String) -> String {
        "direct-pairing-invitation-v1.\(invitationID)"
    }
}
