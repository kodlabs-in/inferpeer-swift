import Foundation
import InferPeerProtocol

extension ModelReference {
    /// Creates a validated model reference from its protocol representation.
    public init(wireValue: InferPeer_V1_ModelReference) throws {
        guard let modelID = ModelID(rawValue: wireValue.modelID) else {
            throw InferenceValidationError.invalidWireValue(field: .modelID)
        }
        try self.init(modelID: modelID, revision: wireValue.revision)
    }

    /// The protocol representation of this model reference.
    public var wireValue: InferPeer_V1_ModelReference {
        InferPeer_V1_ModelReference.with {
            $0.modelID = modelID.rawValue
            $0.revision = revision
        }
    }
}

extension TextMessage {
    /// Creates a validated text message from its protocol representation.
    public init(wireValue: InferPeer_V1_TextMessage) throws {
        try self.init(
            role: TextMessageRole(wireValue: wireValue.role),
            text: wireValue.text
        )
    }

    /// The protocol representation of this text message.
    public var wireValue: InferPeer_V1_TextMessage {
        InferPeer_V1_TextMessage.with {
            $0.role = role.wireValue
            $0.text = text
        }
    }
}

extension SamplingOptions {
    /// Creates validated sampling options from their protocol representation.
    public init(wireValue: InferPeer_V1_SamplingOptions) throws {
        try self.init(
            temperature: wireValue.hasTemperature ? wireValue.temperature : nil,
            topP: wireValue.hasTopP ? wireValue.topP : nil,
            seed: wireValue.hasSeed ? wireValue.seed : nil
        )
    }

    /// The protocol representation of these sampling options.
    public var wireValue: InferPeer_V1_SamplingOptions {
        InferPeer_V1_SamplingOptions.with {
            if let temperature {
                $0.temperature = temperature
            }
            if let topP {
                $0.topP = topP
            }
            if let seed {
                $0.seed = seed
            }
        }
    }
}

extension ModelRequirement {
    /// Creates a validated model requirement from its protocol representation.
    public init(wireValue: InferPeer_V1_ModelRequirement) throws {
        switch wireValue.selector {
        case .exactModel(let reference):
            self = .exact(try ModelReference(wireValue: reference))
        case .permittedModels(let permitted):
            self = try .permitting(permitted.models.map(ModelReference.init(wireValue:)))
        case nil:
            throw InferenceValidationError.invalidWireValue(field: .modelRequirement)
        }
    }

    /// The protocol representation of this model requirement.
    public var wireValue: InferPeer_V1_ModelRequirement {
        InferPeer_V1_ModelRequirement.with {
            switch selection {
            case .exact(let reference):
                $0.exactModel = reference.wireValue
            case .permittedModels(let references):
                $0.permittedModels.models = references.map(\.wireValue)
            }
        }
    }
}

extension TextGenerationRequest {
    /// Creates a validated request from its protocol representation.
    public init(wireValue: InferPeer_V1_TextRequest) throws {
        let context = try ConversationContext(wireValue: wireValue)
        let options = try GenerationOptions(wireValue: wireValue)
        let allowedWorkerIDs = try Set(
            wireValue.allowedWorkerIds.map { rawValue in
                guard let workerID = PeerID(rawValue: rawValue) else {
                    throw InferenceValidationError.invalidWireValue(field: .allowedWorkerID)
                }
                return workerID
            }
        )
        self.init(
            context: context,
            options: options,
            allowedWorkerIDs: allowedWorkerIDs
        )
    }

    /// The protocol representation of this request.
    public var wireValue: InferPeer_V1_TextRequest {
        InferPeer_V1_TextRequest.with {
            $0.conversationID = context.conversationID.rawValue
            $0.contextRevision = context.revision
            $0.messages = context.messages.map(\.wireValue)
            $0.modelRequirement = options.modelRequirement.wireValue
            $0.maximumOutputTokens = options.maximumOutputTokens
            $0.sampling = options.sampling.wireValue
            if let deadline = options.deadline {
                $0.deadlineUnixMilliseconds = Int64(deadline.timeIntervalSince1970 * 1_000)
            }
            $0.allowedWorkerIds = allowedWorkerIDs.map(\.rawValue).sorted()
        }
    }
}

private extension TextMessageRole {
    init(wireValue: InferPeer_V1_MessageRole) throws {
        switch wireValue {
        case .system:
            self = .system
        case .user:
            self = .user
        case .assistant:
            self = .assistant
        case .unspecified, .UNRECOGNIZED:
            throw InferenceValidationError.invalidWireValue(field: .messageRole)
        }
    }

    var wireValue: InferPeer_V1_MessageRole {
        switch self {
        case .system:
            .system
        case .user:
            .user
        case .assistant:
            .assistant
        }
    }
}

private extension ConversationContext {
    init(wireValue: InferPeer_V1_TextRequest) throws {
        guard let conversationID = ConversationID(rawValue: wireValue.conversationID) else {
            throw InferenceValidationError.invalidWireValue(field: .conversationID)
        }
        try self.init(
            conversationID: conversationID,
            revision: wireValue.contextRevision,
            messages: wireValue.messages.map(TextMessage.init(wireValue:))
        )
    }
}

private extension GenerationOptions {
    init(wireValue: InferPeer_V1_TextRequest) throws {
        let sampling =
            wireValue.hasSampling
            ? try SamplingOptions(wireValue: wireValue.sampling)
            : .default
        let deadline =
            wireValue.hasDeadlineUnixMilliseconds
            ? Date(timeIntervalSince1970: Double(wireValue.deadlineUnixMilliseconds) / 1_000)
            : nil
        try self.init(
            modelRequirement: ModelRequirement(wireValue: wireValue.modelRequirement),
            maximumOutputTokens: wireValue.maximumOutputTokens,
            sampling: sampling,
            deadline: deadline
        )
    }
}
