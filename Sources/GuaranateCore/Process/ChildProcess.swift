import Darwin
import Foundation

/// Errors surfaced while launching a child process.
public enum ChildLaunchError: Error, Equatable, CustomStringConvertible {
    case notFound(command: String)
    case notExecutable(command: String)
    case spawnFailed(command: String, code: Int32)

    public var description: String {
        switch self {
        case .notFound(let command):
            return "\(command): command not found"
        case .notExecutable(let command):
            return "\(command): permission denied"
        case .spawnFailed(let command, let code):
            return "\(command): \(String(cString: strerror(code)))"
        }
    }

    /// The exit code to leave behind, following the POSIX shell convention:
    /// 127 for "not found", 126 for "found but not runnable".
    public var exitCode: Int32 {
        switch self {
        case .notFound: return 127
        case .notExecutable, .spawnFailed: return 126
        }
    }
}

/// Launching and supervising a child process.
///
/// The real implementation calls `posix_spawnp`, `waitpid`, and `killpg`. The
/// protocol keeps the supervising session free of spawning details, and lets a
/// future non-CLI front end drive the same lifecycle.
public protocol ChildLaunching: Sendable {
    /// Spawns `invocation` **suspended**, resolving the executable against `PATH`.
    ///
    /// The child is the leader of a new process group, and is stopped before its
    /// first instruction: the supervisor gets a window in which to hand it the
    /// terminal and announce the session before any of the command's own output
    /// can appear. Call `resume(_:)` to let it run.
    ///
    /// Any signal in `resettingSignals` is restored to its default disposition
    /// in the child, because dispositions set to `SIG_IGN` are otherwise
    /// inherited across `exec`.
    func launch(_ invocation: CommandInvocation, resettingSignals: [Int32]) throws -> pid_t

    /// Lets a child returned by `launch(_:resettingSignals:)` start running.
    func resume(_ pid: pid_t)

    /// Collects a child's latest state change without blocking, reaping it if it
    /// has ended.
    func wait(_ pid: pid_t) -> ChildWaitOutcome

    /// Signals a whole process group, ignoring failures (the group may have
    /// exited between the signal arriving and this call).
    ///
    /// Groups rather than single pids: the command's own children have to be
    /// torn down too, otherwise a forwarded `SIGTERM` kills only the command and
    /// leaves its work running against a machine allowed to sleep again.
    func send(_ signal: Int32, toProcessGroup pgid: pid_t)
}

/// `posix_spawnp`-backed child supervision.
///
/// Foundation's `Process` is deliberately not used: it never exposes the raw
/// wait status needed to tell `exit(9)` from death by `SIGKILL`, it reaps the
/// child itself, and it cannot start a child suspended — all three of which this
/// supervisor depends on.
public struct ChildProcess: ChildLaunching {
    public init() {}

    public func launch(_ invocation: CommandInvocation, resettingSignals: [Int32]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // Reset only the dispositions the parent installed, so anything the
        // surrounding shell intentionally ignored stays ignored.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in resettingSignals {
            sigaddset(&defaults, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        // A group of its own (pgroup 0 means "the child's own pid"): terminal
        // signals then reach the command and its descendants as one unit, and
        // never reach the supervisor, so a single Ctrl+C is delivered once.
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED)
        )

        let argv = invocation.argv
        var pid = pid_t()
        let code = withCStrings(argv) { pointers in
            posix_spawnp(&pid, argv[0], nil, &attributes, pointers, environ)
        }

        switch code {
        case 0:
            return pid
        case ENOENT:
            throw ChildLaunchError.notFound(command: invocation.executable)
        case EACCES, ENOEXEC, EISDIR, ENOTDIR:
            throw ChildLaunchError.notExecutable(command: invocation.executable)
        default:
            throw ChildLaunchError.spawnFailed(command: invocation.executable, code: code)
        }
    }

    public func resume(_ pid: pid_t) {
        _ = kill(pid, SIGCONT)
    }

    public func wait(_ pid: pid_t) -> ChildWaitOutcome {
        var status: Int32 = 0
        while true {
            // `WUNTRACED` so Ctrl+Z is reported as a stop instead of being
            // mistaken for death by signal 127; `WNOHANG` because this runs
            // inside a dispatch event handler that must not block.
            let reaped = waitpid(pid, &status, WNOHANG | WUNTRACED)
            if reaped == pid { return ChildWaitOutcome(rawWaitStatus: status) }
            if reaped == 0 { return .running }
            if errno == EINTR { continue }
            return .unavailable
        }
    }

    public func send(_ signal: Int32, toProcessGroup pgid: pid_t) {
        _ = killpg(pgid, signal)
    }

    /// Builds a NULL-terminated `char *const[]` that stays valid for the
    /// duration of `body`.
    private func withCStrings<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
