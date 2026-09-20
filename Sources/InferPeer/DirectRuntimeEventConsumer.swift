import InferPeerCore
import InferPeerInference

enum DirectRuntimeEventConsumer {
    private static let maximumTextBytes = 512 * 1_024
    private static let maximumAudioBytes = 16 * 1_024 * 1_024

    static func consume(
        _ events: DirectRuntimeEventStream,
        execution: DirectRuntimeExecution,
        emit: @escaping @Sendable (RunEvent) throws -> Void
    ) async throws -> RunResult {
        var streamedTextBytes = 0
        var streamedAudioBytes = 0
        for try await event in events {
            switch event {
            case .preprocessing(let stage):
                try emit(.preprocessing(stage))
            case .textDelta(let text):
                streamedTextBytes += text.utf8.count
                try enforceLimit(streamedTextBytes, maximum: maximumTextBytes)
                try emit(.textDelta(text))
            case .transcriptSegment(let segment):
                try validate(segment)
                streamedTextBytes += segment.text.utf8.count
                try enforceLimit(streamedTextBytes, maximum: maximumTextBytes)
                try emit(.transcriptSegment(segment))
            case .audioChunk(let chunk):
                try validate(chunk)
                streamedAudioBytes += chunk.samples.count
                try enforceLimit(streamedAudioBytes, maximum: maximumAudioBytes)
                try emit(.audioChunk(chunk))
            case .completed(let result):
                try validate(result, execution: execution)
                try emit(.usage(result.usage))
                return result
            }
        }
        throw InferPeerError(
            code: .internal,
            message: "The runtime ended without a terminal event",
            isRetryable: false
        )
    }

    private static func validate(
        _ result: RunResult,
        execution: DirectRuntimeExecution
    ) throws {
        guard result.model == execution.model,
            content(result.content, matches: execution.query.task)
        else {
            throw InferPeerError(
                code: .internal,
                message: "The runtime returned a result for a different model or task",
                isRetryable: false
            )
        }
        switch result.content {
        case .text(let text):
            try enforceLimit(text.utf8.count, maximum: maximumTextBytes)
        case .transcription(let segments, let language, _):
            guard !language.isEmpty, segments.allSatisfy(\.isFinal) else {
                throw invalidRuntimeOutput()
            }
            try segments.forEach(validate)
            try enforceLimit(
                segments.reduce(0) { $0 + $1.text.utf8.count },
                maximum: maximumTextBytes
            )
        case .speech(_, _, let sampleRate, let channelCount, let frameCount):
            guard sampleRate > 0, channelCount > 0, frameCount > 0 else {
                throw invalidRuntimeOutput()
            }
        }
    }

    private static func content(
        _ content: RunResultContent,
        matches task: InferenceTask
    ) -> Bool {
        switch (task, content) {
        case (.textGeneration, .text), (.imageUnderstanding, .text),
            (.transcribe, .transcription), (.synthesizeSpeech, .speech):
            true
        default:
            false
        }
    }

    private static func validate(_ segment: TranscriptSegment) throws {
        guard !segment.id.isEmpty, segment.revision > 0,
            segment.start >= .zero, segment.end >= segment.start
        else {
            throw invalidRuntimeOutput()
        }
    }

    private static func validate(_ chunk: AudioChunk) throws {
        guard chunk.sampleRate > 0, chunk.channelCount > 0, !chunk.samples.isEmpty else {
            throw invalidRuntimeOutput()
        }
    }

    private static func enforceLimit(_ bytes: Int, maximum: Int) throws {
        guard bytes <= maximum else {
            throw InferPeerError(
                code: .outputBackpressure,
                message: "The runtime output exceeded the configured byte bound",
                isRetryable: false
            )
        }
    }

    private static func invalidRuntimeOutput() -> InferPeerError {
        InferPeerError(
            code: .internal,
            message: "The runtime returned malformed output",
            isRetryable: false
        )
    }
}
