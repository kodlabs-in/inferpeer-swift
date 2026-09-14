import Foundation
import InferPeerInference
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

struct AppleMLXRuntime: MLXRuntime {
    func loadModel(at directoryURL: URL) async throws -> any MLXModelSession {
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directoryURL,
            using: #huggingFaceTokenizerLoader()
        )
        return AppleMLXModelSession(container: container)
    }

    func clearCache() {
        Memory.clearCache()
    }
}

private struct AppleMLXModelSession: MLXModelSession {
    let container: ModelContainer

    func tokenCount(messages: [TextMessage]) async throws -> Int {
        let input = try await container.prepare(input: userInput(messages))
        return input.text.tokens.size
    }

    func generate(
        messages: [TextMessage],
        sampling: SamplingOptions,
        maximumOutputTokens: UInt32
    ) async throws -> MLXRuntimeEventStream {
        let input = try await container.prepare(input: userInput(messages))
        let parameters = GenerateParameters(
            maxTokens: Int(maximumOutputTokens),
            temperature: Float(sampling.temperature ?? 0.6),
            topP: Float(sampling.topP ?? 1.0),
            seed: sampling.seed
        )
        let generations = try await container.generate(input: input, parameters: parameters)
        return MLXRuntimeEventStream { continuation in
            let task = Task {
                do {
                    try await forward(generations, to: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func userInput(_ messages: [TextMessage]) -> UserInput {
        let chat = messages.map { message in
            Chat.Message(role: role(message.role), content: message.text)
        }
        return UserInput(chat: chat)
    }

    private func role(_ role: TextMessageRole) -> Chat.Message.Role {
        switch role {
        case .system:
            .system
        case .user:
            .user
        case .assistant:
            .assistant
        }
    }

    private func forward(
        _ generations: AsyncStream<Generation>,
        to continuation: MLXRuntimeEventStream.Continuation
    ) async throws {
        for await generation in generations {
            try Task.checkCancellation()
            switch generation {
            case .chunk(let text):
                continuation.yield(.text(text))
            case .info(let information):
                continuation.yield(.completed(try completion(information)))
            case .toolCall:
                throw MLXRuntimeAdapterError.toolCallsUnsupported
            }
        }
    }

    private func completion(_ information: GenerateCompletionInfo) throws -> MLXRuntimeCompletion {
        guard let promptTokens = UInt32(exactly: information.promptTokenCount),
            let outputTokens = UInt32(exactly: information.generationTokenCount)
        else {
            throw MLXRuntimeAdapterError.invalidTokenCount
        }
        let finishReason: MLXRuntimeFinishReason
        switch information.stopReason {
        case .stop:
            finishReason = .stop
        case .length:
            finishReason = .maximumTokens
        case .cancelled:
            throw CancellationError()
        }
        return MLXRuntimeCompletion(
            promptTokens: promptTokens,
            outputTokens: outputTokens,
            promptDuration: .seconds(information.promptTime),
            generationDuration: .seconds(information.generateTime),
            finishReason: finishReason
        )
    }
}
