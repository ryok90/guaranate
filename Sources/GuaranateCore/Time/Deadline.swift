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

    /// Returns a copy whose end is moved by `interval` seconds relative to
    /// `now`. A positive interval extends the window; a negative one shortens
    /// it. The end is floored at `now`, so a shortened window never ends in the
    /// past — at the floor the result is already expired. Pure in `now`; no
    /// wall-clock read.
    public func adjustingEnd(by interval: TimeInterval, at now: Date) -> Deadline {
        let target = max(now, end.addingTimeInterval(interval))
        return Deadline(start: start, duration: target.timeIntervalSince(start))
    }

    /// Returns a copy extended by `interval` seconds (later end). `interval` is
    /// expected to be non-negative; the end never moves earlier than `now`.
    public func extended(by interval: TimeInterval, at now: Date) -> Deadline {
        adjustingEnd(by: interval, at: now)
    }

    /// Returns a copy shortened by `interval` seconds (earlier end), floored so
    /// the end never lands before `now`. `interval` is expected to be
    /// non-negative.
    public func shortened(by interval: TimeInterval, at now: Date) -> Deadline {
        adjustingEnd(by: -interval, at: now)
    }
}
