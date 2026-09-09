import Darwin
import Foundation

/// Registering interest in another process's exit.
///
/// Split from `ProcessInspecting` because the two answer different questions:
/// an inspector says what a pid *is* right now, a registrar makes the kernel
/// promise to report when one specific process ends.
public protocol ProcessExitRegistering: Sendable {
    /// Registers for `identity`'s exit and returns a descriptor that becomes
    /// readable exactly once that process has ended.
    ///
    /// Registration completes before this returns, which is the property the
    /// caller depends on: only then can the identity be re-verified in an order
    /// that rules out a pid recycled in between. Throws
    /// `ProcessLookupError.noSuchProcess` when the process is already gone.
    ///
    /// The caller owns the descriptor and must close it.
    func registerExit(of identity: ProcessIdentity) throws -> Int32
}

/// `kqueue`-backed exit registration.
///
/// `EVFILT_PROC`/`NOTE_EXIT` attaches to a process, not to a number, so once
/// `EV_ADD` has returned the watch cannot drift onto a later reuse of the same
/// pid. `DispatchSourceProcess` is not used for this: it registers on
/// libdispatch's manager queue, so `resume()` returns before the kernel knows
/// about the watch and there is no point at which the caller can prove the
/// registration landed on the process it looked up.
public struct KqueueExitRegistrar: ProcessExitRegistering {
    private let inspector: ProcessInspecting

    public init(inspector: ProcessInspecting = SystemProcessInspector()) {
        self.inspector = inspector
    }

    public func registerExit(of identity: ProcessIdentity) throws -> Int32 {
        let queue = kqueue()
        guard queue >= 0 else {
            throw ProcessLookupError.cannotWatch(identity.pid, code: errno)
        }

        // One owner for the descriptor on every failing path: closing it twice
        // could hit an unrelated descriptor that another thread opened onto the
        // same number in between.
        var handedOff = false
        defer { if !handedOff { close(queue) } }

        var registration = kevent(
            ident: UInt(identity.pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: NOTE_EXIT,
            data: 0,
            udata: nil
        )
        guard kevent(queue, &registration, 1, nil, 0, nil) != -1 else {
            let code = errno
            // The process ended between the lookup and this call.
            throw code == ESRCH
                ? ProcessLookupError.noSuchProcess(identity.pid)
                : ProcessLookupError.cannotWatch(identity.pid, code: code)
        }

        // Verified *after* registration, never before: a check that precedes it
        // proves only what was true earlier, and the pid could have been recycled
        // in the gap. Passing here means the watch is attached to this process.
        guard try inspector.identity(of: identity.pid).isSameProcess(as: identity) else {
            throw ProcessLookupError.noSuchProcess(identity.pid)
        }

        handedOff = true
        return queue
    }
}
