import Foundation
import InferPeerInference

/// A text-inference phase whose duration can inform future scheduling.
public enum InferenceTimingPhase: String, Equatable, Sendable {
    /// Loading model weights and tokenizer state.
    case modelLoad

    /// Applying the chat template and processing prompt tokens.
    case promptProcessing

    /// Producing output tokens.
    case generation
}

/// A LAN operation whose measured duration can inform future scheduling.
public enum NetworkTimingOperation: String, Equatable, Sendable {
    /// Establishing an authenticated transport session.
    case connection

    /// Sending request input to a coordinator or worker.
    case inputTransfer

    /// Receiving generated events from a coordinator or worker.
    case outputTransfer
}

/// Invalid telemetry rejected before it reaches observers.
public enum TelemetryMeasurementError: Error, Equatable, Sendable {
    /// A supplied duration was negative.
    case negativeDuration
}

/// One content-free measured inference duration.
public struct InferenceTimingMeasurement: Equatable, Sendable {
    /// The exact model involved in the measurement.
    public let model: ModelReference

    /// The measured inference phase.
    public let phase: InferenceTimingPhase

    /// Monotonic elapsed time for the phase.
    public let duration: Duration

    /// Creates a validated inference timing without prompt or output content.
    public init(model: ModelReference, phase: InferenceTimingPhase, duration: Duration) throws {
        guard duration >= .zero else { throw TelemetryMeasurementError.negativeDuration }
        self.model = model
        self.phase = phase
        self.duration = duration
    }
}

/// One content-free measured LAN duration.
public struct NetworkTimingMeasurement: Equatable, Sendable {
    /// The measured transport operation.
    public let operation: NetworkTimingOperation

    /// Monotonic elapsed time for the operation.
    public let duration: Duration

    /// Transferred byte count when the transport can report it.
    public let byteCount: UInt64?

    /// Creates a validated transport timing without network payloads.
    public init(
        operation: NetworkTimingOperation,
        duration: Duration,
        byteCount: UInt64? = nil
    ) throws {
        guard duration >= .zero else { throw TelemetryMeasurementError.negativeDuration }
        self.operation = operation
        self.duration = duration
        self.byteCount = byteCount
    }
}

/// A privacy-preserving local timing event.
public enum TelemetryEvent: Equatable, Sendable {
    /// A model execution phase completed.
    case inference(InferenceTimingMeasurement)

    /// A LAN operation completed.
    case network(NetworkTimingMeasurement)
}

/// A monotonic stopwatch suitable for constructing measured telemetry events.
public struct TelemetryStopwatch: Sendable {
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant

    /// Starts the stopwatch immediately.
    public init() {
        startedAt = clock.now
    }

    /// Returns monotonic time since this stopwatch was created.
    public func elapsed() -> Duration {
        startedAt.duration(to: clock.now)
    }
}

/// In-memory, bounded telemetry fan-out that cannot accept inference content.
public actor LocalTelemetryRecorder {
    private let broadcaster = StreamBroadcaster<TelemetryEvent>()

    /// Creates an empty recorder with no background work.
    public init() {}

    /// Returns a bounded stream of subsequent local measurements.
    nonisolated public func events(bufferingLimit: Int) -> AsyncStream<TelemetryEvent> {
        guard bufferingLimit > 0 else { return AsyncStream { $0.finish() } }
        let identifier = UUID()
        let broadcaster = self.broadcaster
        let pair = AsyncStream.makeStream(
            of: TelemetryEvent.self,
            bufferingPolicy: .bufferingNewest(bufferingLimit)
        )
        broadcaster.add(pair.continuation, identifier: identifier)
        pair.continuation.onTermination = { _ in
            broadcaster.remove(identifier: identifier)
        }
        return pair.stream
    }

    /// Publishes a content-free timing measurement to current observers.
    public func record(_ event: TelemetryEvent) {
        broadcaster.yield(event)
    }
}
