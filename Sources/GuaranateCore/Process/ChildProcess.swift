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
/// The real implementation calls `posix_spawnp`, `waitpid`, and `kill`; tests
/// substitute a fake so child-lifecycle logic never spawns anything.
public protocol ChildLaunching: Sendable {
    /// Spawns `invocation`, resolving the executable against `PATH`.
    ///
    /// The child inherits this process's standard streams and process group, so
    /// terminal signals reach it exactly as if it had been run directly. Any
    /// signal in `resettingSignals` is restored to its default disposition in
    /// the child, because dispositions set to `SIG_IGN` are otherwise inherited
    /// across `exec`.
    func launch(_ invocation: CommandInvocation, resettingSignals: [Int32]) throws -> pid_t

    /// Reaps an exited child without blocking. Returns `nil` if the child has
    /// not exited yet or was already reaped.
    func reap(_ pid: pid_t) -> ExitStatus?

    /// Forwards a signal to the child, ignoring failures (the child may have
    /// exited between the signal arriving and this call).
    func forward(_ signal: Int32, to pid: pid_t)
}

/// `posix_spawnp`-backed child supervision.
///
/// Foundation's `Process` is deliberately not used: it always sets
/// `POSIX_SPAWN_SETPGROUP`, which puts the child in its own process group where
/// a terminal Ctrl+C never reaches it, and it never exposes the raw wait status
/// needed to tell `exit(9)` from death by `SIGKILL`.
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
        // POSIX_SPAWN_SETPGROUP is intentionally absent: omitting it makes the
        // child inherit our process group, keeping it in the terminal's
        // foreground group so Ctrl+C is delivered to it directly.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))

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

    public func reap(_ pid: pid_t) -> ExitStatus? {
        var status: Int32 = 0
        // The process source fires while the child is still an unreaped zombie,
        // so this both collects the status and clears the zombie.
        let reaped = waitpid(pid, &status, WNOHANG)
        guard reaped == pid else { return nil }
        return ExitStatus(rawWaitStatus: status)
    }

    public func forward(_ signal: Int32, to pid: pid_t) {
        _ = kill(pid, signal)
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
