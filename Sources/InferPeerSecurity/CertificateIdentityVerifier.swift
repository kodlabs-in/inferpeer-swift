import Crypto
import Foundation
import InferPeerCore
import InferPeerProtocol
import Security
import X509

/// Parses and validates the self-signed identity certificates used for pinned mutual TLS.
public struct CertificateIdentityVerifier: Sendable {
    /// Creates an identity-certificate verifier.
    public init() {}

    /// Validates certificate structure, purpose, validity, identity binding, and an optional pin.
    public func verify(
        certificateDER: Data,
        expectedFingerprint: CertificateFingerprint? = nil,
        at date: Date = Date()
    ) throws -> PresentedPeerIdentity {
        do {
            return try verifiedIdentity(
                certificateDER: certificateDER,
                expectedFingerprint: expectedFingerprint,
                at: date
            )
        } catch let error as InferPeerSecurityError {
            throw error
        } catch {
            throw InferPeerSecurityError.invalidCertificate
        }
    }

    private func verifiedIdentity(
        certificateDER: Data,
        expectedFingerprint: CertificateFingerprint?,
        at date: Date
    ) throws -> PresentedPeerIdentity {
        let certificate = try parseCertificate(certificateDER)
        let fingerprint = try certificateFingerprint(for: certificateDER)
        try validateFingerprint(fingerprint, expected: expectedFingerprint)
        try validateIntegrity(certificate, at: date)
        let peerID = try peerID(from: certificateDER)
        try validateExtensions(certificate, peerID: peerID)
        return PresentedPeerIdentity(peerID: peerID, certificateFingerprint: fingerprint)
    }

    private func parseCertificate(_ data: Data) throws -> Certificate {
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw InferPeerSecurityError.invalidCertificate
        }
        return try Certificate(certificate)
    }

    private func certificateFingerprint(for data: Data) throws -> CertificateFingerprint {
        try CertificateFingerprint(bytes: Data(SHA256.hash(data: data)))
    }

    private func validateFingerprint(
        _ actual: CertificateFingerprint,
        expected: CertificateFingerprint?
    ) throws {
        guard expected == nil || expected == actual else {
            throw InferPeerSecurityError.certificateFingerprintMismatch
        }
    }

    private func validateIntegrity(_ certificate: Certificate, at date: Date) throws {
        guard date >= certificate.notValidBefore, date <= certificate.notValidAfter else {
            throw InferPeerSecurityError.certificateNotCurrentlyValid
        }
        guard certificate.subject == certificate.issuer else {
            throw InferPeerSecurityError.invalidCertificate
        }
        guard certificate.publicKey.isValidSignature(certificate.signature, for: certificate) else {
            throw InferPeerSecurityError.invalidCertificate
        }
    }

    private func peerID(from certificateDER: Data) throws -> PeerID {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw InferPeerSecurityError.invalidCertificate
        }
        var commonName: CFString?
        guard SecCertificateCopyCommonName(certificate, &commonName) == errSecSuccess,
            let commonName,
            let peerID = PeerID(rawValue: commonName as String)
        else {
            throw InferPeerSecurityError.invalidCertificate
        }
        return peerID
    }

    private func validateExtensions(_ certificate: Certificate, peerID: PeerID) throws {
        let expectedURI = GeneralName.uniformResourceIdentifier(
            "urn:inferpeer:peer:\(peerID.rawValue)"
        )
        guard try certificate.extensions.subjectAlternativeNames?.contains(expectedURI) == true
        else {
            throw InferPeerSecurityError.invalidCertificate
        }
        guard try certificate.extensions.basicConstraints == .notCertificateAuthority else {
            throw InferPeerSecurityError.invalidCertificate
        }
        guard try certificate.extensions.keyUsage?.digitalSignature == true else {
            throw InferPeerSecurityError.invalidCertificate
        }
        let usages = try certificate.extensions.extendedKeyUsage
        guard usages?.contains(.clientAuth) == true, usages?.contains(.serverAuth) == true else {
            throw InferPeerSecurityError.invalidCertificate
        }
    }
}
