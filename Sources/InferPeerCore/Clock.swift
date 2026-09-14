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
