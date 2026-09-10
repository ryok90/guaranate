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

/// Registering interest in signals sent to this process.
///
/// Split from the disposition changes a caller makes around it: a registrar
/// promises that the kernel will record these signals, and says nothing about what
/// happens to them afterwards.
public protocol SignalNoteRegistering: Sendable {
    /// Registers every signal in `signals` before returning, so a caller may change
    /// their dispositions afterwards without opening a gap.
    func registerNotes(watching signals: [Int32]) throws -> any SignalNoteReading
}

/// A kernel record of signals that have arrived, readable whatever their
/// disposition is and whatever state this process is in.
public protocol SignalNoteReading: Sendable {
    /// Becomes readable while at least one watched signal has an unread note. The
    /// reader must not close it; `close()` owns it.
    var descriptor: Int32 { get }

    /// The signals with notes waiting, if any. Never blocks.
    func drain() -> [Int32]

    /// Releases the registration. Idempotent.
    func close()
}

/// `kqueue`-backed signal registration.
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
public struct KqueueSignalNotes: SignalNoteRegistering {
    public init() {}

    public func registerNotes(watching signals: [Int32]) throws -> any SignalNoteReading {
        try SignalNotes(watching: signals)
    }
}

/// Takes `signals` out of the kernel's hands process-wide, and reports which of
/// them the caller was not already ignoring.
///
/// A disposition is a property of the process, not of a thread, which is what makes
/// this the only guard that holds everywhere: from here on, no thread can take a
/// signal's default action. A handler is used rather than `SIG_IGN` because
/// `SIG_IGN` discards what is already pending, and this runs *before* the watch
/// exists — the point being to survive that gap, not to erase it. The handler does
/// nothing: arrivals are read from the watch, never from here.
///
/// The returned signals are the ones whose disposition this changed. A signal the
/// surrounding shell was already ignoring is the caller's choice, inherited across
/// `exec`, and must stay that way in a command.
public func claimSignals(_ signals: [Int32]) -> [Int32] {
    signals.filter { sig in
        let previous = signal(sig) { _ in }
        // Dispositions are C function pointers, which Swift will not compare
        // directly; `SIG_IGN` is a sentinel address, so the bit patterns are the
        // comparison.
        return unsafeBitCast(previous, to: UInt.self) != unsafeBitCast(SIG_IGN, to: UInt.self)
    }
}

/// Runs `body` with `signals` blocked, restoring the previous mask afterwards.
///
/// Blocking is what keeps a signal from being *lost* while the watch is being
/// established: a blocked signal stays pending instead of reaching a handler that
/// has nowhere to record it, and its note is recorded when it arrives regardless.
/// Pair it with `claimSignals(_:)`, which is what keeps the signal from *ending*
/// this process: masks are per-thread, dispositions are not.
///
/// A mask this narrow cannot fail — `sigprocmask` rejects only an invalid `how`,
/// and there is one here — but the result is checked rather than assumed, and a
/// refusal simply means `body` runs unmasked, still guarded by the dispositions.
@discardableResult
public func withSignalsBlocked<T>(_ signals: [Int32], _ body: () throws -> T) rethrows -> T {
    var blocking = sigset_t()
    sigemptyset(&blocking)
    for signal in signals { sigaddset(&blocking, signal) }

    var previous = sigset_t()
    let blocked = sigprocmask(SIG_BLOCK, &blocking, &previous) == 0
    defer { if blocked { sigprocmask(SIG_SETMASK, &previous, nil) } }

    return try body()
}

/// One `kqueue` holding `EVFILT_SIGNAL` registrations.
///
/// `@unchecked Sendable`: the descriptor is immutable and `kevent` is safe to call
/// from any thread, but closing races with reading — so a lock serializes the two
/// and makes `close()` idempotent. Closing twice would be worse than pointless: the
/// number can be reused by then, and the second close would hit a stranger.
final class SignalNotes: SignalNoteReading, @unchecked Sendable {
    let descriptor: Int32
    private let lock = NSLock()
    private var closed = false

    init(watching signals: [Int32]) throws {
        let queue = kqueue()
        guard queue >= 0 else {
            throw SignalWatchError.cannotWatch(signal: signals.first ?? 0, code: errno)
        }

        // One owner for the descriptor on every failing path.
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

    /// Repeat arrivals of one signal coalesce into a single note, exactly as they
    /// do for a dispatch signal source: a relay is per signal, not per delivery.
    func drain(upTo limit: Int = 16) -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return [] }

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

    func drain() -> [Int32] {
        drain(upTo: 16)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(descriptor)
    }
}
