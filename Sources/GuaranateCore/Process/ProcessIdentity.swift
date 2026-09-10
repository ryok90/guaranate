import Darwin
import Foundation

/// Errors surfaced while looking up a process to watch.
public enum ProcessLookupError: Error, Equatable, CustomStringConvertible {
    case invalidPID(pid_t)
    case noSuchProcess(pid_t)
    case wouldWatchItself(pid_t)
    /// The process exists, but the kernel refused to report its exit.
    case cannotWatch(pid_t, code: Int32)

    public var description: String {
        switch self {
        case .invalidPID(let pid):
            return "\(pid) is not a valid process id."
        case .noSuchProcess(let pid):
            return "No process with pid \(pid)."
        case .wouldWatchItself(let pid):
            return "Cannot watch guaranate's own process (pid \(pid))."
        case .cannotWatch(let pid, let code):
            return "Cannot watch pid \(pid): \(String(cString: strerror(code)))."
        }
    }
}

/// Identity of a running process, precise enough to survive pid reuse.
///
/// A pid alone is not an identity: pids recycle, so a process that exits between
/// lookup and registration could be replaced by an unrelated one holding the
/// assertion. The start time pins the pid to one specific process.
public struct ProcessIdentity: Equatable, Sendable {
    public let pid: pid_t
    /// Process start time, in seconds since the epoch.
    public let startedAt: TimeInterval
    /// The kernel's short process name (`p_comm`), when available.
    public let name: String?

    public init(pid: pid_t, startedAt: TimeInterval, name: String?) {
        self.pid = pid
        self.startedAt = startedAt
        self.name = name
    }

    /// Whether both values describe the same process instance.
    ///
    /// Compares the pid and its start time only: a process keeps its identity
    /// across `exec`, which changes `name`.
    public func isSameProcess(as other: ProcessIdentity) -> Bool {
        pid == other.pid && startedAt == other.startedAt
    }

    /// How the process is shown to the user, e.g. `1234 (node)`.
    public var displayName: String {
        guard let name, !name.isEmpty else { return "\(pid)" }
        return "\(pid) (\(name))"
    }
}

/// Looking up processes this tool does not own.
public protocol ProcessInspecting: Sendable {
    /// Resolves a pid to a process identity.
    ///
    /// Throws `ProcessLookupError.noSuchProcess` when nothing is running under
    /// that pid.
    func identity(of pid: pid_t) throws -> ProcessIdentity
}

/// `sysctl`-backed process lookup.
///
/// `sysctl(KERN_PROC_PID)` is used rather than `proc_pidinfo` or
/// `proc_pid_rusage` because it is the only public, unprivileged source of a
/// process start time that also works for processes owned by another user.
public struct SystemProcessInspector: ProcessInspecting {
    public init() {}

    public func identity(of pid: pid_t) throws -> ProcessIdentity {
        // Guard before signalling: kill(0, 0) would address our whole process
        // group, and negative pids address groups too.
        guard pid > 0 else { throw ProcessLookupError.invalidPID(pid) }
        guard pid != getpid() else { throw ProcessLookupError.wouldWatchItself(pid) }

        // Existence check. EPERM means the process exists but belongs to another
        // user, which is still watchable: the kernel only enforces credentials
        // on EVFILT_PROC when NOTE_EXITSTATUS is requested, and it never is.
        if kill(pid, 0) != 0 {
            let code = errno
            if code == ESRCH { throw ProcessLookupError.noSuchProcess(pid) }
            guard code == EPERM else { throw ProcessLookupError.cannotWatch(pid, code: code) }
        }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // "Gone" and "could not tell" are different answers, and only the first
        // one may end a watch session as though the work had finished. A dead pid
        // yields success with a zero-length result, so the length is the signal
        // for absence; a failed call is an operational error, whatever its cause.
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
            let code = errno
            throw code == ESRCH
                ? ProcessLookupError.noSuchProcess(pid)
                : ProcessLookupError.cannotWatch(pid, code: code)
        }
        guard size > 0 else { throw ProcessLookupError.noSuchProcess(pid) }

        // A zombie has already exited and only lingers until its parent reaps it,
        // so `kill(pid, 0)` still succeeds for it. Watching one would hold the
        // assertion for work that is already over — and, since `NOTE_EXIT` has
        // nothing left to report, would hold it until the parent got around to
        // reaping.
        guard Int32(info.kp_proc.p_stat) != SZOMB else {
            throw ProcessLookupError.noSuchProcess(pid)
        }

        let started = info.kp_proc.p_starttime
        let startedAt = TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000
        return ProcessIdentity(pid: pid, startedAt: startedAt, name: Self.name(from: info))
    }

    private static func name(from info: kinfo_proc) -> String? {
        var command = info.kp_proc.p_comm
        let name = withUnsafeBytes(of: &command) { bytes -> String? in
            guard let base = bytes.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        guard let name, !name.isEmpty else { return nil }
        return name
    }
}
