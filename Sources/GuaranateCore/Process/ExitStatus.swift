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
    /// exit; the next eight bits carry the exit code. Stop notifications are not
    /// represented because callers never pass `WUNTRACED`.
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
