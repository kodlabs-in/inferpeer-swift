import Foundation
import InferPeerCore

/// Validated lifetime settings for a device-local X.509 identity.
public struct DeviceIdentityConfiguration: Equatable, Sendable {
    /// A one-year certificate with five minutes of clock-skew tolerance.
    public static let standard = Self(
        validatedCertificateValidity: 365 * 24 * 60 * 60,
        clockSkewTolerance: 5 * 60
    )

    /// Number of seconds for which a newly issued certificate remains valid.
    public let certificateValidity: TimeInterval

    /// Backdating applied to tolerate small peer wall-clock differences.
    public let clockSkewTolerance: TimeInterval

    /// Creates validated device identity settings.
    public init(
        certificateValidity: TimeInterval,
        clockSkewTolerance: TimeInterval
    ) throws {
        guard certificateValidity.isFinite, certificateValidity > 0 else {
            throw InferPeerSecurityError.invalidConfiguration
        }
        guard clockSkewTolerance.isFinite, clockSkewTolerance >= 0 else {
            throw InferPeerSecurityError.invalidConfiguration
        }
        self.certificateValidity = certificateValidity
        self.clockSkewTolerance = clockSkewTolerance
    }

    private init(
        validatedCertificateValidity: TimeInterval,
        clockSkewTolerance: TimeInterval
    ) {
        certificateValidity = validatedCertificateValidity
        self.clockSkewTolerance = clockSkewTolerance
    }
}

/// Validated limits for short-lived, single-use pairing invitations.
public struct PairingConfiguration: Equatable, Sendable {
    /// A five-minute invitation bounded to four KiB when encoded.
    public static let standard = Self(
        validatedInvitationValidity: 5 * 60,
        maximumEncodedInvitationBytes: 4 * 1_024
    )

    /// Number of seconds for which a new invitation can be consumed.
    public let invitationValidity: TimeInterval

    /// Maximum accepted serialized invitation size.
    public let maximumEncodedInvitationBytes: Int

    /// Creates validated pairing settings.
    public init(
        invitationValidity: TimeInterval,
        maximumEncodedInvitationBytes: Int
    ) throws {
        guard invitationValidity.isFinite, invitationValidity > 0 else {
            throw InferPeerSecurityError.invalidConfiguration
        }
        guard maximumEncodedInvitationBytes > 0 else {
            throw InferPeerSecurityError.invalidConfiguration
        }
        self.invitationValidity = invitationValidity
        self.maximumEncodedInvitationBytes = maximumEncodedInvitationBytes
    }

    private init(
        validatedInvitationValidity: TimeInterval,
        maximumEncodedInvitationBytes: Int
    ) {
        invitationValidity = validatedInvitationValidity
        self.maximumEncodedInvitationBytes = maximumEncodedInvitationBytes
    }
}

/// Supplies deterministic wall-clock timestamps to security policies.
public protocol SecurityDateProvider: Sendable {
    /// Returns the current wall-clock time.
    func now() -> Date
}

/// The production system wall clock.
public struct SystemSecurityDateProvider: SecurityDateProvider, Sendable {
    /// Creates a system date provider.
    public init() {}

    /// Returns the current wall-clock time.
    public func now() -> Date {
        Date()
    }
}

/// Validates the roles granted when a host explicitly approves a peer.
struct PeerApprovalConfiguration: Sendable {
    let roles: Set<NodeRole>

    init(roles: Set<NodeRole>) throws {
        guard !roles.isEmpty else {
            throw InferPeerSecurityError.invalidConfiguration
        }
        self.roles = roles
    }
}
