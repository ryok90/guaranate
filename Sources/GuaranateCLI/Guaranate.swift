import ArgumentParser
import GuaranateCore

/// Root command: `guaranate <duration>`.
///
/// Keeps macOS awake for a human-readable duration. Subcommands (`while`,
/// `until`, `status`, `acquire`, …) are layered on in later milestones; the
/// bare-duration form is the v0.1 foundation.
@main
struct Guaranate: ParsableCommand {
    /// The single source of truth for the CLI version, printed by `-v`/`--version`.
    static let versionString = "0.1.0"

    static let configuration = CommandConfiguration(
        commandName: "guaranate",
        abstract: "A developer-friendly macOS keep-awake CLI.",
        discussion: "Keep your Mac awake when work needs to finish. Give your Mac some guaraná."
    )

    @Argument(help: "How long to stay awake: 30m, 2h, 1h30m, 90s, or a plain number of seconds.")
    var duration: String?

    @Flag(name: .long, help: "Also keep the display awake (default lets the display sleep).")
    var display = false

    @Flag(name: .long, help: "Prevent all system sleep.")
    var system = false

    @Option(name: .long, help: "Reason recorded on the power assertion.")
    var reason = "Guaranate timed session"

    // Version is handled explicitly (rather than via `CommandConfiguration.version`)
    // so both a short `-v` and long `--version` alias are available.
    @Flag(name: [.customShort("v"), .long], help: "Show the version.")
    var version = false

    func validate() throws {
        if version { return }
        guard let duration else {
            throw ValidationError("Missing expected argument '<duration>'.")
        }
        _ = try parseSeconds(duration)
        if display && system {
            throw ValidationError("Choose at most one of --display or --system.")
        }
    }

    func run() throws {
        if version {
            print(Self.versionString)
            return
        }

        // validate() guarantees `duration` is present and parseable here.
        let seconds = try parseSeconds(duration ?? "")
        let session = TimedSession(
            durationSeconds: seconds,
            assertionType: assertionType,
            reason: reason,
            power: PowerManager()
        )
        try session.run()
    }

    private var assertionType: PowerAssertionType {
        if display { return .preventUserIdleDisplaySleep }
        if system { return .preventSystemSleep }
        return .preventUserIdleSystemSleep
    }

    private func parseSeconds(_ input: String) throws -> Int {
        do {
            return try DurationParser.parse(input)
        } catch {
            throw ValidationError(String(describing: error))
        }
    }
}
