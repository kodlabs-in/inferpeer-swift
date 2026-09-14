import Foundation

/// Device-local secret persistence used for identities and pairing authority state.
public protocol SecretStore: Sendable {
    /// Loads bytes for an exact logical key, or `nil` when absent.
    func data(forKey key: String) throws -> Data?

    /// Atomically adds or replaces bytes for an exact logical key.
    func setData(_ data: Data, forKey key: String) throws

    /// Removes bytes for an exact logical key when present.
    func removeData(forKey key: String) throws
}

enum SecuritySecretKey {
    static let deviceCredentials = "device-credentials-v1"
    static let pairingAuthority = "pairing-authority-v1"

    static func invitation(_ invitationID: String) -> String {
        "pairing-invitation-v1.\(invitationID)"
    }
}
