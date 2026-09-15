import InferPeerInference
import InferPeerProtocol

/// Host-controlled worker participation in scheduling.
public enum WorkerParticipationState: String, Equatable, Sendable {
    /// The worker may accept new attempts.
    case available

    /// Existing attempts may finish, but new attempts are not admitted.
    case draining

    /// The worker must not execute attempts.
    case unavailable
}

/// A portable thermal signal used for worker admission.
public enum WorkerThermalState: String, Equatable, Sendable {
    /// The platform cannot report a thermal signal.
    case unknown

    /// The device has no meaningful thermal pressure.
    case nominal

    /// The device has elevated but acceptable thermal pressure.
    case fair

    /// The device should reject new inference work.
    case serious

    /// The device must reject inference work.
    case critical

    /// Whether the state permits a new attempt offer.
    public var permitsAdmission: Bool {
        switch self {
        case .unknown, .nominal, .fair:
            true
        case .serious, .critical:
            false
        }
    }
}

/// Host and platform conditions relevant to worker admission.
public struct WorkerCondition: Equatable, Sendable {
    /// Host-controlled participation.
    public let participation: WorkerParticipationState

    /// The latest portable thermal signal.
    public let thermalState: WorkerThermalState

    /// Whether the host reports low-power mode.
    public let lowPowerModeEnabled: Bool?

    /// Creates a worker condition snapshot.
    public init(
        participation: WorkerParticipationState,
        thermalState: WorkerThermalState,
        lowPowerModeEnabled: Bool?
    ) {
        self.participation = participation
        self.thermalState = thermalState
        self.lowPowerModeEnabled = lowPowerModeEnabled
    }
}

/// Current worker capacity and optional app-memory availability.
public struct WorkerLoad: Equatable, Sendable {
    /// Currently active generations.
    public let activeGenerations: UInt32

    /// Maximum concurrent generations admitted by the worker.
    public let generationCapacity: UInt32

    /// Memory currently available to the host app, when measurable.
    public let availableAppMemoryBytes: UInt64?

    /// Creates a worker load snapshot.
    public init(
        activeGenerations: UInt32,
        generationCapacity: UInt32,
        availableAppMemoryBytes: UInt64?
    ) {
        self.activeGenerations = activeGenerations
        self.generationCapacity = generationCapacity
        self.availableAppMemoryBytes = availableAppMemoryBytes
    }

    /// Whether the worker reports a free execution slot.
    public var hasAvailableSlot: Bool {
        generationCapacity > 0 && activeGenerations < generationCapacity
    }
}

/// Identity, heartbeat, condition, and load reported for one worker.
public struct WorkerSnapshot: Equatable, Sendable {
    /// The authenticated worker identity.
    public let peerID: PeerID

    /// Whether current cluster membership authorizes inference.
    public let isAuthorized: Bool

    /// The coordinator-local monotonic time of the last heartbeat.
    public let lastHeartbeat: MonotonicInstant

    /// Host and platform admission conditions.
    public let condition: WorkerCondition

    /// Current capacity and memory availability.
    public let load: WorkerLoad

    /// Creates a worker snapshot.
    public init(
        peerID: PeerID,
        isAuthorized: Bool,
        lastHeartbeat: MonotonicInstant,
        condition: WorkerCondition,
        load: WorkerLoad
    ) {
        self.peerID = peerID
        self.isAuthorized = isAuthorized
        self.lastHeartbeat = lastHeartbeat
        self.condition = condition
        self.load = load
    }
}

/// Queue and network timing estimates outside the inference backend.
public struct SchedulingTimings: Equatable, Sendable {
    /// Estimated wait before this worker can begin the attempt.
    public let queueDelay: Duration

    /// Estimated request transfer time, when known.
    public let inputTransferDuration: Duration?

    /// Creates scheduling timing inputs.
    public init(queueDelay: Duration, inputTransferDuration: Duration?) {
        self.queueDelay = queueDelay
        self.inputTransferDuration = inputTransferDuration
    }
}

/// One exact model and worker pairing considered by the scheduler.
public struct SchedulingCandidate: Equatable, Sendable {
    /// The candidate worker.
    public let worker: WorkerSnapshot

    /// The exact model revision this candidate can execute.
    public let model: ModelReference

    /// Whether the exact model is already loaded.
    public let isModelLoaded: Bool

    /// Backend-provided request-specific estimates.
    public let estimate: InferenceResourceEstimate

    /// Coordinator and network timing estimates.
    public let timings: SchedulingTimings

    /// Creates one scheduler candidate.
    public init(
        worker: WorkerSnapshot,
        model: ModelReference,
        isModelLoaded: Bool,
        estimate: InferenceResourceEstimate,
        timings: SchedulingTimings
    ) {
        self.worker = worker
        self.model = model
        self.isModelLoaded = isModelLoaded
        self.estimate = estimate
        self.timings = timings
    }
}

/// Deterministic values used only when a measured scheduling input is unavailable.
public struct SchedulingFallbacks: Equatable, Sendable {
    /// Conservative deterministic estimates used before worker benchmarks exist.
    public static let standard = Self(
        validatedModelLoadDuration: .seconds(5),
        promptProcessingDuration: .seconds(1),
        inputTransferDuration: .milliseconds(100),
        generationTokensPerSecond: 10
    )

    /// Fallback model loading duration.
    public let modelLoadDuration: Duration

    /// Fallback prompt processing duration.
    public let promptProcessingDuration: Duration

    /// Fallback input transfer duration.
    public let inputTransferDuration: Duration

    /// Fallback generation throughput.
    public let generationTokensPerSecond: Double

    /// Creates validated deterministic fallback estimates.
    public init(
        modelLoadDuration: Duration,
        promptProcessingDuration: Duration,
        inputTransferDuration: Duration,
        generationTokensPerSecond: Double
    ) throws {
        try SchedulerConfiguration.validate(modelLoadDuration)
        try SchedulerConfiguration.validate(promptProcessingDuration)
        try SchedulerConfiguration.validate(inputTransferDuration)
        guard generationTokensPerSecond.isFinite, generationTokensPerSecond > 0 else {
            throw SchedulerConfigurationError.invalidGenerationRate
        }
        self.modelLoadDuration = modelLoadDuration
        self.promptProcessingDuration = promptProcessingDuration
        self.inputTransferDuration = inputTransferDuration
        self.generationTokensPerSecond = generationTokensPerSecond
    }

    private init(
        validatedModelLoadDuration: Duration,
        promptProcessingDuration: Duration,
        inputTransferDuration: Duration,
        generationTokensPerSecond: Double
    ) {
        modelLoadDuration = validatedModelLoadDuration
        self.promptProcessingDuration = promptProcessingDuration
        self.inputTransferDuration = inputTransferDuration
        self.generationTokensPerSecond = generationTokensPerSecond
    }
}

/// Configurable scheduler timing and preference policy.
public struct SchedulerConfiguration: Equatable, Sendable {
    /// Deterministic demo defaults used until measurements replace fallback estimates.
    public static let standard = Self(
        validatedHeartbeatTimeout: .seconds(15),
        warmModelPreferenceTolerance: .seconds(2),
        lowPowerModePenalty: .seconds(5),
        fallbacks: .standard
    )

    /// Maximum elapsed time since an executable worker heartbeat.
    public let heartbeatTimeout: Duration

    /// Maximum score difference within which an already-loaded model is preferred.
    public let warmModelPreferenceTolerance: Duration

    /// Score penalty applied when low-power mode is explicitly enabled.
    public let lowPowerModePenalty: Duration

    /// Deterministic estimates for unavailable measurements.
    public let fallbacks: SchedulingFallbacks

    /// Creates validated scheduler configuration.
    public init(
        heartbeatTimeout: Duration,
        warmModelPreferenceTolerance: Duration,
        lowPowerModePenalty: Duration,
        fallbacks: SchedulingFallbacks
    ) throws {
        try Self.validate(heartbeatTimeout)
        try Self.validate(warmModelPreferenceTolerance)
        try Self.validate(lowPowerModePenalty)
        self.heartbeatTimeout = heartbeatTimeout
        self.warmModelPreferenceTolerance = warmModelPreferenceTolerance
        self.lowPowerModePenalty = lowPowerModePenalty
        self.fallbacks = fallbacks
    }

    fileprivate static func validate(_ duration: Duration) throws {
        guard duration >= .zero else {
            throw SchedulerConfigurationError.negativeDuration
        }
    }

    private init(
        validatedHeartbeatTimeout: Duration,
        warmModelPreferenceTolerance: Duration,
        lowPowerModePenalty: Duration,
        fallbacks: SchedulingFallbacks
    ) {
        heartbeatTimeout = validatedHeartbeatTimeout
        self.warmModelPreferenceTolerance = warmModelPreferenceTolerance
        self.lowPowerModePenalty = lowPowerModePenalty
        self.fallbacks = fallbacks
    }
}

/// A malformed scheduler configuration.
public enum SchedulerConfigurationError: Error, Equatable, Sendable {
    /// A configured timing was negative.
    case negativeDuration

    /// A generation-rate fallback was zero, negative, or not finite.
    case invalidGenerationRate
}

/// The worker and exact model selected for one attempt.
public struct ScheduledWorker: Equatable, Sendable {
    /// The authenticated worker identity.
    public let peerID: PeerID

    /// The exact selected model revision.
    public let model: ModelReference

    /// The estimated time until generation completes.
    public let estimatedCompletionDuration: Duration
}

/// Selects an eligible worker and exact model for one request.
public protocol SchedulerPolicy: Sendable {
    /// Returns the preferred eligible worker, or `nil` when none can accept the request.
    func selectWorker(
        for request: TextGenerationRequest,
        from candidates: [SchedulingCandidate],
        at now: MonotonicInstant
    ) -> ScheduledWorker?
}
