import Dispatch
import Foundation
import GuaranateCore

/// Supervises a child command, holding a power assertion for exactly its lifetime.
///
/// Lifecycle:
/// 1. Acquire the requested power assertion.
/// 2. Launch the command, which inherits this process's streams and process group.
/// 3. Forward termination signals to it and wait for it to exit.
/// 4. Release the assertion and exit with the command's own exit code.
///
/// Unlike `TimedSession` there is no live frame and no keyboard handling: the
/// command owns the terminal, so repainting over its output — or putting stdin in
/// cbreak mode behind its back — would corrupt it. All state is touched only on
/// the main dispatch queue.
final class ProcessSession: @unchecked Sendable {
    /// Signals forwarded to the child, and reset to their default disposition in
    /// it. `SIG_IGN` is inherited across `exec`, so without the reset the child
    /// would be deaf to Ctrl+C.
    static let forwardedSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    private let invocation: CommandInvocation
    private let assertionType: PowerAssertionType
    private let reason: String
    private let power: PowerAsserting
    private let child: ChildLaunching
    private let renderer: TerminalRenderer
    private let start: Date

    private var token: PowerAssertionToken?
    private var childPID: pid_t?
    private var exitSource: DispatchSourceProcess?
    private var signalSources: [DispatchSourceSignal] = []
    private var finished = false

    init(
        invocation: CommandInvocation,
        assertionType: PowerAssertionType,
        reason: String,
        power: PowerAsserting,
        child: ChildLaunching = ChildProcess(),
        renderer: TerminalRenderer = TerminalRenderer(),
        now: Date = Date()
    ) {
        self.invocation = invocation
        self.assertionType = assertionType
        self.reason = reason
        self.power = power
        self.child = child
        self.renderer = renderer
        self.start = now
    }

    /// Acquires the assertion, launches the command, and blocks until it exits.
    func run() throws {
        token = try power.acquire(assertionType, reason: reason, onBehalfOf: nil)

        // Installed before spawning so a signal arriving during startup cannot
        // kill this process and orphan the assertion.
        installSignalHandlers()

        do {
            childPID = try child.launch(invocation, resettingSignals: Self.forwardedSignals)
        } catch let error as ChildLaunchError {
            fail(error)
        }

        // Announced only once the command is actually running, so a failed launch
        // never claims the Mac is being kept awake for it.
        renderer.renderProcessStart(command: invocation.displayName, type: assertionType)

        watchChild()
        dispatchMain()
    }

    // MARK: - Child supervision

    private func watchChild() {
        guard let childPID else { return }
        let source = DispatchSource.makeProcessSource(
            identifier: childPID,
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.childExited() }
        exitSource = source
        source.resume()
    }

    private func childExited() {
        guard let childPID else { return }
        // The exit event fires while the child is still an unreaped zombie, so
        // this both collects its status and clears it.
        finish(status: child.reap(childPID) ?? .exited(code: 0))
    }

    // MARK: - Signals

    private func installSignalHandlers() {
        for sig in Self.forwardedSignals {
            // Ignore the default disposition so the dispatch source is the sole
            // handler; the child gets the default back via POSIX_SPAWN_SETSIGDEF.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.forward(sig) }
            signalSources.append(source)
            source.resume()
        }
    }

    /// Relays a termination signal and keeps waiting.
    ///
    /// The session deliberately does not end here: the assertion is held until
    /// the child has actually exited, so the command is never left running
    /// against a machine that has been allowed to sleep. The child shares our
    /// process group, so a terminal Ctrl+C reaches it directly as well; the
    /// duplicate is harmless and keeps `kill -INT <guaranate-pid>` working.
    private func forward(_ sig: Int32) {
        guard let childPID else {
            // Signalled before the child existed: nothing to wait for.
            finish(status: .signalled(signal: SIGINT))
            return
        }
        child.forward(sig, to: childPID)
    }

    // MARK: - Teardown

    private func finish(status: ExitStatus) {
        guard !finished else { return }
        finished = true

        exitSource?.cancel()
        exitSource = nil
        releaseAssertion()

        let elapsed = max(0, Date().timeIntervalSince(start))
        renderer.renderProcessFinished(
            command: invocation.displayName,
            elapsed: elapsed,
            status: status
        )

        exit(status.exitCode)
    }

    /// Reports a launch failure with the shell's conventional exit codes and
    /// leaves no assertion behind.
    private func fail(_ error: ChildLaunchError) -> Never {
        releaseAssertion()
        FileHandle.standardError.write(Data("guaranate: \(error)\n".utf8))
        exit(error.exitCode)
    }

    private func releaseAssertion() {
        guard let token else { return }
        power.release(token)
        self.token = nil
    }
}
