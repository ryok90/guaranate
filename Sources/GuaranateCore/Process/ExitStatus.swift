import Foundation

/// How a supervised process ended.
///
/// Decoding is a pure function of the raw 16-bit status `waitpid(2)` reports, so
/// exit-code propagation is unit-testable without spawning anything.
public enum ExitStatus: Equatable, Sendable {
    /// The process called `exit(code)` (or returned from `main`).
    case exited(code: Int32)
    /// The process was killed by an uncaught signal.
    case signalled(signal: Int32)

    /// Decodes a raw wait status as produced by `waitpid`.
    ///
    /// The low seven bits carry the terminating signal and are zero for a normal
    /// exit; the next eight bits carry the exit code. Stop notifications never
    /// arrive here: `ChildWaitOutcome` recognizes them first.
    public init(rawWaitStatus status: Int32) {
        let terminatingSignal = status & 0x7f
        if terminatingSignal == 0 {
            self = .exited(code: (status >> 8) & 0xff)
        } else {
            self = .signalled(signal: terminatingSignal)
        }
    }

    /// The exit code a supervisor should adopt to stand in for the process.
    ///
    /// Signal deaths become `128 + signal`, matching every POSIX shell — so
    /// `guaranate while <cmd>` is transparent to scripts that check `$?`.
    public var exitCode: Int32 {
        switch self {
        case .exited(let code): return code
        case .signalled(let signal): return 128 + signal
        }
    }

    /// Whether the process ended successfully.
    public var isSuccess: Bool {
        self == .exited(code: 0)
    }

    /// A short phrase describing the outcome, e.g. `finished`, `exited 7`,
    /// `interrupted`, or `killed by SIGSEGV`.
    public var summary: String {
        switch self {
        case .exited(let code):
            return code == 0 ? "finished" : "exited \(code)"
        case .signalled(let signal):
            // SIGINT is the everyday case (Ctrl+C); name it in plain language.
            if signal == SIGINT { return "interrupted" }
            return "killed by \(Self.signalName(signal))"
        }
    }

    /// The conventional `SIG*` spelling of a signal number.
    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGHUP: return "SIGHUP"
        case SIGINT: return "SIGINT"
        case SIGQUIT: return "SIGQUIT"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        case SIGABRT: return "SIGABRT"
        case SIGFPE: return "SIGFPE"
        case SIGKILL: return "SIGKILL"
        case SIGBUS: return "SIGBUS"
        case SIGSEGV: return "SIGSEGV"
        case SIGPIPE: return "SIGPIPE"
        case SIGALRM: return "SIGALRM"
        case SIGTERM: return "SIGTERM"
        case SIGXCPU: return "SIGXCPU"
        case SIGXFSZ: return "SIGXFSZ"
        case SIGUSR1: return "SIGUSR1"
        case SIGUSR2: return "SIGUSR2"
        default: return "signal \(signal)"
        }
    }
}

/// A supervised child's latest state change, as reported by `waitpid`.
///
/// Separate from `ExitStatus` because a stop is not an ending: the command is
/// still there, still owns the terminal, and still needs the machine kept awake.
public enum ChildWaitOutcome: Equatable, Sendable {
    /// No state change since the last check.
    case running
    /// Stopped by a job-control signal (`SIGTSTP` from Ctrl+Z, `SIGSTOP`, …).
    case stopped(signal: Int32)
    /// Ended, and reaped.
    case ended(ExitStatus)
    /// `waitpid` failed: the child is gone but its status is unknowable, so a
    /// supervisor must not claim it succeeded.
    case unavailable

    /// Decodes a raw wait status collected with `WUNTRACED`.
    public init(rawWaitStatus status: Int32) {
        // A stop is marked by all seven signal bits being set, with the stopping
        // signal in the next eight. Checked first, because as an exit status the
        // same bits would read as death by signal 127.
        if status & 0x7f == 0x7f {
            self = .stopped(signal: (status >> 8) & 0xff)
        } else {
            self = .ended(ExitStatus(rawWaitStatus: status))
        }
    }
}
