import InferPeerCore
import InferPeerInference
import InferPeerProtocol

enum WireRunEventType: String, Codable {
    case accepted
    case queued
    case loadingModel
    case started
    case preprocessing
    case textDelta
    case usage
    case completed
    case failed
    case cancelled
    case expired
    case interrupted
}

struct WireRunEventPayload: Codable {
    let type: WireRunEventType
    let model: WireModelKey?
    let position: Int?
    let stage: String?
    let text: String?
    let usage: WireUsage?
    let result: WireTextResult?
    let error: WireError?

    init(_ event: RunEvent) throws {
        let values = try WireRunEventValues(event)
        type = values.type
        model = values.model
        position = values.position
        stage = values.stage
        text = values.text
        usage = values.usage
        result = values.result
        error = values.error
    }

    func value(wireError: InferPeer_V2_ErrorDetail?) throws -> RunEvent {
        if type.isProgressEvent {
            return try progressValue()
        }
        return try terminalValue(wireError: wireError)
    }

    private func progressValue() throws -> RunEvent {
        switch type {
        case .accepted: .accepted(model: try requiredModel())
        case .queued: .queued(position: try requiredPosition())
        case .loadingModel: .loadingModel(try requiredModel())
        case .started: .started(model: try requiredModel())
        case .preprocessing: .preprocessing(try requiredStage())
        case .textDelta: .textDelta(try requiredText())
        case .usage: .usage(try requiredUsage())
        default: throw protocolError()
        }
    }

    private func terminalValue(
        wireError: InferPeer_V2_ErrorDetail?
    ) throws -> RunEvent {
        switch type {
        case .completed: .completed(try requiredResult())
        case .failed: .failed(try requiredError(wireError))
        case .cancelled: .cancelled
        case .expired: .expired
        case .interrupted: .interrupted(try requiredError(wireError))
        default: throw protocolError()
        }
    }

    private func requiredModel() throws -> ModelKey {
        guard let model else { throw protocolError() }
        return try model.value()
    }

    private func requiredPosition() throws -> Int {
        guard let position, position > 0 else { throw protocolError() }
        return position
    }

    private func requiredStage() throws -> PreprocessingStage {
        guard let stage, let value = PreprocessingStage(rawValue: stage) else {
            throw protocolError()
        }
        return value
    }

    private func requiredText() throws -> String {
        guard let text, !text.isEmpty else { throw protocolError() }
        return text
    }

    private func requiredUsage() throws -> TokenUsage {
        guard let usage else { throw protocolError() }
        return usage.value
    }

    private func requiredResult() throws -> RunResult {
        guard let result else { throw protocolError() }
        return try result.value()
    }

    private func requiredError(_ wire: InferPeer_V2_ErrorDetail?) throws -> InferPeerError {
        if let wire { return DirectWireMapper.error(wire) }
        guard let error else { throw protocolError() }
        return error.value
    }

    private func protocolError() -> InferPeerError {
        InferPeerError(code: .protocolMismatch, isRetryable: false)
    }
}

private extension WireRunEventType {
    var isProgressEvent: Bool {
        switch self {
        case .accepted, .queued, .loadingModel, .started,
            .preprocessing, .textDelta, .usage:
            true
        case .completed, .failed, .cancelled, .expired, .interrupted:
            false
        }
    }
}

struct WireRunEventValues {
    let type: WireRunEventType
    var model: WireModelKey?
    var position: Int?
    var stage: String?
    var text: String?
    var usage: WireUsage?
    var result: WireTextResult?
    var error: WireError?

    init(_ event: RunEvent) throws {
        switch event {
        case .accepted(let model):
            self.init(type: .accepted, model: WireModelKey(model))
        case .queued(let position):
            self.init(type: .queued, position: position)
        case .loadingModel(let model):
            self.init(type: .loadingModel, model: WireModelKey(model))
        case .started(let model):
            self.init(type: .started, model: WireModelKey(model))
        case .preprocessing(let stage):
            self.init(type: .preprocessing, stage: stage.rawValue)
        case .textDelta(let text):
            self.init(type: .textDelta, text: text)
        case .usage(let usage):
            self.init(type: .usage, usage: WireUsage(usage))
        default:
            self = try Self.terminalValues(event)
        }
    }

    private static func terminalValues(_ event: RunEvent) throws -> Self {
        switch event {
        case .completed(let result):
            Self(type: .completed, result: try WireTextResult(result))
        case .failed(let error):
            Self(type: .failed, error: WireError(error))
        case .cancelled:
            Self(type: .cancelled)
        case .expired:
            Self(type: .expired)
        case .interrupted(let error):
            Self(type: .interrupted, error: WireError(error))
        case .transcriptSegment, .audioChunk:
            throw InferPeerError(code: .unsupportedTask, isRetryable: false)
        default:
            throw InferPeerError(code: .internal, isRetryable: false)
        }
    }

    private init(
        type: WireRunEventType,
        model: WireModelKey? = nil,
        position: Int? = nil,
        stage: String? = nil,
        text: String? = nil,
        usage: WireUsage? = nil,
        result: WireTextResult? = nil,
        error: WireError? = nil
    ) {
        self.type = type
        self.model = model
        self.position = position
        self.stage = stage
        self.text = text
        self.usage = usage
        self.result = result
        self.error = error
    }
}

struct WireModelKey: Codable {
    let modelID: String
    let revision: String

    init(_ model: ModelKey) {
        modelID = model.modelID.rawValue
        revision = model.revision
    }

    func value() throws -> ModelKey {
        guard let identifier = ModelID(rawValue: modelID) else {
            throw InferPeerError(code: .protocolMismatch, isRetryable: false)
        }
        return try ModelKey(modelID: identifier, revision: revision)
    }
}

struct WireUsage: Codable {
    let promptTokens: UInt32
    let outputTokens: UInt32

    init(_ usage: TokenUsage) {
        promptTokens = usage.promptTokens
        outputTokens = usage.outputTokens
    }

    var value: TokenUsage {
        TokenUsage(promptTokens: promptTokens, outputTokens: outputTokens)
    }
}

struct WireTextResult: Codable {
    let text: String
    let model: WireModelKey
    let finishReason: String
    let usage: WireUsage

    init(_ result: RunResult) throws {
        guard case .text(let text) = result.content else {
            throw InferPeerError(code: .unsupportedTask, isRetryable: false)
        }
        self.text = text
        model = WireModelKey(result.model)
        finishReason = result.finishReason.rawValue
        usage = WireUsage(result.usage)
    }

    func value() throws -> RunResult {
        guard let finishReason = GenerationFinishReason(rawValue: finishReason) else {
            throw InferPeerError(code: .protocolMismatch, isRetryable: false)
        }
        return RunResult(
            text: text,
            model: try model.value(),
            finishReason: finishReason,
            usage: usage.value
        )
    }
}

struct WireError: Codable {
    let code: Int
    let message: String
    let retryable: Bool

    init(_ error: InferPeerError) {
        code = error.code.rawValue
        message = error.message
        retryable = error.isRetryable
    }

    var value: InferPeerError {
        InferPeerError(
            code: InferPeerErrorCode(rawValue: code),
            message: message,
            isRetryable: retryable
        )
    }
}
