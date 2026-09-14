/// A security operation that failed without exposing credential contents.
public enum InferPeerSecurityError: Error, Equatable, Sendable {
    /// A public configuration value is empty or outside its supported range.
    case invalidConfiguration

    /// A secret-store key is empty.
    case invalidSecretKey

    /// Apple Keychain returned an operating-system status code.
    case keychainFailure(status: Int32)

    /// Keychain returned an unexpected value type.
    case invalidKeychainResult

    /// Stored device identity material is missing fields, malformed, or inconsistent.
    case corruptCredentials

    /// A new X.509 identity certificate could not be created.
    case certificateGenerationFailed

    /// Certificate bytes do not contain a supported InferPeer identity certificate.
    case invalidCertificate

    /// A certificate is not valid at the supplied wall-clock time.
    case certificateNotCurrentlyValid

    /// A certificate fingerprint differs from an explicitly pinned fingerprint.
    case certificateFingerprintMismatch

    /// A stored private key does not belong to its stored certificate.
    case privateKeyMismatch

    /// Pairing invitation bytes exceed the configured bound or fail strict decoding.
    case invalidInvitationEncoding

    /// The invitation was not issued here or was consumed already.
    case invitationUnknownOrConsumed

    /// The invitation has passed its expiry time.
    case invitationExpired

    /// The invitation proof is invalid or its claims differ from the issued invitation.
    case invalidInvitationProof

    /// Pairing authority state is missing or malformed.
    case corruptPairingState
}
