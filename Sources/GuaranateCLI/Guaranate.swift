import ArgumentParser

/// Root command.
///
/// A pure container: it declares no arguments of its own because a command that
/// owns a positional argument consumes the subcommand name before dispatch can
/// happen, which silently makes every subcommand unreachable. The bare-duration
/// form therefore lives in `RunCommand`, registered as the default subcommand, so
/// `guaranate 10m` and `guaranate while npm test` both work.
@main
struct Guaranate: ParsableCommand {
    /// The single source of truth for the CLI version, printed by `-v`/`--version`.
    static let versionString = "0.1.0"

    static let configuration = CommandConfiguration(
        commandName: "guaranate",
        abstract: "A developer-friendly macOS keep-awake CLI.",
        usage: """
            guaranate [<duration>] [--watch <pid>] [--display] [--system] [--reason <text>]
            guaranate while <command> [<arguments> ...]
            """,
        discussion: """
            Keep your Mac awake when work needs to finish. Give your Mac some guaraná.

              guaranate 2h                  stay awake for two hours
              guaranate                     stay awake until interrupted
              guaranate --watch 4821        stay awake until pid 4821 exits
              guaranate while npm test      stay awake for exactly one command

            The timed form is the default command: see `guaranate run --help` for \
            its full options, and `guaranate while --help` for the command form.
            """,
        subcommands: [RunCommand.self, WhileCommand.self],
        defaultSubcommand: RunCommand.self
    )
}
