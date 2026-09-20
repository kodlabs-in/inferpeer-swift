extension InferenceQuery {
    /// Initial protocol-wide maximum output-token request.
    public static let maximumOutputTokens: UInt32 = 16_384

    /// Maximum image references accepted by the generic v2 contract.
    public static let maximumImageCount = 8

    /// Maximum Unicode scalar count accepted by speech synthesis.
    public static let maximumSpeechTextScalars = 8_000

    /// Validates transport-independent v2 bounds without loading media or a model.
    public func validate() throws {
        switch self {
        case .text(let query):
            try Self.validateMessages(query.messages)
            try Self.validateGeneration(query.generation)
        case .vision(let query):
            try Self.validateVision(query)
        case .audioTranscription(let query):
            try Self.validateTranscription(query)
        case .speechSynthesis(let query):
            try Self.validateSpeech(query)
        }
    }

    private static func validateVision(_ query: VisionInferenceQuery) throws {
        try validateMessages(query.messages)
        try validateGeneration(query.generation)
        guard !query.images.isEmpty else {
            throw InferenceQueryValidationError.emptyInput
        }
        guard query.images.count <= maximumImageCount else {
            throw InferenceQueryValidationError.inputTooLarge
        }
        try query.images.forEach(validateAsset)
    }

    private static func validateTranscription(_ query: AudioTranscriptionQuery) throws {
        try validateAsset(query.audio)
        if let language = query.language, language.isEmpty {
            throw InferenceQueryValidationError.invalidOption
        }
    }

    private static func validateSpeech(_ query: SpeechSynthesisQuery) throws {
        guard !query.text.isEmpty, !query.voiceID.isEmpty else {
            throw InferenceQueryValidationError.emptyInput
        }
        guard query.text.unicodeScalars.count <= maximumSpeechTextScalars else {
            throw InferenceQueryValidationError.inputTooLarge
        }
        if let rate = query.rate, !rate.isFinite || rate <= 0 {
            throw InferenceQueryValidationError.invalidOption
        }
    }

    private static func validateMessages(_ messages: [InferenceMessage]) throws {
        guard !messages.isEmpty, messages.allSatisfy({ !$0.text.isEmpty }) else {
            throw InferenceQueryValidationError.emptyInput
        }
    }

    private static func validateGeneration(_ generation: TextQueryGenerationOptions) throws {
        guard (1...maximumOutputTokens).contains(generation.maxOutputTokens) else {
            throw InferenceQueryValidationError.invalidGenerationOptions
        }
        if let temperature = generation.temperature,
            !temperature.isFinite || temperature < 0
        {
            throw InferenceQueryValidationError.invalidGenerationOptions
        }
        if let topP = generation.topP,
            !topP.isFinite || topP <= 0 || topP > 1
        {
            throw InferenceQueryValidationError.invalidGenerationOptions
        }
    }

    private static func validateAsset(_ asset: InferenceAssetReference) throws {
        switch asset {
        case .file(let url):
            guard url.isFileURL else {
                throw InferenceQueryValidationError.invalidAsset
            }
        case .receipt(let receipt):
            guard !receipt.rawValue.isEmpty else {
                throw InferenceQueryValidationError.invalidAsset
            }
        }
    }
}
