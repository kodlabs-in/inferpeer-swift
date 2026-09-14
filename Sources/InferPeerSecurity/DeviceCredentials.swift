import Crypto
import Foundation
import InferPeerCore
import InferPeerProtocol
import Security
import X509

/// Exportable identity material consumed by the future mutual-TLS transport adapter.
public struct DeviceCredentials: Hashable, Sendable {
    /// The stable device identity and current certificate pin.
    public let identity: LocalPeerIdentity

    /// The self-signed leaf certificate encoded as X.509 DER.
    public let certificateDER: Data

    /// The matching P-256 private key encoded as DER.
    public let privateKeyDER: Data

    /// The first time at which the certificate is valid.
    public let notValidBefore: Date

    /// The time after which the certificate must not be accepted.
    public let notValidAfter: Date
}

struct StoredDeviceCredentials: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let peerID: String
    let privateKeyRawRepresentation: Data
    let certificateDER: Data
}

enum DeviceCredentialCodec {
    static func encode(_ credentials: StoredDeviceCredentials) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(credentials)
    }

    static func decode(_ data: Data) throws -> StoredDeviceCredentials {
        do {
            let credentials = try JSONDecoder().decode(StoredDeviceCredentials.self, from: data)
            guard credentials.version == StoredDeviceCredentials.currentVersion else {
                throw InferPeerSecurityError.corruptCredentials
            }
            return credentials
        } catch let error as InferPeerSecurityError {
            throw error
        } catch {
            throw InferPeerSecurityError.corruptCredentials
        }
    }
}

enum X509CredentialFactory {
    static func generate(
        peerID: PeerID,
        at date: Date,
        configuration: DeviceIdentityConfiguration
    ) throws -> StoredDeviceCredentials {
        do {
            let privateKey = P256.Signing.PrivateKey()
            let certificate = try makeCertificate(
                peerID: peerID,
                privateKey: privateKey,
                at: date,
                configuration: configuration
            )
            return StoredDeviceCredentials(
                version: StoredDeviceCredentials.currentVersion,
                peerID: peerID.rawValue,
                privateKeyRawRepresentation: privateKey.rawRepresentation,
                certificateDER: try derRepresentation(of: certificate)
            )
        } catch let error as InferPeerSecurityError {
            throw error
        } catch {
            throw InferPeerSecurityError.certificateGenerationFailed
        }
    }

    static func restore(
        _ stored: StoredDeviceCredentials,
        at date: Date
    ) throws -> DeviceCredentials {
        do {
            guard let storedPeerID = PeerID(rawValue: stored.peerID) else {
                throw InferPeerSecurityError.corruptCredentials
            }
            let privateKey = try P256.Signing.PrivateKey(
                rawRepresentation: stored.privateKeyRawRepresentation
            )
            let verifier = CertificateIdentityVerifier()
            let presentedIdentity = try verifier.verify(
                certificateDER: stored.certificateDER,
                at: date
            )
            guard presentedIdentity.peerID == storedPeerID else {
                throw InferPeerSecurityError.corruptCredentials
            }
            try validatePrivateKey(privateKey, certificateDER: stored.certificateDER)
            return DeviceCredentials(
                identity: LocalPeerIdentity(
                    peerID: storedPeerID,
                    certificateFingerprint: presentedIdentity.certificateFingerprint
                ),
                certificateDER: stored.certificateDER,
                privateKeyDER: privateKey.derRepresentation,
                notValidBefore: try certificate(stored.certificateDER).notValidBefore,
                notValidAfter: try certificate(stored.certificateDER).notValidAfter
            )
        } catch let error as InferPeerSecurityError {
            throw error
        } catch {
            throw InferPeerSecurityError.corruptCredentials
        }
    }

    private static func makeCertificate(
        peerID: PeerID,
        privateKey: P256.Signing.PrivateKey,
        at date: Date,
        configuration: DeviceIdentityConfiguration
    ) throws -> Certificate {
        let certificateKey = Certificate.PrivateKey(privateKey)
        let name = try DistinguishedName {
            OrganizationName("InferPeer")
            CommonName(peerID.rawValue)
        }
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
            try ExtendedKeyUsage([.serverAuth, .clientAuth])
            SubjectAlternativeNames([
                .uniformResourceIdentifier("urn:inferpeer:peer:\(peerID.rawValue)")
            ])
        }
        return try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: certificateKey.publicKey,
            notValidBefore: date.addingTimeInterval(-configuration.clockSkewTolerance),
            notValidAfter: date.addingTimeInterval(configuration.certificateValidity),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: certificateKey
        )
    }

    private static func derRepresentation(of certificate: Certificate) throws -> Data {
        let securityCertificate = try SecCertificate.makeWithCertificate(certificate)
        return SecCertificateCopyData(securityCertificate) as Data
    }

    private static func certificate(_ data: Data) throws -> Certificate {
        guard let securityCertificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw InferPeerSecurityError.corruptCredentials
        }
        return try Certificate(securityCertificate)
    }

    private static func validatePrivateKey(
        _ privateKey: P256.Signing.PrivateKey,
        certificateDER: Data
    ) throws {
        let storedPublicKey = try certificate(certificateDER).publicKey
        guard storedPublicKey == Certificate.PublicKey(privateKey.publicKey) else {
            throw InferPeerSecurityError.privateKeyMismatch
        }
    }
}
