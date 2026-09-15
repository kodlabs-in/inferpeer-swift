/// A monotonic instant represented independently from wall-clock time.
public struct MonotonicInstant: Hashable, Comparable, Sendable {
    /// Nanoseconds elapsed from the clock implementation's private origin.
    public let nanoseconds: UInt64

    /// Creates an instant from a clock-relative nanosecond count.
    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    /// Orders instants by their clock-relative nanosecond count.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    /// Returns the nonnegative duration elapsed since an earlier instant.
    public func elapsed(since earlier: Self) -> Duration {
        guard self >= earlier else { return .zero }
        let elapsedNanoseconds = nanoseconds - earlier.nanoseconds
        let seconds = elapsedNanoseconds / 1_000_000_000
        let remainder = elapsedNanoseconds % 1_000_000_000
        return .seconds(Int64(seconds)) + .nanoseconds(Int64(remainder))
    }
}

/// A deterministic source of monotonic time for leases, deadlines, and heartbeats.
public protocol CoreClock: Sendable {
    /// Returns the current clock-relative instant.
    func now() -> MonotonicInstant
}

/// Monotonic system uptime clock used for production leases and heartbeat expiry.
public struct SystemCoreClock: CoreClock, Sendable {
    /// Creates a clock with no hidden resources.
    public init() {}

    /// Returns the current monotonic system-uptime instant.
    public func now() -> MonotonicInstant {
        MonotonicInstant(nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
}

/// Wall clock used only to establish a monotonic deadline at admission or recovery.
public protocol CoreWallClock: Sendable {
    /// Returns the current diagnostic wall-clock date.
    func now() -> Date
}

/// Production wall clock.
public struct SystemCoreWallClock: CoreWallClock, Sendable {
    /// Creates a wall clock with no hidden resources.
    public init() {}

    /// Returns the current date.
    public func now() -> Date {
        Date()
    }
}

extension MonotonicInstant {
    /// Advances this instant by a nonnegative duration, saturating at the maximum instant.
    public func advanced(by duration: Duration) -> Self {
        guard duration > .zero else { return self }
        let components = duration.components
        let seconds = UInt64(clamping: components.seconds)
        let secondsNanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !secondsNanoseconds.overflow else { return Self(nanoseconds: .max) }
        let fractionalNanoseconds = UInt64(clamping: components.attoseconds / 1_000_000_000)
        let durationNanoseconds = secondsNanoseconds.partialValue.addingReportingOverflow(
            fractionalNanoseconds
        )
        guard !durationNanoseconds.overflow else { return Self(nanoseconds: .max) }
        let result = nanoseconds.addingReportingOverflow(durationNanoseconds.partialValue)
        return Self(nanoseconds: result.overflow ? .max : result.partialValue)
    }
}
import Dispatch
import Foundation
