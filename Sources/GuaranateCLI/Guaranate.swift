import ArgumentParser
import GuaranateCore

/// Root command: `guaranate <duration>`.
///
/// Keeps macOS awake for a human-readable duration. Subcommands (`while`,
/// `until`, `status`, `acquire`, …) are layered on in later milestones; the
/// bare-duration form is the v0.1 foundation.
@main
struct Guaranate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guaranate",
        abstract: "A developer-friendly macOS keep-awake CLI.",
        discussion: "Keep your Mac awake when work needs to finish. Give your Mac some guaraná.",
        version: "0.1.0"
    )

    @Argument(help: "How long to stay awake: 30m, 2h, 1h30m, 90s, or a plain number of seconds.")
    var duration: String

    @Flag(name: .long, help: "Also keep the display awake (default lets the display sleep).")
    var display = false

    @Flag(name: .long, help: "Prevent all system sleep.")
    var system = false

    @Option(name: .long, help: "Reason recorded on the power assertion.")
    var reason = "Guaranate timed session"

    func validate() throws {
        _ = try parseSeconds()
        if display && system {
            throw ValidationError("Choose at most one of --display or --system.")
        }
    }

    func run() throws {
        let seconds = try parseSeconds()
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

    private func parseSeconds() throws -> Int {
        do {
            return try DurationParser.parse(duration)
        } catch {
            throw ValidationError(String(describing: error))
        }
    }
}
