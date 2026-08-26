import Foundation

/// A fixed window that begins at `start` and lasts for `duration` seconds.
///
/// All computations are pure functions of an injected `now`, keeping time math
/// deterministic and testable.
public struct Deadline: Equatable, Sendable {
    public let start: Date
    public let duration: TimeInterval

    public init(start: Date, duration: TimeInterval) {
        self.start = start
        self.duration = duration
    }

    /// The wall-clock instant the window ends.
    public var end: Date {
        start.addingTimeInterval(duration)
    }

    /// Time elapsed since `start`, clamped to be non-negative.
    public func elapsed(at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(start))
    }

    /// Time remaining until `end`, clamped to be non-negative.
    public func remaining(at now: Date) -> TimeInterval {
        max(0, end.timeIntervalSince(now))
    }

    /// Whether the window has reached or passed its end.
    public func isExpired(at now: Date) -> Bool {
        now >= end
    }
}
