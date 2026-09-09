import Darwin
import Foundation

/// Errors surfaced while registering interest in this process's own signals.
public enum SignalWatchError: Error, Equatable, CustomStringConvertible {
    case cannotWatch(signal: Int32, code: Int32)

    public var description: String {
        switch self {
        case .cannotWatch(let signal, let code):
            return "Cannot watch signal \(signal): \(String(cString: strerror(code)))"
        }
    }
}

/// A kernel record of signals that arrive, kept independently of their disposition.
///
/// A supervisor that relays signals rather than dying of them has to ignore their
/// default dispositions, and on this platform setting a disposition to `SIG_IGN`
/// discards anything already pending for it. Registering interest *first* is
/// therefore the only order in which a signal arriving during startup cannot
/// vanish: `kqueue` records the note whatever the disposition is, and the record
/// outlives both an ignored signal and a stopped process, so a `SIGTERM` sent to a
/// paused session is still there to relay once something continues it.
///
/// `DispatchSource.makeSignalSource` cannot offer that: it registers on
/// libdispatch's own queue, so `resume()` returns before the kernel knows about
/// the watch and the gap stays open for as long as that takes.
public final class SignalNotes: Sendable {
    /// Becomes readable while at least one watched signal has an unread note.
    public let descriptor: Int32

    /// Registers every signal in `signals` before returning, so a caller may change
    /// their dispositions afterwards without opening a gap.
    public init(watching signals: [Int32]) throws {
        let queue = kqueue()
        guard queue >= 0 else {
            throw SignalWatchError.cannotWatch(signal: signals.first ?? 0, code: errno)
        }

        // One owner for the descriptor on every failing path: closing it twice
        // could hit an unrelated descriptor opened onto the same number in between.
        var handedOff = false
        defer { if !handedOff { Darwin.close(queue) } }

        // Registered one at a time so a failure names the signal it belongs to.
        for signal in signals {
            var registration = kevent(
                ident: UInt(signal),
                filter: Int16(EVFILT_SIGNAL),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
                fflags: 0,
                data: 0,
                udata: nil
            )
            guard kevent(queue, &registration, 1, nil, 0, nil) != -1 else {
                throw SignalWatchError.cannotWatch(signal: signal, code: errno)
            }
        }

        handedOff = true
        self.descriptor = queue
    }

    /// The signals with notes waiting, if any. Never blocks.
    ///
    /// Repeat arrivals of one signal coalesce into a single note, exactly as they
    /// do for a dispatch signal source: a relay is per signal, not per delivery.
    public func drain(upTo limit: Int = 16) -> [Int32] {
        // `kevent` names both a struct and a function here, so the struct is spelled
        // out; an unqualified `[kevent]` resolves to an array of the function.
        var events = [Darwin.kevent](repeating: Darwin.kevent(), count: limit)
        var immediately = timespec(tv_sec: 0, tv_nsec: 0)
        while true {
            let count = kevent(descriptor, nil, 0, &events, Int32(limit), &immediately)
            if count < 0 {
                guard errno == EINTR else { return [] }
                continue
            }
            return events.prefix(Int(count)).map { Int32($0.ident) }
        }
    }

    public func close() {
        Darwin.close(descriptor)
    }
}
