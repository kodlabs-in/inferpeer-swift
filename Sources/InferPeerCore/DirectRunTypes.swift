import Foundation
import InferPeerInference
import InferPeerProtocol

/// Queue behavior requested for a run on its exact destination.
public enum RunQueuePolicy: Hashable, Sendable {
    /// Wait in the resource's bounded local queue.
    case bounded

    /// Reject immediately when the resource is busy.
    case rejectWhenBusy
}

/// Behavior when an installed model is not already loaded.
public enum MissingModelPolicy: Hashable, Sendable {
    /// Load a registered local artifact when resource policy permits.
    case prepareIfEligible

    /// Require the exact model to be ready already.
    case requireReady
}

/// Behavior when a remote connection is interrupted during execution.
public enum RunDisconnectPolicy: Hashable, Sendable {
    /// Cancel after the bounded same-resource recovery interval.
    case cancelAfter(Duration)
}

/// Options that never permit changing the selected destination.
public struct RunOptions: Hashable, Sendable {
    /// Default bounded behavior for a direct run.
    public static let `default` = Self()

    /// Optional caller-supplied stable request identity.
    public let requestID: RequestID?

    /// Total resource-side budget, including queueing and model loading.
    public let totalTimeout: Duration

    /// Selected resource's local queue behavior.
    public let queuePolicy: RunQueuePolicy

    /// Behavior when the selected model is not ready.
    public let missingModelPolicy: MissingModelPolicy

    /// Same-resource recovery behavior for remote connections.
    public let disconnectPolicy: RunDisconnectPolicy

    /// Creates direct-run options without permitting destination fallback.
    public init(
        requestID: RequestID? = nil,
        totalTimeout: Duration = .seconds(120),
        queuePolicy: RunQueuePolicy = .bounded,
        missingModelPolicy: MissingModelPolicy = .prepareIfEligible,
        disconnectPolicy: RunDisconnectPolicy = .cancelAfter(.seconds(30))
    ) {
        self.requestID = requestID
        self.totalTimeout = totalTimeout
        self.queuePolicy = queuePolicy
        self.missingModelPolicy = missingModelPolicy
        self.disconnectPolicy = disconnectPolicy
    }
}

/// Current state of one accepted direct-resource run.
public enum RunStatus: Equatable, Sendable {
    /// The resource accepted the run specification.
    case accepted

    /// The run is waiting in the selected resource's local queue.
    case queued(position: Int)

    /// The selected resource is preparing the exact model.
    case loadingModel(ModelKey)

    /// Inference is active on the selected resource.
    case running(ModelKey)

    /// Cooperative cancellation has been requested.
    case cancelling

    /// The successful terminal result committed.
    case completed

    /// A classified terminal failure committed.
    case failed(InferPeerError)

    /// Cancellation became the terminal outcome.
    case cancelled

    /// The original total deadline elapsed before completion.
    case expired

    /// Execution ended because its resource process or grant was lost.
    case interrupted(InferPeerError)
}

/// A bounded preprocessing stage reported before runtime execution begins.
public enum PreprocessingStage: String, Hashable, Sendable {
    /// Structural and policy validation is active.
    case validatingInput
    /// Bounded media decoding is active.
    case decodingMedia
    /// Model-specific token preparation is active.
    case tokenizing
}

/// One replaceable ASR segment with resource-relative timestamps.
public struct TranscriptSegment: Hashable, Sendable {
    /// Stable segment identity used to replace provisional revisions.
    public let id: String
    /// Monotonically increasing revision for this segment identity.
    public let revision: UInt64
    /// Resource-relative segment start.
    public let start: Duration
    /// Resource-relative segment end.
    public let end: Duration
    /// Transcript text for this revision.
    public let text: String
    /// Whether this segment revision is final.
    public let isFinal: Bool

    /// Creates one provisional or final transcript segment revision.
    public init(
        id: String,
        revision: UInt64,
        start: Duration,
        end: Duration,
        text: String,
        isFinal: Bool
    ) {
        self.id = id
        self.revision = revision
        self.start = start
        self.end = end
        self.text = text
        self.isFinal = isFinal
    }
}

/// Declared PCM sample representation for a synthesized-audio chunk.
public enum AudioSampleFormat: String, Hashable, Sendable {
    /// Native-endian 32-bit floating-point PCM.
    case float32
    /// Native-endian signed 16-bit PCM.
    case signedInt16
}

/// One ordered synthesized-audio chunk. Playback remains host-owned.
public struct AudioChunk: Hashable, Sendable {
    /// PCM representation of the sample bytes.
    public let format: AudioSampleFormat
    /// Frames per second.
    public let sampleRate: UInt32
    /// Interleaved channel count.
    public let channelCount: UInt32
    /// Absolute first-frame offset in the synthesized output.
    public let frameOffset: UInt64
    /// Bounded PCM sample bytes.
    public let samples: Data

    /// Creates one ordered synthesized-audio chunk.
    public init(
        format: AudioSampleFormat,
        sampleRate: UInt32,
        channelCount: UInt32,
        frameOffset: UInt64,
        samples: Data
    ) {
        self.format = format
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameOffset = frameOffset
        self.samples = samples
    }
}

/// Complete bounded output for one supported inference modality.
public enum RunResultContent: Hashable, Sendable {
    /// Complete generated text for text or vision inference.
    case text(String)

    /// Final revision of each transcription segment and actual language/mode.
    case transcription(
        segments: [TranscriptSegment],
        language: String,
        mode: TranscriptionMode
    )

    /// Authorized synthesized-audio asset plus its exact PCM layout.
    case speech(
        asset: InferenceAssetReceipt,
        format: AudioSampleFormat,
        sampleRate: UInt32,
        channelCount: UInt32,
        frameCount: UInt64
    )
}

/// The successful bounded output of a direct-resource run.
public struct RunResult: Hashable, Sendable {
    /// Complete modality-specific output.
    public let content: RunResultContent

    /// Compatibility view for text and transcription clients.
    public var text: String {
        switch content {
        case .text(let text):
            text
        case .transcription(let segments, _, _):
            segments.filter(\.isFinal).map(\.text).joined(separator: " ")
        case .speech:
            ""
        }
    }

    /// Exact model artifact that produced the output.
    public let model: ModelKey

    /// Runtime-reported completion reason.
    public let finishReason: GenerationFinishReason

    /// Measured prompt and output token counts.
    public let usage: TokenUsage

    /// Creates a successful text result.
    public init(
        text: String,
        model: ModelKey,
        finishReason: GenerationFinishReason,
        usage: TokenUsage
    ) {
        content = .text(text)
        self.model = model
        self.finishReason = finishReason
        self.usage = usage
    }

    /// Creates a successful typed result for any supported modality.
    public init(
        content: RunResultContent,
        model: ModelKey,
        finishReason: GenerationFinishReason,
        usage: TokenUsage
    ) {
        self.content = content
        self.model = model
        self.finishReason = finishReason
        self.usage = usage
    }
}

/// Ordered progress and output from one direct-resource run.
public enum RunEvent: Sendable {
    /// Admission committed with this exact model.
    case accepted(model: ModelKey)

    /// The run is waiting at a bounded queue position.
    case queued(position: Int)

    /// The exact model is being prepared.
    case loadingModel(ModelKey)

    /// Runtime execution started with this exact model.
    case started(model: ModelKey)

    /// Bounded input preparation before runtime execution.
    case preprocessing(PreprocessingStage)

    /// A valid incremental UTF-8 text fragment.
    case textDelta(String)

    /// A provisional or final timestamped transcription segment.
    case transcriptSegment(TranscriptSegment)

    /// Ordered synthesized-audio bytes with explicit format metadata.
    case audioChunk(AudioChunk)

    /// Measured usage for the completed run.
    case usage(TokenUsage)

    /// Successful terminal event.
    case completed(RunResult)

    /// Classified terminal failure event.
    case failed(InferPeerError)

    /// Cancellation terminal event.
    case cancelled

    /// The original request deadline elapsed.
    case expired

    /// The selected resource process or execution grant was lost.
    case interrupted(InferPeerError)
}

/// The single ordered output sequence exposed by a run handle.
public typealias RunEventStream = AsyncThrowingStream<RunEvent, any Error>
