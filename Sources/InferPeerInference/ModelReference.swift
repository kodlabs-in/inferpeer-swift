import InferPeerProtocol

/// An exact, immutable model revision.
public struct ModelReference: Hashable, Sendable {
    /// The maximum UTF-8 length accepted for a model revision.
    public static let maximumRevisionUTF8Length = 128

    /// The stable model identifier.
    public let modelID: ModelID

    /// The exact content revision required for execution.
    public let revision: String

    /// Creates a reference to one exact model revision.
    public init(modelID: ModelID, revision: String) throws {
        guard Self.isValidRevision(revision) else {
            throw InferenceValidationError.invalidModelRevision
        }
        self.modelID = modelID
        self.revision = revision
    }

    private static func isValidRevision(_ revision: String) -> Bool {
        guard !revision.isEmpty else { return false }
        guard revision.utf8.count <= maximumRevisionUTF8Length else { return false }
        return revision.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }
}
