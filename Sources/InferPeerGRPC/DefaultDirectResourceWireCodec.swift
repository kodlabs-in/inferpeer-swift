import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol

/// Versioned, bounded JSON payload codec carried inside the v2 Protobuf envelope.
public struct DefaultDirectResourceWireCodec: DirectResourceWireCoding, Sendable {
    /// Maximum encoded request metadata accepted by the direct protocol.
    public static let maximumSpecificationBytes = 256 * 1_024
    /// Maximum encoded payload accepted for one streamed run event.
    public static let maximumEventPayloadBytes = 256 * 1_024

    /// Creates the versioned production codec.
    public init() {}

    /// Encodes one validated query and its immutable run options.
    public func encode(
        _ query: InferenceQuery,
        options: RunOptions
    ) throws -> EncodedDirectRunSpecification {
        try query.validate()
        let specification = try WireRunSpecification(query: query, options: options)
        let data = try Self.encode(specification, maximumBytes: Self.maximumSpecificationBytes)
        return EncodedDirectRunSpecification(
            bytes: data,
            attachmentReceipts: specification.attachmentReceipts
        )
    }

    /// Decodes and validates one immutable run specification on a host.
    public func decode(
        _ specification: EncodedDirectRunSpecification
    ) throws -> DecodedDirectRunSpecification {
        let value: WireRunSpecification = try Self.decode(
            specification.bytes,
            maximumBytes: Self.maximumSpecificationBytes
        )
        guard Set(value.attachmentReceipts) == Set(specification.attachmentReceipts) else {
            throw InferPeerError(code: .assetInvalid, isRetryable: false)
        }
        let decoded = try value.decoded()
        try decoded.query.validate()
        return decoded
    }

    /// Encodes one ordered event into its bounded Protobuf envelope.
    public func encode(
        _ event: RunEvent,
        requestID: RequestID,
        incarnation: String,
        sequence: UInt64
    ) throws -> InferPeer_V2_RunEvent {
        guard !incarnation.isEmpty, sequence > 0 else {
            throw InferPeerError(code: .invalidRequest, isRetryable: false)
        }
        let payload = try WireRunEventPayload(event)
        let payloadData = try Self.encode(
            payload,
            maximumBytes: Self.maximumEventPayloadBytes
        )
        return InferPeer_V2_RunEvent.with {
            $0.requestID = requestID.rawValue
            $0.executionIncarnation = incarnation
            $0.sequence = sequence
            $0.eventType = payload.type.rawValue
            $0.boundedPayload = payloadData
            if let error = payload.error {
                $0.error = DirectWireMapper.wireError(error.value)
            }
        }
    }

    /// Decodes one ordered event and validates its payload discriminator.
    public func decode(_ event: InferPeer_V2_RunEvent) throws -> RunEvent {
        guard event.sequence > 0, !event.requestID.isEmpty, !event.executionIncarnation.isEmpty,
            let type = WireRunEventType(rawValue: event.eventType)
        else {
            throw InferPeerError(code: .protocolMismatch, isRetryable: false)
        }
        let payload: WireRunEventPayload = try Self.decode(
            event.boundedPayload,
            maximumBytes: Self.maximumEventPayloadBytes
        )
        guard payload.type == type else {
            throw InferPeerError(code: .protocolMismatch, isRetryable: false)
        }
        return try payload.value(wireError: event.hasError ? event.error : nil)
    }

    private static func encode<Value: Encodable>(
        _ value: Value,
        maximumBytes: Int
    ) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            guard data.count <= maximumBytes else {
                throw InferPeerError(code: .inputTooLarge, isRetryable: false)
            }
            return data
        } catch let error as InferPeerError {
            throw error
        } catch {
            throw InferPeerError(code: .invalidRequest, isRetryable: false)
        }
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type = Value.self,
        from data: Data,
        maximumBytes: Int
    ) throws -> Value {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw InferPeerError(code: .inputTooLarge, isRetryable: false)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw InferPeerError(code: .invalidRequest, isRetryable: false)
        }
    }

    private static func decode<Value: Decodable>(
        _ data: Data,
        maximumBytes: Int
    ) throws -> Value {
        try decode(Value.self, from: data, maximumBytes: maximumBytes)
    }
}

private struct WireRunSpecification: Codable {
    static let currentVersion = 1

    let version: Int
    let task: String
    let model: WireModelSelection
    let messages: [WireMessage]
    let attachmentReceipts: [String]
    let generation: WireGeneration?
    let queuePolicy: String
    let missingModelPolicy: String
    let disconnectGraceMilliseconds: UInt64

    init(query: InferenceQuery, options: RunOptions) throws {
        version = Self.currentVersion
        model = try WireModelSelection(query.modelSelection)
        queuePolicy = options.queuePolicy == .bounded ? "bounded" : "reject"
        missingModelPolicy =
            options.missingModelPolicy == .prepareIfEligible
            ? "prepare" : "ready"
        disconnectGraceMilliseconds = Self.grace(options.disconnectPolicy)
        switch query {
        case .text(let text):
            task = "text"
            messages = text.messages.map(WireMessage.init)
            attachmentReceipts = []
            generation = WireGeneration(text.generation)
        case .vision(let vision):
            task = "vision"
            messages = vision.messages.map(WireMessage.init)
            attachmentReceipts = try vision.images.map(Self.receipt)
            generation = WireGeneration(vision.generation)
        case .audioTranscription, .speechSynthesis:
            throw InferPeerError(code: .unsupportedTask, isRetryable: false)
        }
    }

    func decoded() throws -> DecodedDirectRunSpecification {
        guard version == Self.currentVersion else {
            throw InferPeerError(code: .protocolMismatch, isRetryable: false)
        }
        let selection = try model.value()
        let decodedMessages = try messages.map { try $0.value() }
        let decodedGeneration = try generation?.value() ?? .default
        let query: InferenceQuery
        switch task {
        case "text":
            guard attachmentReceipts.isEmpty else {
                throw InferPeerError(code: .assetInvalid, isRetryable: false)
            }
            query = .text(
                model: selection,
                messages: decodedMessages,
                generation: decodedGeneration
            )
        case "vision":
            query = .vision(
                model: selection,
                messages: decodedMessages,
                images: attachmentReceipts.map {
                    .receipt(InferenceAssetReceipt(rawValue: $0))
                },
                generation: decodedGeneration
            )
        default:
            throw InferPeerError(code: .unsupportedTask, isRetryable: false)
        }
        return DecodedDirectRunSpecification(query: query, options: try options())
    }

    private func options() throws -> RunOptions {
        let queue: RunQueuePolicy
        switch queuePolicy {
        case "bounded": queue = .bounded
        case "reject": queue = .rejectWhenBusy
        default: throw InferPeerError(code: .invalidRequest, isRetryable: false)
        }
        let missing: MissingModelPolicy
        switch missingModelPolicy {
        case "prepare": missing = .prepareIfEligible
        case "ready": missing = .requireReady
        default: throw InferPeerError(code: .invalidRequest, isRetryable: false)
        }
        return RunOptions(
            queuePolicy: queue,
            missingModelPolicy: missing,
            disconnectPolicy: .cancelAfter(.milliseconds(disconnectGraceMilliseconds))
        )
    }

    private static func receipt(_ asset: InferenceAssetReference) throws -> String {
        guard case .receipt(let receipt) = asset, !receipt.rawValue.isEmpty else {
            throw InferPeerError(code: .assetInvalid, isRetryable: false)
        }
        return receipt.rawValue
    }

    private static func grace(_ policy: RunDisconnectPolicy) -> UInt64 {
        switch policy {
        case .cancelAfter(let duration): DirectWireMapper.durationMilliseconds(duration)
        }
    }
}

private struct WireModelSelection: Codable {
    let modelID: String?
    let revision: String?

    init(_ selection: InferenceModelSelection) throws {
        switch selection {
        case .taskDefault:
            modelID = nil
            revision = nil
        case .exact(let key):
            modelID = key.modelID.rawValue
            revision = key.revision
        }
    }

    func value() throws -> InferenceModelSelection {
        if modelID == nil, revision == nil { return .taskDefault }
        guard let modelID, let revision, let identifier = ModelID(rawValue: modelID) else {
            throw InferPeerError(code: .invalidRequest, isRetryable: false)
        }
        return .exact(try ModelKey(modelID: identifier, revision: revision))
    }
}

private struct WireMessage: Codable {
    let role: String
    let text: String

    init(_ message: InferenceMessage) {
        role = message.role.rawValue
        text = message.text
    }

    func value() throws -> InferenceMessage {
        guard let role = TextMessageRole(rawValue: role) else {
            throw InferPeerError(code: .invalidRequest, isRetryable: false)
        }
        return InferenceMessage(role: role, text: text)
    }
}

private struct WireGeneration: Codable {
    let maximumOutputTokens: UInt32
    let temperature: Double?
    let topP: Double?
    let seed: UInt64?

    init(_ value: TextQueryGenerationOptions) {
        maximumOutputTokens = value.maxOutputTokens
        temperature = value.temperature
        topP = value.topP
        seed = value.seed
    }

    func value() throws -> TextQueryGenerationOptions {
        let value = TextQueryGenerationOptions(
            maxOutputTokens: maximumOutputTokens,
            temperature: temperature,
            topP: topP,
            seed: seed
        )
        return value
    }
}
