import Foundation
@testable import InferPeer
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import Testing

extension DirectResourceFacadeTests {
    @Test("A v2 runtime executes vision and preserves preprocessing progress")
    func directRuntimeExecutesVision() async throws {
        let fixture = try DirectMultimodalFixture()
        let query = InferenceQuery.vision(
            model: .exact(fixture.model),
            messages: [.user("Describe the image")],
            images: [.file(URL(fileURLWithPath: "/tmp/direct-vision.png"))]
        )

        let handle = try await fixture.facade.run(query, resourceId: .local)
        let result = try await handle.result()
        let events = try await collect(handle.events)

        #expect(result.content == .text(DirectMultimodalRuntime.visionText))
        #expect(
            events.contains { event in
                guard case .preprocessing(.decodingMedia) = event else { return false }
                return true
            })
        #expect(
            events.contains { event in
                guard case .textDelta(DirectMultimodalRuntime.visionText) = event else {
                    return false
                }
                return true
            })
        #expect(await fixture.runtime.executedTasks() == [.imageUnderstanding])
    }

    @Test("A v2 runtime streams replaceable transcription segments")
    func directRuntimeExecutesTranscription() async throws {
        let fixture = try DirectMultimodalFixture()
        let query = InferenceQuery.transcribe(
            model: .exact(fixture.model),
            audio: .file(URL(fileURLWithPath: "/tmp/direct-audio.wav")),
            language: "en"
        )

        let handle = try await fixture.facade.run(query, resourceId: .local)
        let result = try await handle.result()
        let events = try await collect(handle.events)

        #expect(result.text == DirectMultimodalRuntime.transcript.text)
        #expect(
            events.contains { event in
                guard case .transcriptSegment(DirectMultimodalRuntime.transcript) = event else {
                    return false
                }
                return true
            })
        #expect(await fixture.runtime.executedTasks() == [.transcribe])
    }

    @Test("A v2 runtime resolves a speech default and streams host-owned PCM")
    func directRuntimeExecutesSpeechSynthesis() async throws {
        let fixture = try DirectMultimodalFixture()
        let query = InferenceQuery.synthesizeSpeech(
            model: .taskDefault,
            voiceID: "test-voice",
            text: "Hello from InferPeer"
        )

        let handle = try await fixture.facade.run(query, resourceId: .local)
        let result = try await handle.result()
        let events = try await collect(handle.events)

        #expect(
            result.content == DirectMultimodalRuntime.speechResult(model: fixture.model).content)
        #expect(
            events.contains { event in
                guard case .audioChunk(DirectMultimodalRuntime.audioChunk) = event else {
                    return false
                }
                return true
            })
        #expect(await fixture.runtime.executedModels() == [fixture.model])
    }

    @Test("Direct-runtime capabilities and execution availability are truthful")
    func directRuntimeAdvertisesConfiguredTasks() async throws {
        let fixture = try DirectMultimodalFixture()
        let local = try #require(await fixture.facade.resources().first)

        #expect(local.execution == .available)
        #expect(local.capabilities.supportedTasks == Set(InferenceTask.allCases))
        #expect(local.models.first?.supportedTasks == Set(InferenceTask.allCases))
    }

    @Test("A runtime without an executable model stays locally unavailable")
    func directRuntimeWithoutCapabilitiesIsUnavailable() async throws {
        let runtime = DirectMultimodalRuntime()
        let facade = try InferPeer(
            configuration: InferPeerConfiguration(
                localResource: LocalResourceConfiguration(
                    displayName: "Empty Test Mac",
                    platform: PlatformDescriptor(
                        operatingSystem: .macOS,
                        operatingSystemVersion: "test"
                    )
                ),
                directRuntime: runtime
            )
        )

        let local = try #require(await facade.resources().first)
        #expect(local.execution == .unavailable)
        #expect(local.capabilities.supportedTasks.isEmpty)
    }

    @Test("A task absent from a model capability fails before runtime execution")
    func directRuntimeRejectsUnsupportedModelTask() async throws {
        let runtime = DirectMultimodalRuntime()
        let artifact = try DirectMultimodalFixture.makeArtifact()
        let model = artifact.descriptor.reference
        let facade = try DirectMultimodalFixture.makeFacade(
            runtime: runtime,
            artifact: artifact,
            tasks: [.imageUnderstanding]
        )
        let query = InferenceQuery.transcribe(
            model: .exact(model),
            audio: .receipt(InferenceAssetReceipt(rawValue: "audio-receipt"))
        )

        do {
            _ = try await facade.run(query, resourceId: .local)
            Issue.record("An unsupported model task reached the direct runtime")
        } catch let error as InferPeerError {
            #expect(error.code == .unsupportedTask)
        }
        #expect(await runtime.executedTasks().isEmpty)
    }

    @Test("A direct runtime cannot substitute a different model in its result")
    func directRuntimeResultMustMatchTheAdmittedModel() async throws {
        let substitutedID = try #require(ModelID(rawValue: "substituted-model"))
        let substitutedModel = try ModelReference(modelID: substitutedID, revision: "1")
        let runtime = DirectMultimodalRuntime(resultModelOverride: substitutedModel)
        let artifact = try DirectMultimodalFixture.makeArtifact()
        let facade = try DirectMultimodalFixture.makeFacade(
            runtime: runtime,
            artifact: artifact,
            tasks: [.imageUnderstanding]
        )
        let query = InferenceQuery.vision(
            model: .exact(artifact.descriptor.reference),
            messages: [.user("Describe this")],
            images: [.receipt(InferenceAssetReceipt(rawValue: "image-receipt"))]
        )

        let handle = try await facade.run(query, resourceId: .local)
        do {
            _ = try await handle.result()
            Issue.record("A runtime substituted a different model")
        } catch let error as InferPeerError {
            #expect(error.code == .internal)
        }
    }

    private func collect(_ stream: RunEventStream) async throws -> [RunEvent] {
        var events: [RunEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }
}

private struct DirectMultimodalFixture {
    let runtime: DirectMultimodalRuntime
    let model: ModelKey
    let facade: InferPeer

    init() throws {
        runtime = DirectMultimodalRuntime()
        let artifact = try Self.makeArtifact()
        model = artifact.descriptor.reference
        facade = try Self.makeFacade(
            runtime: runtime,
            artifact: artifact,
            tasks: Set(InferenceTask.allCases)
        )
    }

    static func makeFacade(
        runtime: DirectMultimodalRuntime,
        artifact: LocalModelArtifact,
        tasks: Set<InferenceTask>
    ) throws -> InferPeer {
        let model = artifact.descriptor.reference
        return try InferPeer(
            configuration: InferPeerConfiguration(
                localResource: LocalResourceConfiguration(
                    displayName: "Multimodal Test Mac",
                    platform: PlatformDescriptor(
                        operatingSystem: .macOS,
                        operatingSystemVersion: "test"
                    )
                ),
                directRuntime: runtime,
                localModels: [artifact],
                localModelTasks: [model: tasks],
                defaultModels: Dictionary(
                    uniqueKeysWithValues: tasks.map { ($0, model) }
                )
            )
        )
    }

    static func makeArtifact() throws -> LocalModelArtifact {
        let modelID = try #require(ModelID(rawValue: "direct-multimodal-model"))
        let reference = try ModelReference(modelID: modelID, revision: "1")
        let descriptor = try ModelDescriptor(
            reference: reference,
            runtimeFormat: .mlx,
            metadata: try ModelMetadata(
                quantization: "test",
                tokenizer: "test",
                chatTemplate: "test",
                license: "test"
            ),
            contextTokenLimit: 1_024,
            contentDigest: try ModelContentDigest(bytes: Data(repeating: 0x6A, count: 32)),
            measuredMemoryBytes: 1
        )
        return try LocalModelArtifact(
            descriptor: descriptor,
            directoryURL: URL(fileURLWithPath: "/tmp/direct-multimodal-model")
        )
    }
}

private actor DirectMultimodalRuntime: DirectInferenceRuntime {
    static let visionText = "A mountain reflected in a lake."
    static let transcript = TranscriptSegment(
        id: "segment-1",
        revision: 1,
        start: .zero,
        end: .seconds(1),
        text: "Testing direct transcription.",
        isFinal: true
    )
    static let audioChunk = AudioChunk(
        format: .signedInt16,
        sampleRate: 24_000,
        channelCount: 1,
        frameOffset: 0,
        samples: Data([0, 1, 2, 3])
    )

    private var executions: [DirectRuntimeExecution] = []
    private let resultModelOverride: ModelKey?

    init(resultModelOverride: ModelKey? = nil) {
        self.resultModelOverride = resultModelOverride
    }

    func estimateResources(
        for query: InferenceQuery,
        using model: ModelDescriptor
    ) async throws -> InferenceResourceEstimate {
        await Task.yield()
        return try InferenceResourceEstimate(peakMemoryBytes: 1)
    }

    func loadModel(_ model: LocalModelArtifact) async throws {
        await Task.yield()
    }

    func unloadModel(_ reference: ModelKey) async throws {
        await Task.yield()
    }

    func execute(_ execution: DirectRuntimeExecution) async throws -> DirectRuntimeEventStream {
        await Task.yield()
        executions.append(execution)
        let resultModel = resultModelOverride ?? execution.model
        let pair = DirectRuntimeEventStream.makeStream()
        switch execution.query {
        case .vision:
            pair.continuation.yield(.preprocessing(.decodingMedia))
            pair.continuation.yield(.textDelta(Self.visionText))
            pair.continuation.yield(
                .completed(Self.textResult(Self.visionText, model: resultModel))
            )
        case .audioTranscription:
            pair.continuation.yield(.transcriptSegment(Self.transcript))
            pair.continuation.yield(
                .completed(Self.transcriptionResult(model: resultModel))
            )
        case .speechSynthesis:
            pair.continuation.yield(.audioChunk(Self.audioChunk))
            pair.continuation.yield(.completed(Self.speechResult(model: resultModel)))
        case .text:
            pair.continuation.yield(.completed(Self.textResult("text", model: resultModel)))
        }
        pair.continuation.finish()
        return pair.stream
    }

    func cancel(attemptID: AttemptID) async {
        await Task.yield()
    }

    func executedTasks() -> [InferenceTask] {
        executions.map(\.query.task)
    }

    func executedModels() -> [ModelKey] {
        executions.map(\.model)
    }

    static func speechResult(model: ModelKey) -> RunResult {
        RunResult(
            content: .speech(
                asset: InferenceAssetReceipt(rawValue: "synthesized-audio"),
                format: audioChunk.format,
                sampleRate: audioChunk.sampleRate,
                channelCount: audioChunk.channelCount,
                frameCount: 2
            ),
            model: model,
            finishReason: .stop,
            usage: TokenUsage(promptTokens: 3, outputTokens: 0)
        )
    }

    private static func textResult(_ text: String, model: ModelKey) -> RunResult {
        RunResult(
            text: text,
            model: model,
            finishReason: .stop,
            usage: TokenUsage(promptTokens: 4, outputTokens: 6)
        )
    }

    private static func transcriptionResult(model: ModelKey) -> RunResult {
        RunResult(
            content: .transcription(
                segments: [transcript],
                language: "en",
                mode: .transcription
            ),
            model: model,
            finishReason: .stop,
            usage: TokenUsage(promptTokens: 0, outputTokens: 4)
        )
    }
}
