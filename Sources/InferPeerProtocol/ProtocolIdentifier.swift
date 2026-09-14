/// A validated, strongly typed identifier carried by the InferPeer protocol.
public struct ProtocolIdentifier<Domain>:
    RawRepresentable,
    Hashable,
    Codable,
    Sendable,
    CustomStringConvertible
{
    /// The maximum UTF-8 length accepted for an identifier.
    public static var maximumUTF8Length: Int { 128 }

    /// The identifier's wire representation.
    public let rawValue: String

    /// Creates an identifier when `rawValue` is nonempty printable ASCII and at most 128 bytes.
    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// Decodes an identifier from its single string value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let identifier = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid InferPeer protocol identifier"
            )
        }
        self = identifier
    }

    /// Encodes the identifier as its single string value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The identifier's wire representation.
    public var description: String { rawValue }

    private static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        guard value.utf8.count <= maximumUTF8Length else { return false }
        return value.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }
}

/// Type domain for cluster identifiers.
public enum ClusterIdentifierDomain: Sendable {}

/// Type domain for peer identifiers.
public enum PeerIdentifierDomain: Sendable {}

/// Type domain for protocol message identifiers.
public enum MessageIdentifierDomain: Sendable {}

/// Type domain for inference request identifiers.
public enum RequestIdentifierDomain: Sendable {}

/// Type domain for execution attempt identifiers.
public enum AttemptIdentifierDomain: Sendable {}

/// Type domain for conversation identifiers.
public enum ConversationIdentifierDomain: Sendable {}

/// Type domain for coordinator incarnation identifiers.
public enum CoordinatorIncarnationIdentifierDomain: Sendable {}

/// Type domain for model identifiers.
public enum ModelIdentifierDomain: Sendable {}

/// Type domain for pairing invitation identifiers.
public enum InvitationIdentifierDomain: Sendable {}

/// A cluster identifier.
public typealias ClusterID = ProtocolIdentifier<ClusterIdentifierDomain>

/// An authenticated peer identifier.
public typealias PeerID = ProtocolIdentifier<PeerIdentifierDomain>

/// A unique wire-message identifier.
public typealias MessageID = ProtocolIdentifier<MessageIdentifierDomain>

/// A stable logical request identifier.
public typealias RequestID = ProtocolIdentifier<RequestIdentifierDomain>

/// A single execution-attempt identifier.
public typealias AttemptID = ProtocolIdentifier<AttemptIdentifierDomain>

/// A conversation identifier.
public typealias ConversationID = ProtocolIdentifier<ConversationIdentifierDomain>

/// A coordinator-process incarnation identifier.
public typealias CoordinatorIncarnationID =
    ProtocolIdentifier<CoordinatorIncarnationIdentifierDomain>

/// A registered model identifier.
public typealias ModelID = ProtocolIdentifier<ModelIdentifierDomain>

/// A single-use pairing invitation identifier.
public typealias InvitationID = ProtocolIdentifier<InvitationIdentifierDomain>
