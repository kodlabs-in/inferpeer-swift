/// Whether admission is for host-local work or a paired remote caller.
public enum DirectRunOrigin: Hashable, Sendable {
    /// A foreground user action owned by the resource's host app.
    case localUserInitiated

    /// Work requested by a paired remote app identity.
    case remote
}

/// Host lifecycle state relevant to heavy inference eligibility.
public enum DirectHostLifecycleState: Hashable, Sendable {
    /// The host is active and may execute heavy work.
    case foreground

    /// The host is backgrounded with an active execution grant.
    case backgroundAllowed

    /// The host is backgrounded without a usable execution grant.
    case backgroundRestricted

    /// The adapter cannot currently establish lifecycle eligibility.
    case unknown
}

/// Power-source and charge information supplied by the host adapter.
public enum DirectPowerState: Hashable, Sendable {
    /// External power is currently available.
    case externalPower

    /// The device is on battery; `nil` means charge is unavailable, not zero.
    case battery(BatteryPercentage?)

    /// The adapter cannot establish whether external power is available.
    case unknown
}

/// Stable reason a direct-resource admission was denied.
public enum DirectResourceAdmissionDenial: Hashable, Sendable {
    /// Sharing was explicitly paused by the host.
    case pausedByHost

    /// Lifecycle state or execution grants forbid heavy work.
    case backgroundRestricted

    /// Thermal telemetry is unsafe, unavailable, or inside recovery hysteresis.
    case thermalLimited

    /// Remote battery policy does not permit this request.
    case batteryPolicy
}

/// Host and platform signals evaluated before starting heavy inference.
public struct DirectResourceAdmissionInput: Hashable, Sendable {
    /// Whether the request is local or remote.
    public let origin: DirectRunOrigin

    /// Explicit host pause for resource sharing.
    public let sharingPaused: Bool

    /// Current host lifecycle eligibility.
    public let lifecycle: DirectHostLifecycleState

    /// Current coarse OS thermal signal.
    public let thermalState: WorkerThermalState

    /// Current power-source and charge information.
    public let power: DirectPowerState

    /// Creates one immutable policy input snapshot.
    public init(
        origin: DirectRunOrigin,
        sharingPaused: Bool,
        lifecycle: DirectHostLifecycleState,
        thermalState: WorkerThermalState,
        power: DirectPowerState
    ) {
        self.origin = origin
        self.sharingPaused = sharingPaused
        self.lifecycle = lifecycle
        self.thermalState = thermalState
        self.power = power
    }
}

/// Configurable remote-sharing policy with PRD defaults.
public struct DirectResourceAdmissionConfiguration: Hashable, Sendable {
    /// Default serious/critical recovery interval.
    public static let defaultThermalRecoveryInterval: Duration = .seconds(30)

    /// Default minimum charge for opted-in remote execution on battery.
    public static let defaultMinimumRemoteBatteryPercentage: BatteryPercentage = {
        guard let value = try? BatteryPercentage(20) else {
            preconditionFailure("A 20 percent battery floor must remain valid")
        }
        return value
    }()

    /// Default charging-only policy with a 20 percent remote battery floor.
    public static let standard = Self(
        allowsRemoteSharingOnBattery: false,
        minimumRemoteBatteryPercentage: defaultMinimumRemoteBatteryPercentage,
        thermalRecoveryInterval: defaultThermalRecoveryInterval,
        validated: ()
    )

    /// Whether paired callers may execute while the resource is on battery.
    public let allowsRemoteSharingOnBattery: Bool

    /// Required known charge when remote battery sharing is enabled.
    public let minimumRemoteBatteryPercentage: BatteryPercentage

    /// Continuous time below serious before thermal admission reopens.
    public let thermalRecoveryInterval: Duration

    /// Creates a policy using charging-only remote sharing by default.
    public init(
        allowsRemoteSharingOnBattery: Bool = false,
        minimumRemoteBatteryPercentage: BatteryPercentage = defaultMinimumRemoteBatteryPercentage,
        thermalRecoveryInterval: Duration = Self.defaultThermalRecoveryInterval
    ) throws {
        guard thermalRecoveryInterval > .zero else {
            throw DirectAdmissionConfigurationError.invalidThermalRecoveryInterval
        }
        self.allowsRemoteSharingOnBattery = allowsRemoteSharingOnBattery
        self.minimumRemoteBatteryPercentage = minimumRemoteBatteryPercentage
        self.thermalRecoveryInterval = thermalRecoveryInterval
    }

    private init(
        allowsRemoteSharingOnBattery: Bool,
        minimumRemoteBatteryPercentage: BatteryPercentage,
        thermalRecoveryInterval: Duration,
        validated _: Void
    ) {
        self.allowsRemoteSharingOnBattery = allowsRemoteSharingOnBattery
        self.minimumRemoteBatteryPercentage = minimumRemoteBatteryPercentage
        self.thermalRecoveryInterval = thermalRecoveryInterval
    }

}

/// Invalid lifecycle-admission configuration rejected before use.
public enum DirectAdmissionConfigurationError: Error, Equatable, Sendable {
    /// Thermal recovery must require a positive continuous interval.
    case invalidThermalRecoveryInterval
}

/// One policy evaluation, including cancellation and engine-profile signals.
public struct DirectResourceAdmissionEvaluation: Equatable, Sendable {
    /// Current execution availability published in the resource snapshot.
    public let availability: ExecutionAvailability

    /// Stable denial reason, or `nil` when admission is open.
    public let denial: DirectResourceAdmissionDenial?

    /// Typed public failure for a rejected admission.
    public let error: InferPeerError?

    /// Whether active heavy work should receive cooperative cancellation.
    public let requiresCooperativeCancellation: Bool

    /// Whether a fair thermal state requests a conservative engine profile.
    public let usesConservativeEngineProfile: Bool

    /// Remaining thermal recovery interval when known.
    public let retryAfter: Duration?

    /// Whether a new heavy operation may be admitted.
    public var isAdmitted: Bool { denial == nil }
}

/// Stateful admission evaluator implementing thermal recovery hysteresis.
public actor DirectResourceAdmissionPolicy {
    private let configuration: DirectResourceAdmissionConfiguration
    private let clock: any CoreClock
    private var isThermallyLatched = false
    private var thermalRecoveryStartedAt: MonotonicInstant?

    /// Creates an adapter-neutral policy evaluator.
    public init(
        configuration: DirectResourceAdmissionConfiguration = .standard,
        clock: any CoreClock = SystemCoreClock()
    ) {
        self.configuration = configuration
        self.clock = clock
    }

    /// Evaluates the latest complete host snapshot and advances thermal hysteresis.
    public func evaluate(_ input: DirectResourceAdmissionInput) -> DirectResourceAdmissionEvaluation
    {
        let thermal = evaluateThermal(input.thermalState, at: clock.now())
        let denial = admissionDenial(input, thermalDenied: thermal.denied)
        return DirectResourceAdmissionEvaluation(
            availability: availability(for: denial),
            denial: denial,
            error: error(for: denial),
            requiresCooperativeCancellation: input.thermalState == .critical,
            usesConservativeEngineProfile: input.thermalState == .fair && denial == nil,
            retryAfter: denial == .thermalLimited ? thermal.recoveryRemaining : nil
        )
    }
}

extension DirectResourceAdmissionPolicy {
    private func evaluateThermal(
        _ state: WorkerThermalState,
        at now: MonotonicInstant
    ) -> (denied: Bool, recoveryRemaining: Duration?) {
        switch state {
        case .serious, .critical:
            isThermallyLatched = true
            thermalRecoveryStartedAt = nil
            return (true, nil)
        case .unknown:
            thermalRecoveryStartedAt = nil
            return (true, nil)
        case .nominal, .fair:
            return evaluateThermalRecovery(at: now)
        }
    }

    private func evaluateThermalRecovery(
        at now: MonotonicInstant
    ) -> (denied: Bool, recoveryRemaining: Duration?) {
        guard isThermallyLatched else { return (false, nil) }
        guard let startedAt = thermalRecoveryStartedAt else {
            thermalRecoveryStartedAt = now
            return (true, configuration.thermalRecoveryInterval)
        }
        let elapsed = now.elapsed(since: startedAt)
        guard elapsed >= configuration.thermalRecoveryInterval else {
            return (true, configuration.thermalRecoveryInterval - elapsed)
        }
        isThermallyLatched = false
        thermalRecoveryStartedAt = nil
        return (false, nil)
    }

    private func admissionDenial(
        _ input: DirectResourceAdmissionInput,
        thermalDenied: Bool
    ) -> DirectResourceAdmissionDenial? {
        if input.sharingPaused, input.origin == .remote { return .pausedByHost }
        guard lifecycleAllowsAdmission(input.lifecycle) else { return .backgroundRestricted }
        if thermalDenied { return .thermalLimited }
        guard remotePowerAllowsAdmission(input) else { return .batteryPolicy }
        return nil
    }

    private func lifecycleAllowsAdmission(_ state: DirectHostLifecycleState) -> Bool {
        switch state {
        case .foreground, .backgroundAllowed: true
        case .backgroundRestricted, .unknown: false
        }
    }

    private func remotePowerAllowsAdmission(_ input: DirectResourceAdmissionInput) -> Bool {
        guard input.origin == .remote else { return true }
        return switch input.power {
        case .externalPower:
            true
        case .battery(let percentage):
            configuration.allowsRemoteSharingOnBattery
                && (percentage?.value ?? 0) >= configuration.minimumRemoteBatteryPercentage.value
        case .unknown:
            false
        }
    }

    private func availability(
        for denial: DirectResourceAdmissionDenial?
    ) -> ExecutionAvailability {
        switch denial {
        case nil: .available
        case .pausedByHost: .pausedByHost
        case .backgroundRestricted: .backgroundRestricted
        case .thermalLimited: .thermalLimited
        case .batteryPolicy: .unavailable
        }
    }

    private func error(for denial: DirectResourceAdmissionDenial?) -> InferPeerError? {
        switch denial {
        case nil:
            nil
        case .pausedByHost:
            InferPeerError(code: .workerUnavailable, isRetryable: true)
        case .backgroundRestricted:
            InferPeerError(code: .backgroundRestricted, isRetryable: true)
        case .thermalLimited:
            InferPeerError(code: .thermalLimited, isRetryable: true)
        case .batteryPolicy:
            InferPeerError(code: .batteryPolicy, isRetryable: true)
        }
    }
}
