import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerLlamaBridge
import InferPeerModelStore
import InferPeerProtocol

// Native ownership and Swift session glue are intentionally colocated for auditability.
// swiftlint:disable file_length

/// Offline, model-store-backed llama.cpp and libmtmd runtime adapter.
public struct LlamaRuntimeAdapter: InferPeerRuntimeAdapter, Sendable {
    /// Stable model-manifest runtime identity.
    public let runtimeID = RuntimeID(rawValue: "llama.cpp")

    /// InferPeer adapter version pinned to llama.cpp b10982.
    public let runtimeVersion = "b10982.1"

    /// Creates a native adapter with no runtime-owned download path.
    public init() {}

    // Protocol requirement is async so adapters can probe hardware when needed.
    // swiftlint:disable async_without_await
    /// Validates the GGUF and projector shape supported by the native bridge.
    public func support(
        for model: ModelManifest,
        on _: ModelStoreDeviceProfile
    ) async -> ModelSupport {
        guard
            model.runtime.runtimeIdentifier.caseInsensitiveCompare(runtimeID.rawValue)
                == .orderedSame
        else {
            return .unsupported(reasons: [.adapterRejected("runtime identifier is not llama.cpp")])
        }
        guard model.runtime.format.caseInsensitiveCompare("GGUF") == .orderedSame else {
            return .unsupported(reasons: [.adapterRejected("model format is not GGUF")])
        }
        let tasks = Set(model.capabilities.map(\.task))
        guard tasks.isSubset(of: [.textGeneration, .imageUnderstanding]) else {
            return .unsupported(reasons: [.adapterRejected("unsupported llama.cpp task")])
        }
        if tasks.contains(.imageUnderstanding),
            !model.files.contains(where: { $0.role == .projector })
        {
            return .unsupported(
                reasons: [.adapterRejected("vision GGUF requires a libmtmd projector")]
            )
        }
        return .supported
    }
    // swiftlint:enable async_without_await

    // Protocol requirement is async so other adapters can load asynchronously.
    // swiftlint:disable async_without_await
    /// Loads exact package-managed GGUF files and rejects hidden dependencies.
    public func load(
        model: InstalledModel,
        configuration: ModelLoadConfiguration
    ) async throws -> any InferPeerModelSession {
        if let limit = configuration.maximumWorkingMemoryBytes,
            model.installedByteCount > limit
        {
            throw LlamaAdapterError.memoryLimitExceeded
        }
        let files = try Self.files(for: model)
        let contextTokens = Self.contextTokens(for: model.manifest)
        let native = try NativeLlamaHandle(
            modelPath: files.model.path,
            projectorPath: files.projector?.path,
            contextTokens: contextTokens
        )
        let tasks = Set(model.manifest.capabilities.map(\.task))
        guard !tasks.contains(.imageUnderstanding) || native.supportsVision else {
            throw LlamaAdapterError.projectorRejected
        }
        return LlamaModelSession(modelKey: model.key, capabilities: tasks, native: native)
    }
    // swiftlint:enable async_without_await
}

private extension LlamaRuntimeAdapter {
    struct NativeFiles {
        let model: URL
        let projector: URL?
    }

    static func files(for model: InstalledModel) throws -> NativeFiles {
        guard let weights = model.manifest.files.first(where: { $0.role == .weights }) else {
            throw LlamaAdapterError.invalidManifest
        }
        let modelURL = model.directoryURL.appendingPathComponent(weights.relativePath)
        let projectorURL = model.manifest.files.first(where: { $0.role == .projector }).map {
            model.directoryURL.appendingPathComponent($0.relativePath)
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LlamaAdapterError.missingArtifact
        }
        if let projectorURL, !FileManager.default.fileExists(atPath: projectorURL.path) {
            throw LlamaAdapterError.missingArtifact
        }
        return NativeFiles(model: modelURL, projector: projectorURL)
    }

    static func contextTokens(for manifest: ModelManifest) -> UInt32 {
        let declared = manifest.capabilities.compactMap(\.contextTokenLimit).max() ?? 4_096
        return min(declared, 4_096)
    }
}

private final class NativeLlamaHandle: @unchecked Sendable {
    private let pointer: OpaquePointer

    var supportsVision: Bool {
        ipl_llama_session_supports_vision(pointer)
    }

    init(modelPath: String, projectorPath: String?, contextTokens: UInt32) throws {
        var error = [CChar](repeating: 0, count: 512)
        let created = modelPath.withCString { modelPointer in
            Self.withOptionalCString(projectorPath) { projectorPointer in
                ipl_llama_session_create(
                    modelPointer,
                    projectorPointer,
                    contextTokens,
                    99,
                    &error,
                    error.count
                )
            }
        }
        guard let created else {
            throw LlamaAdapterError.nativeLoadFailed(Self.message(from: error))
        }
        pointer = created
    }

    deinit {
        ipl_llama_session_destroy(pointer)
    }

    func cancel() {
        ipl_llama_cancel(pointer)
    }

    func generate(
        input: LlamaRunInput,
        collector: LlamaOutputCollector
    ) throws -> LlamaGenerationSummary {
        let call = invoke(input: input, collector: collector)
        if call.status == 2 {
            throw CancellationError()
        }
        guard call.status == 0 else {
            throw LlamaAdapterError.nativeGenerationFailed(Self.message(from: call.error))
        }
        return LlamaGenerationSummary(
            promptTokens: call.promptTokens,
            outputTokens: call.outputTokens,
            reachedEndToken: call.reachedEnd
        )
    }
}

private extension NativeLlamaHandle {
    func invoke(
        input: LlamaRunInput,
        collector: LlamaOutputCollector
    ) -> NativeGenerationCall {
        let roles = OwnedCStringArray(input.roles)
        let contents = OwnedCStringArray(input.contents)
        let media = OwnedCStringArray(input.mediaPaths)
        var promptTokens: UInt32 = 0
        var outputTokens: UInt32 = 0
        var reachedEnd = false
        var error = [CChar](repeating: 0, count: 512)
        let collectorPointer = Unmanaged.passUnretained(collector).toOpaque()
        let status = roles.withBuffer { roleBuffer in
            contents.withBuffer { contentBuffer in
                media.withBuffer { mediaBuffer in
                    ipl_llama_generate(
                        pointer,
                        roleBuffer.baseAddress,
                        contentBuffer.baseAddress,
                        roleBuffer.count,
                        mediaBuffer.baseAddress,
                        mediaBuffer.count,
                        input.maximumOutputTokens,
                        input.temperature,
                        input.topP,
                        input.seed,
                        llamaTokenCallback,
                        collectorPointer,
                        &promptTokens,
                        &outputTokens,
                        &reachedEnd,
                        &error,
                        error.count
                    )
                }
            }
        }
        return NativeGenerationCall(
            status: status,
            promptTokens: promptTokens,
            outputTokens: outputTokens,
            reachedEnd: reachedEnd,
            error: error
        )
    }

    static func withOptionalCString<Result>(
        _ string: String?,
        body: (UnsafePointer<CChar>?) throws -> Result
    ) rethrows -> Result {
        guard let string else { return try body(nil) }
        return try string.withCString(body)
    }

    static func message(from buffer: [CChar]) -> String {
        buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return "native llama.cpp error" }
            return String(cString: baseAddress)
        }
    }
}

private struct LlamaRunInput: Sendable {
    let roles: [String]
    let contents: [String]
    let mediaPaths: [String]
    let maximumOutputTokens: UInt32
    let temperature: Float
    let topP: Float
    let seed: UInt32
}

private struct LlamaGenerationSummary: Sendable {
    let promptTokens: UInt32
    let outputTokens: UInt32
    let reachedEndToken: Bool
}

private struct NativeGenerationCall {
    let status: Int32
    let promptTokens: UInt32
    let outputTokens: UInt32
    let reachedEnd: Bool
    let error: [CChar]
}

private final class OwnedCStringArray {
    private let storage: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) {
        storage = strings.map { string in
            string.withCString { strdup($0) }
        }
    }

    deinit {
        storage.forEach { pointer in
            free(UnsafeMutableRawPointer(pointer))
        }
    }

    func withBuffer<Result>(
        _ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        let pointers: [UnsafePointer<CChar>?] = storage.map { pointer in
            pointer.map { UnsafePointer<CChar>($0) }
        }
        return try pointers.withUnsafeBufferPointer(body)
    }
}

private let llamaTokenCallback: IPLLamaTokenCallback = { bytes, count, context in
    guard let bytes, let context, count > 0 else { return }
    let collector = Unmanaged<LlamaOutputCollector>.fromOpaque(context).takeUnretainedValue()
    let raw = UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self)
    let buffer = UnsafeBufferPointer(start: raw, count: Int(count))
    collector.receive(String(bytes: buffer, encoding: .utf8) ?? "")
}

private final class LlamaOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: DirectRuntimeEventStream.Continuation
    private var text = ""

    init(continuation: DirectRuntimeEventStream.Continuation) {
        self.continuation = continuation
    }

    func receive(_ delta: String) {
        lock.withLock { text += delta }
        continuation.yield(.textDelta(delta))
    }

    func completeText() -> String {
        lock.withLock { text }
    }
}

private final class LlamaModelSession: InferPeerModelSession, @unchecked Sendable {
    let modelKey: ModelKey
    let capabilities: Set<InferenceTask>

    private let native: NativeLlamaHandle
    private let state = LlamaSessionState()

    init(
        modelKey: ModelKey,
        capabilities: Set<InferenceTask>,
        native: NativeLlamaHandle
    ) {
        self.modelKey = modelKey
        self.capabilities = capabilities
        self.native = native
    }

    func run(_ request: InferenceQuery) -> DirectRuntimeEventStream {
        let pair = DirectRuntimeEventStream.makeStream(bufferingPolicy: .bufferingOldest(64))
        let collector = LlamaOutputCollector(continuation: pair.continuation)
        let runID = UUID()
        do {
            try state.begin(runID)
        } catch {
            pair.continuation.finish(throwing: error)
            return pair.stream
        }
        let task = Task.detached(priority: .userInitiated) { [modelKey, native, state] in
            defer { state.finish(runID) }
            do {
                try Task.checkCancellation()
                let input = try Self.input(from: request)
                let summary = try native.generate(input: input, collector: collector)
                let result = Self.result(
                    text: collector.completeText(),
                    modelKey: modelKey,
                    summary: summary
                )
                pair.continuation.yield(.completed(result))
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        pair.continuation.onTermination = { [native, state] _ in
            task.cancel()
            if state.requestCancellation(runID) { native.cancel() }
        }
        return pair.stream
    }

    func unload() async {
        if state.markUnloaded() { native.cancel() }
        await state.waitUntilIdle()
    }
}

private extension LlamaModelSession {
    static func input(from request: InferenceQuery) throws -> LlamaRunInput {
        try request.validate()
        switch request {
        case .text(let query):
            return input(messages: query.messages, mediaPaths: [], options: query.generation)
        case .vision(let query):
            let paths = try query.images.map(Self.localPath)
            return input(messages: query.messages, mediaPaths: paths, options: query.generation)
        default:
            throw LlamaAdapterError.unsupportedQuery
        }
    }

    static func input(
        messages: [InferenceMessage],
        mediaPaths: [String],
        options: TextQueryGenerationOptions
    ) -> LlamaRunInput {
        LlamaRunInput(
            roles: messages.map { $0.role.rawValue },
            contents: messages.map(\.text),
            mediaPaths: mediaPaths,
            maximumOutputTokens: options.maxOutputTokens,
            temperature: Float(options.temperature ?? 0),
            topP: Float(options.topP ?? 1),
            seed: UInt32(truncatingIfNeeded: options.seed ?? 0)
        )
    }

    static func localPath(_ reference: InferenceAssetReference) throws -> String {
        guard case .file(let url) = reference, url.isFileURL else {
            throw LlamaAdapterError.unsupportedQuery
        }
        return url.path
    }

    static func result(
        text: String,
        modelKey: ModelKey,
        summary: LlamaGenerationSummary
    ) -> RunResult {
        RunResult(
            text: text,
            model: modelKey,
            finishReason: summary.reachedEndToken ? .stop : .maximumTokens,
            usage: TokenUsage(
                promptTokens: summary.promptTokens,
                outputTokens: summary.outputTokens
            )
        )
    }
}

private final class LlamaSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRunID: UUID?
    private var unloaded = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func begin(_ runID: UUID) throws {
        try lock.withLock {
            guard activeRunID == nil, !unloaded else {
                throw LlamaAdapterError.sessionUnavailable
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
// swiftlint:enable file_length
