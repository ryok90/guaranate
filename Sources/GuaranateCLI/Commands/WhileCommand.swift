import ArgumentParser
import GuaranateCore

/// `guaranate while <command> …` — hold an assertion for one command's lifetime.
struct WhileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "while",
        abstract: "Stay awake for exactly as long as a command runs.",
        discussion: """
            The command keeps this terminal: its output and input pass straight \
            through, and guaranate exits with the command's own exit code — or \
            128 + signal number if it is killed by a signal.

            Guaranate's own flags belong before the command. Everything from the \
            first non-flag token onwards is handed to the command untouched, so \
            use `--` when the command's first argument could be mistaken for one \
            of ours:

              guaranate while npm test
              guaranate while --display -- ./build.sh --release
            """
    )

    @OptionGroup var assertion: AssertionOptions

    // No default value: the command is genuinely required, and a defaulted array
    // would report itself as optional in `--help` and in the generated CLI
    // reference. A `--`-only invocation still reaches `validate()`.
    @Argument(
        parsing: .captureForPassthrough,
        help: "The command to run, with its arguments."
    )
    var command: [String]

    func validate() throws {
        // `.captureForPassthrough` captures `--help` into the command instead of
        // showing help, so a bare help request is intercepted here. A command
        // introduced by `--` is left alone: `guaranate while -- --help` really
        // does mean "run a program called --help".
        if command == ["--help"] || command == ["-h"] {
            throw CleanExit.helpRequest(self)
        }

        try assertion.validate()

        do {
            _ = try CommandInvocation(argv: command)
        } catch {
            throw ValidationError(String(describing: error))
        }
    }

    func run() throws {
        // validate() guarantees the command is non-empty here.
        let invocation = try CommandInvocation(argv: command)
        let session = ProcessSession(
            invocation: invocation,
            assertionType: assertion.assertionType,
            reason: assertion.reason ?? invocation.assertionReason,
            power: PowerManager()
        )
        try session.run()
    }
}
