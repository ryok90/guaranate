import ArgumentParser
import GuaranateCore

/// Assertion options shared by every command that keeps the Mac awake.
///
/// Declared on each subcommand rather than on the root: options declared on a
/// root command with a default subcommand are consumed before dispatch, which
/// would make `guaranate while --display …` fail with "unknown option".
struct AssertionOptions: ParsableArguments {
    @Flag(name: [.customShort("d"), .long], help: "Also keep the display awake (default lets the display sleep).")
    var display = false

    @Flag(name: [.customShort("s"), .long], help: "Prevent all system sleep.")
    var system = false

    @Option(
        name: [.customShort("r"), .long],
        help: ArgumentHelp("Reason recorded on the power assertion.", valueName: "text")
    )
    var reason: String?

    func validate() throws {
        if display && system {
            throw ValidationError("Choose at most one of --display or --system.")
        }
    }

    var assertionType: PowerAssertionType {
        if display { return .preventUserIdleDisplaySleep }
        if system { return .preventSystemSleep }
        return .preventUserIdleSystemSleep
    }
}
