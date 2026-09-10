import Foundation

/// Errors surfaced while normalizing a user-supplied command.
public enum CommandInvocationError: Error, Equatable, CustomStringConvertible {
    case empty
    case looksLikeOption(String)

    public var description: String {
        switch self {
        case .empty:
            return "Give a command to run, for example: guaranate while npm test"
        case .looksLikeOption(let token):
            return """
                Unknown option '\(token)'. Guaranate's own flags go before the command; \
                to run a program whose name starts with '-', put `--` first.
                """
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

    /// Normalizes captured argv: drops one leading `--` separator, rejects an
    /// empty command, and rejects an option-looking first token that no `--`
    /// introduced — otherwise a mistyped flag of ours silently becomes the
    /// command, and `guaranate while -w 1234` reports "-w: command not found".
    public init(argv: [String]) throws {
        var tokens = argv
        // `.captureForPassthrough` keeps a user-typed `--`; the child must not see
        // it, but its presence is what makes a leading `-` deliberate.
        let introducedBySeparator = tokens.first == "--"
        if introducedBySeparator { tokens.removeFirst() }
        guard let executable = tokens.first, !executable.isEmpty else {
            throw CommandInvocationError.empty
        }
        if !introducedBySeparator, executable.hasPrefix("-") {
            throw CommandInvocationError.looksLikeOption(executable)
        }
        self.executable = executable
        self.arguments = Array(tokens.dropFirst())
    }

    /// The command as a human would write it, quoting any token that contains
    /// whitespace and escaping quotes and backslashes inside it, so the rendered
    /// form is never ambiguous about where a token starts and ends.
    public var displayName: String {
        argv.map(Self.quoted).joined(separator: " ")
    }

    static func quoted(_ token: String) -> String {
        let needsQuotes = token.isEmpty || token.contains {
            $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\"" || $0 == "\\"
        }
        guard needsQuotes else { return token }
        var escaped = ""
        for character in token {
            if character == "\"" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return "\"\(escaped)\""
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
