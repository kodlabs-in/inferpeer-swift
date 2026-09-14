import Foundation
import InferPeerInference

enum MLXRuntimeFinishReason: Sendable {
    case stop
    case maximumTokens
}

struct MLXRuntimeCompletion: Sendable {
    let promptTokens: UInt32
    let outputTokens: UInt32
    let promptDuration: Duration
    let generationDuration: Duration
    let finishReason: MLXRuntimeFinishReason
}

enum MLXRuntimeEvent: Sendable {
    case text(String)
    case completed(MLXRuntimeCompletion)
}

typealias MLXRuntimeEventStream = AsyncThrowingStream<MLXRuntimeEvent, any Error>

protocol MLXModelSession: Sendable {
    func tokenCount(messages: [TextMessage]) async throws -> Int

    func generate(
        messages: [TextMessage],
        sampling: SamplingOptions,
        maximumOutputTokens: UInt32
    ) async throws -> MLXRuntimeEventStream
}

protocol MLXRuntime: Sendable {
    func loadModel(at directoryURL: URL) async throws -> any MLXModelSession
    func clearCache()
}

enum MLXRuntimeAdapterError: Error {
    case invalidTokenCount
    case toolCallsUnsupported
}
