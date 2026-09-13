import ArgumentParser
import Darwin
import GuaranateCore

/// Internal process used to wake a stopped `while` supervisor after child exit.
struct ExitWakeupGuardianCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_exit-wakeup-guardian",
        shouldDisplay: false
    )

    @Argument var supervisorPID: Int32
    @Argument var commandPID: Int32
    @Argument var readinessDescriptor: Int32
    @Argument var cancellationDescriptor: Int32

    func run() throws {
        Darwin.exit(
            ExitWakeupGuardianMode.run(
                supervisorPID: supervisorPID,
                commandPID: commandPID,
                readinessDescriptor: readinessDescriptor,
                cancellationDescriptor: cancellationDescriptor
            )
        )
    }
}
