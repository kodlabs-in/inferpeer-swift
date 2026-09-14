import Foundation
import InferPeerCore
import InferPeerProtocol

/// Creates and retains one stable device identity in an injected device-local secret store.
public actor DeviceIdentityManager {
    private let secretStore: any SecretStore
    private let configuration: DeviceIdentityConfiguration
    private let dateProvider: any SecurityDateProvider

    /// Creates a device identity manager without accessing storage until first use.
    public init(
        secretStore: any SecretStore,
        configuration: DeviceIdentityConfiguration = .standard,
        dateProvider: any SecurityDateProvider = SystemSecurityDateProvider()
    ) {
        self.secretStore = secretStore
        self.configuration = configuration
        self.dateProvider = dateProvider
    }

    /// Loads the existing identity or creates and durably saves one before returning it.
    public func credentials() throws -> DeviceCredentials {
        if let data = try secretStore.data(forKey: SecuritySecretKey.deviceCredentials) {
            return try restoredCredentials(from: data)
        }
        return try createCredentials(peerID: makePeerID())
    }

    /// Rotates the certificate and key while retaining the stable peer identifier.
    public func rotateCertificate() throws -> DeviceCredentials {
        let peerID: PeerID
        if let data = try secretStore.data(forKey: SecuritySecretKey.deviceCredentials) {
            peerID = try storedPeerID(from: data)
        } else {
            peerID = try makePeerID()
        }
        return try createCredentials(peerID: peerID)
    }

    /// Deletes this device's identity; the next load creates a new peer identifier.
    public func resetIdentity() throws {
        try secretStore.removeData(forKey: SecuritySecretKey.deviceCredentials)
    }

    private func createCredentials(peerID: PeerID) throws -> DeviceCredentials {
        let stored = try X509CredentialFactory.generate(
            peerID: peerID,
            at: dateProvider.now(),
            configuration: configuration
        )
        try secretStore.setData(
            DeviceCredentialCodec.encode(stored),
            forKey: SecuritySecretKey.deviceCredentials
        )
        return try X509CredentialFactory.restore(stored, at: dateProvider.now())
    }

    private func restoredCredentials(from data: Data) throws -> DeviceCredentials {
        try X509CredentialFactory.restore(
            DeviceCredentialCodec.decode(data),
            at: dateProvider.now()
        )
    }

    private func storedPeerID(from data: Data) throws -> PeerID {
        let stored = try DeviceCredentialCodec.decode(data)
        guard let peerID = PeerID(rawValue: stored.peerID) else {
            throw InferPeerSecurityError.corruptCredentials
        }
        return peerID
    }

    private func makePeerID() throws -> PeerID {
        guard let peerID = PeerID(rawValue: try SecureRandom.identifier(prefix: "peer-")) else {
            throw InferPeerSecurityError.certificateGenerationFailed
        }
        return peerID
    }
}
