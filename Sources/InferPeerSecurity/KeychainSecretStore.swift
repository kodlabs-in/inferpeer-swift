import Foundation
import Security

/// The device-bound accessibility policy for InferPeer Keychain items.
public enum KeychainAccessibility: Sendable {
    /// Secrets are available only while the device is unlocked.
    case whenUnlockedThisDeviceOnly

    /// Secrets remain available after the first unlock until the next restart.
    case afterFirstUnlockThisDeviceOnly

    var securityValue: CFString {
        switch self {
        case .whenUnlockedThisDeviceOnly:
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .afterFirstUnlockThisDeviceOnly:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }
}

/// Non-synchronizing Apple Keychain storage using the data-protection keychain.
public struct KeychainSecretStore: SecretStore, Sendable {
    private let service: String
    private let accessGroup: String?
    private let accessibility: KeychainAccessibility

    /// Creates an isolated Keychain namespace for one host application.
    public init(
        service: String,
        accessGroup: String? = nil,
        accessibility: KeychainAccessibility = .whenUnlockedThisDeviceOnly
    ) throws {
        guard !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InferPeerSecurityError.invalidConfiguration
        }
        if let accessGroup,
            accessGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw InferPeerSecurityError.invalidConfiguration
        }
        self.service = service
        self.accessGroup = accessGroup
        self.accessibility = accessibility
    }

    /// Loads one exact, non-synchronizing generic-password item.
    public func data(forKey key: String) throws -> Data? {
        var query = try baseQuery(forKey: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        try requireSuccess(status)
        guard let data = result as? Data else {
            throw InferPeerSecurityError.invalidKeychainResult
        }
        return data
    }

    /// Adds or replaces one exact, non-synchronizing generic-password item.
    public func setData(_ data: Data, forKey key: String) throws {
        let query = try baseQuery(forKey: key)
        var attributes = query
        attributes[kSecAttrAccessible as String] = accessibility.securityValue
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecDuplicateItem else {
            try requireSuccess(status)
            return
        }
        let update = [kSecValueData as String: data]
        try requireSuccess(SecItemUpdate(query as CFDictionary, update as CFDictionary))
    }

    /// Removes one exact item; absence is already the desired state.
    public func removeData(forKey key: String) throws {
        let status = SecItemDelete(try baseQuery(forKey: key) as CFDictionary)
        guard status != errSecItemNotFound else { return }
        try requireSuccess(status)
    }

    private func baseQuery(forKey key: String) throws -> [String: Any] {
        guard !key.isEmpty else {
            throw InferPeerSecurityError.invalidSecretKey
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func requireSuccess(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw InferPeerSecurityError.keychainFailure(status: status)
        }
    }
}
