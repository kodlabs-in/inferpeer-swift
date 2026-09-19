import Foundation

/// A malformed v2 direct-resource value rejected at the transport boundary.
public enum DirectWireMappingError: Error, Equatable, Sendable {
    /// A required string field was absent or invalid.
    case invalidIdentifier(String)

    /// A required enum field was unspecified or unknown.
    case invalidEnum(String)

    /// A model artifact identity was malformed.
    case invalidModel

    /// A telemetry measurement did not satisfy its domain invariants.
    case invalidTelemetry(String)

    /// A resource snapshot was structurally invalid.
    case invalidResource
}
