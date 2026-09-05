import Foundation

/// Errors surfaced while normalizing a user-supplied command.
public enum CommandInvocationError: Error, Equatable, CustomStringConvertible {
    case empty

    public var description: String {
        switch self {
        case .empty:
            return "Give a command to run, for example: guaranate while npm test"
        }
    }
}

/// A command to run and hold a power assertion for.
///
/// The argument parser captures everything after `while` verbatim, including a
/// `--` separator the user may have typed, so normalization happens here rather
/// than at the call site.
public struct CommandInvocation: Equatable, Sendable {
    /// The program to run; resolved against `PATH` at launch.
    public let executable: String
    /// Arguments passed to the program, excluding `argv[0]`.
    public let arguments: [String]

    /// The full argument vector to hand to `posix_spawnp`.
    public var argv: [String] { [executable] + arguments }

    /// Normalizes captured argv: drops one leading `--` separator and rejects an
    /// empty command.
    public init(argv: [String]) throws {
        var tokens = argv
        // `.captureForPassthrough` keeps a user-typed `--`; the child must not see it.
        if tokens.first == "--" { tokens.removeFirst() }
        guard let executable = tokens.first, !executable.isEmpty else {
            throw CommandInvocationError.empty
        }
        self.executable = executable
        self.arguments = Array(tokens.dropFirst())
    }

    /// The command as a human would write it, quoting arguments that contain
    /// spaces so the rendered form stays unambiguous.
    public var displayName: String {
        argv.map { token in
            token.contains(" ") ? "\"\(token)\"" : token
        }
        .joined(separator: " ")
    }

    /// The reason recorded on the power assertion when the user supplies none.
    ///
    /// Truncated so `pmset -g assertions` stays readable for long build commands.
    public var assertionReason: String {
        "while: \(Self.truncate(displayName, to: 96))"
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return text.prefix(limit - 1) + "…"
    }
}
