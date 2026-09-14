import Foundation
import InferPeerProtocol

/// The role a text message has in an ordered prompt.
public enum TextMessageRole: String, Sendable {
    /// Instructions that establish the assistant's behavior.
    case system

    /// Input supplied by the user.
    case user

    /// Prior output supplied by the assistant.
    case assistant
}

/// One nonempty message in a complete conversation snapshot.
public struct TextMessage: Hashable, Sendable {
    /// The message's role in the prompt.
    public let role: TextMessageRole

    /// The exact text supplied by the caller.
    public let text: String

    /// Creates a message without altering its text.
    public init(role: TextMessageRole, text: String) throws {
        guard !text.isEmpty else {
            throw InferenceValidationError.emptyMessage
        }
        self.role = role
        self.text = text
    }
}

/// An immutable, ordered context snapshot for one conversation revision.
public struct ConversationContext: Hashable, Sendable {
    /// The conversation to which this snapshot belongs.
    public let conversationID: ConversationID

    /// The caller-assigned revision of the complete context.
    public let revision: UInt64

    /// The ordered messages supplied to the model.
    public let messages: [TextMessage]

    /// Creates a complete context snapshot containing at least one message.
    public init(
        conversationID: ConversationID,
        revision: UInt64,
        messages: [TextMessage]
    ) throws {
        guard !messages.isEmpty else {
            throw InferenceValidationError.emptyConversation
        }
        self.conversationID = conversationID
        self.revision = revision
        self.messages = messages
    }
}

/// Optional controls for text generation.
public struct SamplingOptions: Hashable, Sendable {
    /// The default backend-selected sampling configuration.
    public static let `default` = SamplingOptions(
        validatedTemperature: nil,
        topP: nil,
        seed: nil
    )

    /// Sampling temperature, when explicitly supplied.
    public let temperature: Double?

    /// Nucleus-sampling probability, when explicitly supplied.
    public let topP: Double?

    /// Deterministic random seed, when explicitly supplied.
    public let seed: UInt64?

    /// Creates validated optional sampling controls.
    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        seed: UInt64? = nil
    ) throws {
        try Self.validateTemperature(temperature)
        try Self.validateTopP(topP)
        self.temperature = temperature
        self.topP = topP
        self.seed = seed
    }

    private init(validatedTemperature: Double?, topP: Double?, seed: UInt64?) {
        self.temperature = validatedTemperature
        self.topP = topP
        self.seed = seed
    }

    private static func validateTemperature(_ temperature: Double?) throws {
        guard let temperature else { return }
        guard temperature.isFinite, temperature >= 0 else {
            throw InferenceValidationError.invalidTemperature
        }
    }

    private static func validateTopP(_ topP: Double?) throws {
        guard let topP else { return }
        guard topP.isFinite, topP > 0, topP <= 1 else {
            throw InferenceValidationError.invalidTopP
        }
    }
}

/// A validated exact model or explicit model set accepted by the caller.
public struct ModelRequirement: Hashable, Sendable {
    /// The kind of model selection requested by the caller.
    public enum Selection: Hashable, Sendable {
        /// One exact model revision must be used.
        case exact(ModelReference)

        /// The scheduler may choose one revision from this nonempty ordered set.
        case permittedModels([ModelReference])
    }

    /// The validated selection.
    public let selection: Selection

    /// Requires one exact model revision.
    public static func exact(_ reference: ModelReference) -> Self {
        Self(selection: .exact(reference))
    }

    /// Allows the scheduler to choose from a nonempty ordered model set.
    public static func permitting(_ references: [ModelReference]) throws -> Self {
        guard !references.isEmpty else {
            throw InferenceValidationError.emptyPermittedModels
        }
        return Self(selection: .permittedModels(references))
    }

    private init(selection: Selection) {
        self.selection = selection
    }
}

/// Model and decoding options for one text generation.
public struct GenerationOptions: Hashable, Sendable {
    /// The exact model or explicit permitted model set.
    public let modelRequirement: ModelRequirement

    /// The caller's maximum generated token count.
    public let maximumOutputTokens: UInt32

    /// Optional sampling controls.
    public let sampling: SamplingOptions

    /// The request's absolute diagnostic deadline.
    public let deadline: Date?

    /// Creates validated generation options.
    public init(
        modelRequirement: ModelRequirement,
        maximumOutputTokens: UInt32,
        sampling: SamplingOptions = .default,
        deadline: Date? = nil
    ) throws {
        guard maximumOutputTokens > 0 else {
            throw InferenceValidationError.invalidMaximumOutputTokens
        }
        try Self.validateDeadline(deadline)
        self.modelRequirement = modelRequirement
        self.maximumOutputTokens = maximumOutputTokens
        self.sampling = sampling
        self.deadline = deadline
    }

    private static func validateDeadline(_ deadline: Date?) throws {
        guard let deadline else { return }
        let milliseconds = deadline.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
            milliseconds >= Double(Int64.min),
            milliseconds <= Double(Int64.max)
        else {
            throw InferenceValidationError.invalidDeadline
        }
    }
}

/// An immutable backend-neutral text generation request.
public struct TextGenerationRequest: Hashable, Sendable {
    /// The caller's complete context snapshot.
    public let context: ConversationContext

    /// Model and generation controls.
    public let options: GenerationOptions

    /// Workers explicitly allowed to receive the input; empty means no additional restriction.
    public let allowedWorkerIDs: Set<PeerID>

    /// Creates a request from independently validated values.
    public init(
        context: ConversationContext,
        options: GenerationOptions,
        allowedWorkerIDs: Set<PeerID> = []
    ) {
        self.context = context
        self.options = options
        self.allowedWorkerIDs = allowedWorkerIDs
    }
}
