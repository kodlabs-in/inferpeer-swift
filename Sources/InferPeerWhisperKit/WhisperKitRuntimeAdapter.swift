import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerModelStore
import InferPeerProtocol
import WhisperKit

/// Offline, model-store-backed adapter for pinned WhisperKit Core ML artifacts.
public struct WhisperKitRuntimeAdapter: InferPeerRuntimeAdapter, Sendable {
    /// Stable model-manifest runtime identity.
    public let runtimeID = RuntimeID(rawValue: "whisperkit")

    /// InferPeer adapter version pinned to Argmax OSS 1.1.0.
    public let runtimeVersion = "1.1.0.1"

    /// Creates an adapter whose runtime is prevented from downloading dependencies.
    public init() {}

    // Protocol requirement is async so adapters can probe hardware when needed.
    // swiftlint:disable async_without_await
    /// Validates the manifest shape supported by WhisperKit transcription.
    public func support(
        for model: ModelManifest,
        on _: ModelStoreDeviceProfile
    ) async -> InferPeerRuntimeModelSupport {
        guard
            model.runtime.runtimeIdentifier.caseInsensitiveCompare(runtimeID.rawValue)
                == .orderedSame
        else {
            return .unsupported(reasons: [.adapterRejected("runtime identifier is not whisperkit")])
        }
        guard model.runtime.format.caseInsensitiveCompare("CoreML") == .orderedSame else {
            return .unsupported(reasons: [.adapterRejected("model format is not CoreML")])
        }
        guard Set(model.capabilities.map(\.task)) == [.transcribe] else {
            return .unsupported(
                reasons: [.adapterRejected("WhisperKit supports transcription only")]
            )
        }
        return .supported
    }
    // swiftlint:enable async_without_await

    /// Loads Core ML models and a prevalidated local tokenizer without network fallback.
    public func load(
        model: InstalledModel,
        configuration: ModelLoadConfiguration
    ) async throws -> any InferPeerModelSession {
        if let limit = configuration.maximumWorkingMemoryBytes,
            model.installedByteCount > limit
        {
            throw WhisperKitAdapterError.memoryLimitExceeded
        }
        let tokenizerFolder = try Self.tokenizerFolder(in: model)
        try Self.validateTokenizerFiles(in: tokenizerFolder)
        let tokenizer = try await AutoTokenizerWrapper.from(modelFolder: tokenizerFolder)
        let engine = try await Self.makeEngine(
            modelFolder: model.directoryURL,
            tokenizerFolder: tokenizerFolder,
            tokenizer: OfflineWhisperTokenizer(tokenizer)
        )
        return WhisperKitModelSession(modelKey: model.key, engine: engine)
    }
}

private extension WhisperKitRuntimeAdapter {
    static let tokenizerFiles = [
        "added_tokens.json",
        "merges.txt",
        "normalizer.json",
        "special_tokens_map.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "vocab.json",
    ]

    static func tokenizerFolder(in model: InstalledModel) throws -> URL {
        guard
            let tokenizer = model.manifest.files.first(where: {
                $0.role == .tokenizer && $0.relativePath.hasSuffix("tokenizer.json")
            })
        else {
            throw WhisperKitAdapterError.invalidManifest
        }
        return model.directoryURL
            .appendingPathComponent(tokenizer.relativePath)
            .deletingLastPathComponent()
    }

    static func validateTokenizerFiles(in folder: URL) throws {
        let missing = tokenizerFiles.contains { name in
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
        guard !missing else { throw WhisperKitAdapterError.incompleteTokenizer }
    }

    static func makeEngine(
        modelFolder: URL,
        tokenizerFolder: URL,
        tokenizer: any WhisperTokenizer
    ) async throws -> WhisperKitHandle {
        let engine = try await WhisperKit(
            modelFolder: modelFolder.path,
            tokenizerFolder: tokenizerFolder,
            verbose: false,
            prewarm: false,
            load: false,
            download: false,
            useBackgroundDownloadSession: false
        )
        engine.tokenizer = tokenizer
        try await engine.loadModels()
        return WhisperKitHandle(engine)
    }
}

/// Stable package-facing WhisperKit adapter failures.
public enum WhisperKitAdapterError: Error, Equatable, Sendable {
    case invalidManifest
    case incompleteTokenizer
    case memoryLimitExceeded
    case sessionUnavailable
    case unsupportedAsset
    case transcriptionFailed
}

private final class OfflineWhisperTokenizer: WhisperTokenizer, @unchecked Sendable {
    private let tokenizer: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(_ tokenizer: TokenizerWrapper) {
        self.tokenizer = tokenizer
        specialTokens = Self.specialTokens(from: tokenizer)
        allLanguageTokens = Set(
            Constants.languages.values.compactMap {
                tokenizer.convertTokenToId("<|\($0)|>")
            }
        )
    }

    func encode(text: String) -> [Int] {
        tokenizer.encode(text: text)
    }

    func decode(tokens: [Int]) -> String {
        tokenizer.decode(tokens: tokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        tokenizer.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        tokenizer.convertIdToToken(id)
    }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        var words: [String] = []
        var groups: [[Int]] = []
        for token in tokenIds where token < specialTokens.specialTokenBegin {
            let piece = tokenizer.decode(tokens: [token])
            if words.isEmpty || piece.hasPrefix(" ") {
                words.append(piece)
                groups.append([token])
            } else {
                words[words.count - 1] += piece
                groups[groups.count - 1].append(token)
            }
        }
        return (words, groups)
    }
}

private extension OfflineWhisperTokenizer {
    static func specialTokens(from tokenizer: TokenizerWrapper) -> SpecialTokens {
        SpecialTokens(
            endToken: tokenizer.convertTokenToId("<|endoftext|>") ?? 50_257,
            englishToken: tokenizer.convertTokenToId("<|en|>") ?? 50_259,
            noSpeechToken: tokenizer.convertTokenToId("<|nospeech|>") ?? 50_362,
            noTimestampsToken: tokenizer.convertTokenToId("<|notimestamps|>") ?? 50_363,
            specialTokenBegin: tokenizer.convertTokenToId("<|endoftext|>") ?? 50_257,
            startOfPreviousToken: tokenizer.convertTokenToId("<|startofprev|>") ?? 50_361,
            startOfTranscriptToken: tokenizer.convertTokenToId("<|startoftranscript|>") ?? 50_258,
            timeTokenBegin: tokenizer.convertTokenToId("<|0.00|>") ?? 50_364,
            transcribeToken: tokenizer.convertTokenToId("<|transcribe|>") ?? 50_359,
            translateToken: tokenizer.convertTokenToId("<|translate|>") ?? 50_358,
            whitespaceToken: tokenizer.convertTokenToId(" ") ?? 220
        )
    }
}

private final class WhisperKitModelSession: InferPeerModelSession, @unchecked Sendable {
    let modelKey: ModelKey
    let capabilities: Set<InferenceTask> = [.transcribe]

    private let engine: WhisperKitHandle
    private let state = WhisperKitSessionState()

    init(modelKey: ModelKey, engine: WhisperKitHandle) {
        self.modelKey = modelKey
        self.engine = engine
    }

    func run(_ request: InferenceQuery) -> DirectRuntimeEventStream {
        let pair = DirectRuntimeEventStream.makeStream(bufferingPolicy: .bufferingOldest(64))
        let runID = UUID()
        do {
            try state.begin(runID)
        } catch {
            pair.continuation.finish(throwing: error)
            return pair.stream
        }
        let task = Task { [engine, modelKey, state] in
            defer { state.finish(runID) }
            do {
                try Task.checkCancellation()
                let input = try Self.input(from: request)
                pair.continuation.yield(.preprocessing(.decodingMedia))
                let results = try await Self.transcribe(input: input, using: engine)
                try Task.checkCancellation()
                let segments = Self.segments(from: results)
                segments.forEach { pair.continuation.yield(.transcriptSegment($0)) }
                let result = Self.result(
                    segments: segments,
                    results: results,
                    input: input,
                    modelKey: modelKey
                )
                pair.continuation.yield(.completed(result))
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        pair.continuation.onTermination = { [engine, state] _ in
            task.cancel()
            if state.requestCancellation(runID) { engine.clearState() }
        }
        return pair.stream
    }

    func unload() async {
        if state.markUnloaded() { engine.clearState() }
        await state.waitUntilIdle()
        await engine.unloadModels()
    }
}

private extension WhisperKitModelSession {
    struct Input: Sendable {
        let path: String
        let language: String?
        let mode: TranscriptionMode
    }

    static func input(from request: InferenceQuery) throws -> Input {
        try request.validate()
        guard case .audioTranscription(let query) = request,
            case .file(let url) = query.audio,
            url.isFileURL
        else {
            throw WhisperKitAdapterError.unsupportedAsset
        }
        return Input(path: url.path, language: query.language, mode: query.mode)
    }

    static func transcribe(input: Input, using engine: WhisperKitHandle) async throws
        -> [TranscriptionResult]
    {
        let task: DecodingTask = input.mode == .translation ? .translate : .transcribe
        let options = DecodingOptions(task: task, language: input.language)
        guard let first = await engine.transcribe(path: input.path, options: options).first else {
            throw WhisperKitAdapterError.transcriptionFailed
        }
        return try first.get()
    }

    static func segments(from results: [TranscriptionResult]) -> [InferPeerCore.TranscriptSegment] {
        results.flatMap(\.segments).enumerated().map { index, segment in
            InferPeerCore.TranscriptSegment(
                id: "whisper-\(index)",
                revision: 1,
                start: .milliseconds(Int64(segment.start * 1_000)),
                end: .milliseconds(Int64(segment.end * 1_000)),
                text: segment.text,
                isFinal: true
            )
        }
    }

    static func result(
        segments: [InferPeerCore.TranscriptSegment],
        results: [TranscriptionResult],
        input: Input,
        modelKey: ModelKey
    ) -> RunResult {
        let language =
            results.first(where: { !$0.language.isEmpty })?.language
            ?? input.language
            ?? "und"
        let outputTokens = results.flatMap(\.segments).reduce(0) { total, segment in
            total + segment.tokens.count
        }
        return RunResult(
            content: .transcription(segments: segments, language: language, mode: input.mode),
            model: modelKey,
            finishReason: .stop,
            usage: TokenUsage(promptTokens: 0, outputTokens: UInt32(clamping: outputTokens))
        )
    }
}

private final class WhisperKitHandle: @unchecked Sendable {
    private let engine: WhisperKit

    init(_ engine: WhisperKit) {
        self.engine = engine
    }

    func transcribe(
        path: String,
        options: DecodingOptions
    ) async -> [Result<[TranscriptionResult], any Error>] {
        await engine.transcribeWithResults(audioPaths: [path], decodeOptions: options)
    }

    func clearState() {
        engine.clearState()
    }

    func unloadModels() async {
        await engine.unloadModels()
    }
}

private final class WhisperKitSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRunID: UUID?
    private var unloaded = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func begin(_ runID: UUID) throws {
        try lock.withLock {
            guard activeRunID == nil, !unloaded else {
                throw WhisperKitAdapterError.sessionUnavailable
            }
            activeRunID = runID
        }
    }

    func finish(_ runID: UUID) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard activeRunID == runID else { return [] }
            activeRunID = nil
            defer { idleWaiters.removeAll(keepingCapacity: false) }
            return idleWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func requestCancellation(_ runID: UUID) -> Bool {
        lock.withLock { activeRunID == runID }
    }

    func markUnloaded() -> Bool {
        lock.withLock {
            unloaded = true
            return activeRunID != nil
        }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard activeRunID != nil else { return true }
                idleWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }
}
