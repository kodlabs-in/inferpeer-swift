import Foundation

/// Structural direct-query failures rejected before admission or transport.
public enum InferenceQueryValidationError: Error, Equatable, Sendable {
    case emptyInput
    case invalidGenerationOptions
    case invalidAsset
    case invalidOption
    case inputTooLarge
}

/// The complete inference operations understood by the direct-resource API.
public enum InferenceTask: String, CaseIterable, Codable, Hashable, Sendable {
    /// Generate text from an ordered conversation snapshot.
    case textGeneration

    /// Generate text from images and a prompt.
    case imageUnderstanding

    /// Transcribe an existing audio recording.
    case transcribe

    /// Synthesize audio from text.
    case synthesizeSpeech
}

/// The exact identity of a registered model artifact.
public typealias ModelKey = ModelReference

/// Model selection for one direct-resource request.
public enum InferenceModelSelection: Hashable, Sendable {
    /// Use exactly this registered artifact.
    case exact(ModelKey)

    /// Resolve the resource's configured default before admission.
    case taskDefault
}

/// One message in a complete text-generation context snapshot.
public struct InferenceMessage: Hashable, Sendable {
    /// The message's role in the conversation.
    public let role: TextMessageRole

    /// The message text, validated when the query is admitted.
    public let text: String

    /// Creates a message without changing its contents.
    public init(role: TextMessageRole, text: String) {
        self.role = role
        self.text = text
    }

    /// Creates a system instruction.
    public static func system(_ text: String) -> Self {
        Self(role: .system, text: text)
    }

    /// Creates a user message.
    public static func user(_ text: String) -> Self {
        Self(role: .user, text: text)
    }

    /// Creates an assistant message.
    public static func assistant(_ text: String) -> Self {
        Self(role: .assistant, text: text)
    }
}

/// Text-generation controls for the direct-resource API.
public struct TextQueryGenerationOptions: Hashable, Sendable {
    /// The default bounded generation configuration.
    public static let `default` = Self()

    /// Maximum tokens the selected runtime may generate.
    public let maxOutputTokens: UInt32

    /// Optional sampling temperature.
    public let temperature: Double?

    /// Optional nucleus-sampling probability.
    public let topP: Double?

    /// Optional deterministic seed.
    public let seed: UInt64?

    /// Creates controls that are validated before admission.
    public init(
        maxOutputTokens: UInt32 = GenerationOptions.defaultMaximumOutputTokens,
        temperature: Double? = nil,
        topP: Double? = nil,
        seed: UInt64? = nil
    ) {
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.topP = topP
        self.seed = seed
    }
}

/// A complete immutable text-generation query.
public struct TextInferenceQuery: Hashable, Sendable {
    /// Exact or configured-default model selection.
    public let model: InferenceModelSelection

    /// The complete ordered conversation context.
    public let messages: [InferenceMessage]

    /// Generation controls.
    public let generation: TextQueryGenerationOptions

    /// Creates a text query that is validated by the selected resource.
    public init(
        model: InferenceModelSelection,
        messages: [InferenceMessage],
        generation: TextQueryGenerationOptions = .default
    ) {
        self.model = model
        self.messages = messages
        self.generation = generation
    }
}

/// Opaque receipt returned after a remote resource verifies an uploaded asset.
public struct InferenceAssetReceipt: RawRepresentable, Hashable, Sendable {
    /// Opaque resource-issued receipt value.
    public let rawValue: String

    /// Restores an opaque receipt received from its issuing resource.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A local file or a resource-authorized remote asset receipt.
public enum InferenceAssetReference: Hashable, Sendable {
    case file(URL)
    case receipt(InferenceAssetReceipt)
}

/// A complete immutable image-understanding query.
public struct VisionInferenceQuery: Hashable, Sendable {
    /// Exact or configured-default vision model.
    public let model: InferenceModelSelection
    /// Complete ordered prompt snapshot.
    public let messages: [InferenceMessage]
    /// Authorized image inputs.
    public let images: [InferenceAssetReference]
    /// Bounded text-generation controls.
    public let generation: TextQueryGenerationOptions

    /// Creates an immutable image-understanding query.
    public init(
        model: InferenceModelSelection,
        messages: [InferenceMessage],
        images: [InferenceAssetReference],
        generation: TextQueryGenerationOptions = .default
    ) {
        self.model = model
        self.messages = messages
        self.images = images
        self.generation = generation
    }
}

/// Whether speech should be transcribed in-place or translated by a supporting model.
public enum TranscriptionMode: String, Hashable, Sendable {
    case transcription
    case translation
}

/// A complete immutable audio-transcription query.
public struct AudioTranscriptionQuery: Hashable, Sendable {
    /// Exact or configured-default ASR model.
    public let model: InferenceModelSelection
    /// Authorized existing audio input.
    public let audio: InferenceAssetReference
    /// Optional explicitly requested language.
    public let language: String?
    /// Transcription or translation operation.
    public let mode: TranscriptionMode

    /// Creates an immutable existing-audio transcription query.
    public init(
        model: InferenceModelSelection,
        audio: InferenceAssetReference,
        language: String? = nil,
        mode: TranscriptionMode = .transcription
    ) {
        self.model = model
        self.audio = audio
        self.language = language
        self.mode = mode
    }
}

/// A complete immutable speech-synthesis query.
public struct SpeechSynthesisQuery: Hashable, Sendable {
    /// Exact or configured-default speech model.
    public let model: InferenceModelSelection
    /// Exact installed voice identity.
    public let voiceID: String
    /// Complete bounded synthesis text.
    public let text: String
    /// Optional explicitly requested speaking-rate multiplier.
    public let rate: Double?

    /// Creates an immutable speech-synthesis query.
    public init(
        model: InferenceModelSelection,
        voiceID: String,
        text: String,
        rate: Double? = nil
    ) {
        self.model = model
        self.voiceID = voiceID
        self.text = text
        self.rate = rate
    }
}

/// A typed request executed wholly on one selected resource.
public enum InferenceQuery: Hashable, Sendable {
    /// Text generation from a complete context snapshot.
    case text(TextInferenceQuery)

    /// Image understanding using exact image assets and a complete prompt snapshot.
    case vision(VisionInferenceQuery)

    /// Transcription of an existing audio asset. InferPeer never activates a microphone.
    case audioTranscription(AudioTranscriptionQuery)

    /// Speech synthesis without taking ownership of playback or the audio session.
    case speechSynthesis(SpeechSynthesisQuery)

    /// Creates a text-generation query.
    public static func text(
        model: InferenceModelSelection,
        messages: [InferenceMessage],
        generation: TextQueryGenerationOptions = .default
    ) -> Self {
        .text(
            TextInferenceQuery(
                model: model,
                messages: messages,
                generation: generation
            )
        )
    }

    /// Creates an image-understanding query.
    public static func vision(
        model: InferenceModelSelection,
        messages: [InferenceMessage],
        images: [InferenceAssetReference],
        generation: TextQueryGenerationOptions = .default
    ) -> Self {
        .vision(
            VisionInferenceQuery(
                model: model,
                messages: messages,
                images: images,
                generation: generation
            )
        )
    }

    /// Creates an existing-audio transcription or translation query.
    public static func transcribe(
        model: InferenceModelSelection,
        audio: InferenceAssetReference,
        language: String? = nil,
        mode: TranscriptionMode = .transcription
    ) -> Self {
        .audioTranscription(
            AudioTranscriptionQuery(
                model: model,
                audio: audio,
                language: language,
                mode: mode
            )
        )
    }

    /// Creates a speech-synthesis query without taking playback ownership.
    public static func synthesizeSpeech(
        model: InferenceModelSelection,
        voiceID: String,
        text: String,
        rate: Double? = nil
    ) -> Self {
        .speechSynthesis(
            SpeechSynthesisQuery(
                model: model,
                voiceID: voiceID,
                text: text,
                rate: rate
            )
        )
    }

    /// The operation required by this query.
    public var task: InferenceTask {
        switch self {
        case .text:
            .textGeneration
        case .vision:
            .imageUnderstanding
        case .audioTranscription:
            .transcribe
        case .speechSynthesis:
            .synthesizeSpeech
        }
    }

    /// The exact or task-default model selection frozen into this query.
    public var modelSelection: InferenceModelSelection {
        switch self {
        case .text(let query):
            query.model
        case .vision(let query):
            query.model
        case .audioTranscription(let query):
            query.model
        case .speechSynthesis(let query):
            query.model
        }
    }

}
