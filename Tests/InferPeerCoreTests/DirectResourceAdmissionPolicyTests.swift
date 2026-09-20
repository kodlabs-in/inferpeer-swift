import Foundation
import InferPeerCore
import Testing

@Suite("Direct resource lifecycle admission")
struct DirectResourceAdmissionPolicyTests {
    @Test("configuration rejects zero thermal recovery")
    func invalidConfiguration() throws {
        #expect(throws: DirectAdmissionConfigurationError.invalidThermalRecoveryInterval) {
            _ = try DirectResourceAdmissionConfiguration(thermalRecoveryInterval: .zero)
        }
    }

    @Test("host pause and background loss publish distinct denials")
    func hostLifecycleDenials() async throws {
        let policy = DirectResourceAdmissionPolicy()

        let paused = await policy.evaluate(input(sharingPaused: true))
        #expect(paused.denial == .pausedByHost)
        #expect(paused.availability == .pausedByHost)
        #expect(paused.error?.code == .workerUnavailable)

        let background = await policy.evaluate(input(lifecycle: .backgroundRestricted))
        #expect(background.denial == .backgroundRestricted)
        #expect(background.availability == .backgroundRestricted)
        #expect(background.error?.code == .backgroundRestricted)
    }

    @Test("unknown lifecycle and thermal telemetry fail closed")
    func unknownTelemetryFailsClosed() async throws {
        let policy = DirectResourceAdmissionPolicy()

        let lifecycle = await policy.evaluate(input(lifecycle: .unknown))
        #expect(lifecycle.denial == .backgroundRestricted)

        let thermal = await policy.evaluate(input(thermalState: .unknown))
        #expect(thermal.denial == .thermalLimited)
        #expect(thermal.error?.code == .thermalLimited)
    }

    @Test("serious denies admission and critical requests cooperative cancellation")
    func thermalDenialAndCancellation() async throws {
        let policy = DirectResourceAdmissionPolicy()

        let serious = await policy.evaluate(input(thermalState: .serious))
        #expect(serious.denial == .thermalLimited)
        #expect(!serious.requiresCooperativeCancellation)

        let critical = await policy.evaluate(input(thermalState: .critical))
        #expect(critical.denial == .thermalLimited)
        #expect(critical.requiresCooperativeCancellation)
    }

    @Test("fair thermal state selects a conservative profile")
    func fairUsesConservativeProfile() async throws {
        let policy = DirectResourceAdmissionPolicy()
        let result = await policy.evaluate(input(thermalState: .fair))

        #expect(result.isAdmitted)
        #expect(result.usesConservativeEngineProfile)
    }

    @Test("thermal admission reopens only after 30 continuous safe seconds")
    func thermalHysteresis() async throws {
        let clock = AdmissionTestClock()
        let policy = DirectResourceAdmissionPolicy(clock: clock)

        _ = await policy.evaluate(input(thermalState: .serious))
        clock.advance(by: .seconds(5))
        let recoveryStarted = await policy.evaluate(input())
        #expect(recoveryStarted.denial == .thermalLimited)

        clock.advance(by: .seconds(29))
        #expect(await policy.evaluate(input()).denial == .thermalLimited)

        clock.advance(by: .seconds(1))
        #expect(await policy.evaluate(input()).isAdmitted)
    }

    @Test("unsafe sample resets continuous thermal recovery")
    func thermalRecoveryResets() async throws {
        let clock = AdmissionTestClock()
        let policy = DirectResourceAdmissionPolicy(clock: clock)

        _ = await policy.evaluate(input(thermalState: .serious))
        _ = await policy.evaluate(input())
        clock.advance(by: .seconds(20))
        _ = await policy.evaluate(input(thermalState: .unknown))
        clock.advance(by: .seconds(20))
        #expect(await policy.evaluate(input()).denial == .thermalLimited)

        clock.advance(by: .seconds(30))
        #expect(await policy.evaluate(input()).isAdmitted)
    }

    @Test("remote battery use requires opt-in, known charge, and minimum level")
    func remoteBatteryPolicy() async throws {
        let denied = DirectResourceAdmissionPolicy()
        #expect(await denied.evaluate(input(power: try battery(80))).denial == .batteryPolicy)

        let configuration = try DirectResourceAdmissionConfiguration(
            allowsRemoteSharingOnBattery: true,
            minimumRemoteBatteryPercentage: try BatteryPercentage(20)
        )
        let allowed = DirectResourceAdmissionPolicy(configuration: configuration)
        #expect(await allowed.evaluate(input(power: try battery(19))).denial == .batteryPolicy)
        #expect(await allowed.evaluate(input(power: try battery(nil))).denial == .batteryPolicy)
        #expect(await allowed.evaluate(input(power: .unknown)).denial == .batteryPolicy)
        #expect(await allowed.evaluate(input(power: try battery(20))).isAdmitted)
        #expect(await allowed.evaluate(input(power: .externalPower)).isAdmitted)
    }

    @Test("local user work does not inherit remote charging-only policy")
    func localBatteryPolicyIsIndependent() async throws {
        let policy = DirectResourceAdmissionPolicy()
        let result = await policy.evaluate(
            input(origin: .localUserInitiated, power: try battery(1))
        )

        #expect(result.isAdmitted)
    }

    private func input(
        origin: DirectRunOrigin = .remote,
        sharingPaused: Bool = false,
        lifecycle: DirectHostLifecycleState = .foreground,
        thermalState: WorkerThermalState = .nominal,
        power: DirectPowerState = .externalPower
    ) -> DirectResourceAdmissionInput {
        DirectResourceAdmissionInput(
            origin: origin,
            sharingPaused: sharingPaused,
            lifecycle: lifecycle,
            thermalState: thermalState,
            power: power
        )
    }

    private func battery(_ percentage: UInt32?) throws -> DirectPowerState {
        guard let percentage else { return .battery(nil) }
        return .battery(try BatteryPercentage(percentage))
    }
}

private final class AdmissionTestClock: CoreClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant = MonotonicInstant(nanoseconds: 0)

    func now() -> MonotonicInstant {
        lock.withLock { instant }
    }

    func advance(by duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}
