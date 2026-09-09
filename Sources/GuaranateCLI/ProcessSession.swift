import Dispatch
import Foundation
import GuaranateCore

/// Supervises a child command, holding a power assertion for exactly its lifetime.
///
/// Lifecycle:
/// 1. Acquire the requested power assertion.
/// 2. Launch the command suspended, as the leader of its own process group.
/// 3. Hand it the controlling terminal, announce the session, let it run.
/// 4. Relay termination signals to its group, mirror its stops, wait for it to exit.
/// 5. Take the terminal back, release the assertion, exit with the command's own code.
///
/// Unlike `TimedSession` there is no live frame and no keyboard handling: the
/// command owns the terminal, so repainting over its output — or putting stdin in
/// cbreak mode behind its back — would corrupt it. All state is touched only on
/// the main dispatch queue.
final class ProcessSession: @unchecked Sendable {
    /// Signals relayed to the command's process group when they arrive here.
    static let forwardedSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    /// Signals whose disposition this process changes, and which therefore have
    /// to be restored to their defaults in the child: `SIG_IGN` is inherited
    /// across `exec`, so without the reset the command would be deaf to Ctrl+C —
    /// and, for `SIGPIPE`, would survive a vanished reader that should have
    /// ended it.
    static let signalsResetInChild: [Int32] = forwardedSignals + [SIGCONT, SIGPIPE]

    private let invocation: CommandInvocation
    private let assertionType: PowerAssertionType
    private let reason: String
    private let power: PowerAsserting
    private let child: ChildLaunching
    private let renderer: TerminalRenderer
    private let clock: @Sendable () -> Date
    private let start: Date

    private var token: PowerAssertionToken?
    private var childPID: pid_t?
    private var stateSource: DispatchSourceProcess?
    private var signalSources: [DispatchSourceSignal] = []
    private var terminal: TerminalForeground?
    private var stopped = false
    private var finished = false

    init(
        invocation: CommandInvocation,
        assertionType: PowerAssertionType,
        reason: String,
        power: PowerAsserting,
        child: ChildLaunching = ChildProcess(),
        // Status output goes to stderr: stdout belongs to the command alone, so
        // `guaranate while jq … > out.json` writes only the command's own bytes.
        renderer: TerminalRenderer = TerminalRenderer(handle: .standardError),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.invocation = invocation
        self.assertionType = assertionType
        self.reason = reason
        self.power = power
        self.child = child
        self.renderer = renderer
        self.clock = clock
        self.start = clock()
    }

    /// Acquires the assertion, launches the command, and blocks until it exits.
    func run() throws {
        token = try power.acquire(assertionType, reason: reason, onBehalfOf: nil)

        // Installed before spawning so a signal arriving during startup cannot
        // kill this process and orphan the assertion.
        installSignalHandlers()

        let pid: pid_t
        do {
            pid = try child.launch(invocation, resettingSignals: Self.signalsResetInChild)
        } catch let error as ChildLaunchError {
            fail(error)
        }
        childPID = pid

        // The command stays suspended until `resume`, which is what makes the
        // startup sequence race-free: it cannot read stdin before it owns the
        // terminal, and cannot print before the start line is out. Supervision is
        // in place first, so nothing between here and `resume` can leave the
        // command unattended.
        watchChild()
        terminal = TerminalForeground()
        terminal?.give(to: pid)
        renderer.renderProcessStart(command: invocation.displayName, type: assertionType)
        // Consume the initial suspension so it can never be misread as a Ctrl+Z.
        _ = child.wait(pid)
        child.resume(pid)

        dispatchMain()
    }

    // MARK: - Child supervision

    private func watchChild() {
        guard let childPID else { return }
        // `.signal` as well as `.exit`: a stopped command is not a finished one,
        // and the difference is only visible by waiting with `WUNTRACED` after a
        // signal was delivered to it.
        let source = DispatchSource.makeProcessSource(
            identifier: childPID,
            eventMask: [.exit, .signal],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.childStateChanged() }
        stateSource = source
        source.resume()
    }

    private func childStateChanged() {
        guard let childPID, !finished else { return }
        switch child.wait(childPID) {
        case .running:
            break
        case .stopped:
            handleStop()
        case .ended(let status):
            finish(status: status)
        case .unavailable:
            finishWithUnknownStatus()
        }
    }

    /// Mirrors the command's own stop, so Ctrl+Z stops the whole job.
    ///
    /// The command holds the terminal, so a `SIGTSTP` reaches it and not us. If
    /// this process just kept running, the shell would believe the job is still
    /// alive while nothing is reading the terminal — a hang. Handing the terminal
    /// back and stopping too makes the shell report `Stopped` and lets `fg`
    /// resume both halves. The assertion is deliberately kept: the command has
    /// not finished, it is only paused.
    private func handleStop() {
        guard !stopped else { return }
        stopped = true
        terminal?.restore()
        kill(getpid(), SIGSTOP)
    }

    /// Resumes the command after this process was continued, typically by `fg`.
    private func resumeAfterStop() {
        guard let childPID, stopped else { return }
        stopped = false
        // Ownership is re-evaluated: a job that started in the background never
        // held the terminal, but `fg` has just handed it to us.
        if terminal == nil { terminal = TerminalForeground() }
        terminal?.give(to: childPID)
        child.send(SIGCONT, toProcessGroup: childPID)
    }

    // MARK: - Signals

    private func installSignalHandlers() {
        // A vanished stdout reader must not be able to kill the supervisor mid
        // command — writes are failure-tolerant instead. The child gets the
        // default disposition back, so it still dies on a broken pipe as it would
        // if run directly.
        signal(SIGPIPE, SIG_IGN)

        for sig in Self.forwardedSignals + [SIGCONT] {
            // Ignore the default disposition so the dispatch source is the sole
            // handler; the child gets the default back via POSIX_SPAWN_SETSIGDEF.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                sig == SIGCONT ? self.resumeAfterStop() : self.forward(sig)
            }
            signalSources.append(source)
            source.resume()
        }
    }

    /// Relays a termination signal to the command's process group and keeps waiting.
    ///
    /// The session deliberately does not end here: the assertion is held until
    /// the command has actually exited, so it is never left running against a
    /// machine that has been allowed to sleep. The command is signalled as a
    /// group so its own children are torn down with it, and it is signalled only
    /// from here — it has its own process group, so a terminal Ctrl+C reaches it
    /// directly and never reaches this process, which is what keeps a single
    /// keypress from arriving twice.
    private func forward(_ sig: Int32) {
        guard let childPID else {
            // Signalled before the child existed: nothing to wait for.
            finish(status: .signalled(signal: sig))
            return
        }
        child.send(sig, toProcessGroup: childPID)
        // A stopped command would leave the signal pending indefinitely, holding
        // the assertion forever; wake it so the signal takes effect, as a shell
        // does when it terminates a stopped job.
        if stopped {
            stopped = false
            child.send(SIGCONT, toProcessGroup: childPID)
        }
    }

    // MARK: - Teardown

    private func finish(status: ExitStatus) {
        guard !finished else { return }
        finished = true
        teardown()

        let elapsed = max(0, clock().timeIntervalSince(start))
        renderer.renderProcessFinished(
            command: invocation.displayName,
            elapsed: elapsed,
            status: status
        )

        exit(status.exitCode)
    }

    /// The command is gone but `waitpid` could not say how it ended — only
    /// reachable if something else reaped it. Never claim it succeeded.
    private func finishWithUnknownStatus() {
        guard !finished else { return }
        finished = true
        teardown()

        FileHandle.standardError.write(
            Data("guaranate: \(invocation.displayName) ended, but its exit status could not be read\n".utf8)
        )
        exit(1)
    }

    /// Reports a launch failure with the shell's conventional exit codes and
    /// leaves no assertion behind.
    private func fail(_ error: ChildLaunchError) -> Never {
        teardown()
        FileHandle.standardError.write(Data("guaranate: \(error)\n".utf8))
        exit(error.exitCode)
    }

    /// Stops watching, gives the terminal back, and releases the assertion.
    /// Ordered so this process owns the terminal again before it writes anything.
    private func teardown() {
        stateSource?.cancel()
        stateSource = nil
        terminal?.restore()
        terminal = nil
        if let token {
            power.release(token)
            self.token = nil
        }
    }
}

/// The controlling terminal's foreground process group.
///
/// The command has to be the foreground group: otherwise reading stdin would
/// stop it with `SIGTTIN`. This process must *not* be in that group: a terminal
/// signal goes to every process in the foreground group, so sharing one would
/// mean a single Ctrl+C is delivered to the command once by the kernel and again
/// by the relay — enough to make tools that treat a second interrupt as "force
/// quit now" do exactly that on the first keypress.
private struct TerminalForeground {
    private let fd: Int32
    private let previous: pid_t

    /// Non-`nil` only while this process owns the terminal, so a background job
    /// never steals it from whatever is in the foreground.
    init?() {
        let fd = STDIN_FILENO
        guard isatty(fd) == 1 else { return nil }
        let foreground = tcgetpgrp(fd)
        guard foreground != -1, foreground == getpgrp() else { return nil }
        self.fd = fd
        self.previous = foreground
    }

    func give(to pgid: pid_t) {
        // `tcsetpgrp` from a background process group raises `SIGTTOU` at the
        // caller — which is exactly the situation when handing the terminal back.
        let previousDisposition = signal(SIGTTOU, SIG_IGN)
        tcsetpgrp(fd, pgid)
        signal(SIGTTOU, previousDisposition)
    }

    func restore() {
        give(to: previous)
    }
}
