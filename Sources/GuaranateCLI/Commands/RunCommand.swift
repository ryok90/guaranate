import ArgumentParser
import Darwin
import GuaranateCore

/// `guaranate [<duration>]` / `guaranate --watch <pid>` — the default command.
///
/// Holds an assertion for a fixed duration, until interrupted, or until an
/// already-running process exits.
struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Stay awake for a duration, until interrupted, or until a process exits.",
        discussion: """
            This is the default command, so its name is optional: `guaranate 2h` \
            and `guaranate run 2h` do the same thing.

              guaranate 2h              stay awake for two hours
              guaranate                 stay awake until interrupted
              guaranate --watch 4821    stay awake until pid 4821 exits

            A watched process is not started, stopped, or otherwise touched by \
            guaranate — only observed. Ctrl+C detaches and leaves it running. \
            Processes belonging to another user can be watched too.
            """
    )

    @Argument(help: "How long to stay awake: 30m, 2h, 1h30m, 90s, or a plain number of seconds. Omit to stay awake until interrupted.")
    var duration: String?

    @Option(
        name: [.customShort("w"), .long],
        help: ArgumentHelp("Stay awake until the process with this pid exits.", valueName: "pid")
    )
    var watch: pid_t?

    @OptionGroup var assertion: AssertionOptions

    // Version is handled explicitly (rather than via `CommandConfiguration.version`)
    // so both a short `-v` and long `--version` alias are available. It lives here
    // rather than on the root because a root command that declares a default
    // subcommand never runs its own `run()`.
    @Flag(name: [.customShort("v"), .long], help: "Show the version.")
    var version = false

    func validate() throws {
        if version { return }
        try assertion.validate()

        if let duration {
            _ = try parseSeconds(duration)
        }

        if let watch {
            guard duration == nil else {
                throw ValidationError("Choose either a duration or --watch <pid>, not both.")
            }
            _ = try lookUp(watch)
        }
    }

    func run() throws {
        if version {
            print(Guaranate.versionString)
            return
        }

        // validate() guarantees a supplied duration parses and a supplied pid exists.
        let target = try watch.map { try lookUp($0) }
        let seconds = try duration.map { try parseSeconds($0) }
        let session = TimedSession(
            durationSeconds: seconds,
            watching: target,
            assertionType: assertion.assertionType,
            reason: assertion.reason ?? Self.defaultReason(for: target),
            power: PowerManager()
        )
        try session.run()
    }

    /// The reason recorded when the user supplies none, derived from the mode so
    /// `pmset -g assertions` explains itself.
    private static func defaultReason(for target: ProcessIdentity?) -> String {
        guard let target else { return "Guaranate timed session" }
        return "Watching \(target.displayName)"
    }

    private func lookUp(_ pid: pid_t) throws -> ProcessIdentity {
        do {
            return try SystemProcessInspector().identity(of: pid)
        } catch {
            throw ValidationError(String(describing: error))
        }
    }

    private func parseSeconds(_ input: String) throws -> Int {
        do {
            return try DurationParser.parse(input)
        } catch {
            throw ValidationError(String(describing: error))
        }
    }
}
