import Darwin
import Foundation

/// Errors surfaced while looking up a process to watch.
public enum ProcessLookupError: Error, Equatable, CustomStringConvertible {
    case invalidPID(pid_t)
    case noSuchProcess(pid_t)
    case wouldWatchItself(pid_t)

    public var description: String {
        switch self {
        case .invalidPID(let pid):
            return "\(pid) is not a valid process id."
        case .noSuchProcess(let pid):
            return "No process with pid \(pid)."
        case .wouldWatchItself(let pid):
            return "Cannot watch guaranate's own process (pid \(pid))."
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
        if kill(pid, 0) != 0, errno == ESRCH {
            throw ProcessLookupError.noSuchProcess(pid)
        }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        // A dead pid yields success with a zero-length result, so the length is
        // the real signal here.
        guard result == 0, size > 0 else {
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
