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

    /// Signals whose disposition this process took over and must therefore restore
    /// in the child, recorded as they are taken so an inherited `SIG_IGN` is never
    /// undone. See `take(_:)`.
    private var signalsToResetInChild: [Int32] = []

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
    private var notes: SignalNotes?
    private var noteSource: DispatchSourceRead?
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
        // kill this process and orphan the assertion. A supervisor that cannot be
        // signalled cannot be cancelled either, so a failure here is fatal rather
        // than quietly accepted — and it happens before any child exists.
        do {
            try installSignalHandlers()
        } catch {
            failToSupervise(error)
        }

        let pid: pid_t
        do {
            pid = try child.launch(invocation, resettingSignals: signalsToResetInChild)
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
        // Announced before the handover, while this process is still the
        // foreground group. Afterwards it is a background one, where a terminal
        // with `tostop` set turns this very line into a `SIGTTOU` stop or an
        // `EIO` failure. The command is suspended either way, so nothing of its
        // own can interleave.
        renderer.renderProcessStart(command: invocation.displayName, type: assertionType)
        terminal = TerminalForeground()
        if let failure = terminal?.give(to: pid) {
            // Owning the terminal but being refused the handover is not silent, and
            // not fatal either: the command runs in a background group, where only
            // reading stdin would stop it — and a `fg` after that stop re-hands the
            // terminal, which is the same recovery Ctrl+Z already uses. Ownership is
            // dropped so teardown does not claim back something never handed over.
            renderer.renderDiagnostic("\(failure)")
            terminal = nil
        }

        // Consume the initial suspension so it can never be misread as a Ctrl+Z —
        // and honor it if the command was killed while it was still suspended,
        // because this wait is the only one that will ever see that status.
        switch child.wait(pid) {
        case .ended(let status):
            finish(status: status)
        case .stopped, .running, .unavailable:
            child.resume(pid)
        }

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
        reportTerminal(terminal?.restore())
        // Ownership ends with the pause. Whoever continues the job decides who owns
        // the terminal next: `fg` hands it to this process, `bg` keeps it for the
        // shell — so holding on to a stale claim here is how a background job comes
        // back and takes the shell's terminal away from it.
        terminal = nil
        // Termination signals stay ignored across the pause, so they stay this
        // process's to relay, and the kernel's note of one that arrives now
        // outlives the pause. A stopped process runs no code, so it is acted on
        // once something continues this one: `fg`, `bg`, an interactive shell's
        // `kill %job` (which continues a job it knows is stopped), `kill -CONT`,
        // or the kernel itself, which owes `SIGHUP` and `SIGCONT` to a process
        // group that becomes orphaned while stopped — the terminal-closed case.
        // Handing the signals back to the kernel instead would end this process
        // without relaying anything, orphaning a command that ignores `SIGHUP` — a
        // running command behind a released assertion, the one outcome that must
        // never happen.
        kill(getpid(), SIGSTOP)
    }

    /// Resumes the command after this process was continued, typically by `fg`.
    private func resumeAfterStop() {
        guard let childPID, stopped else { return }
        stopped = false
        // Ownership is re-evaluated rather than assumed: this constructs a claim
        // only while this process really is the terminal's foreground group, which
        // is true after `fg` and false after `bg`.
        terminal = TerminalForeground()
        reportTerminal(terminal?.give(to: childPID))
        child.send(SIGCONT, toProcessGroup: childPID)
    }

    /// Surfaces a refused terminal move. There is nothing to recover here — the
    /// command keeps running either way — but a supervisor that quietly loses the
    /// terminal leaves a command that behaves differently for no visible reason.
    private func reportTerminal(_ failure: TerminalHandoffFailure?) {
        guard let failure else { return }
        renderer.renderDiagnostic("\(failure)")
    }

    // MARK: - Signals

    private func installSignalHandlers() throws {
        // Registration comes first, and the dispositions second. This platform
        // discards whatever is pending for a signal the moment its disposition
        // becomes `SIG_IGN`, so taking the signals over before the kernel is
        // watching them would drop a Ctrl+C that lands in the gap instead of
        // relaying it.
        let watched = Self.forwardedSignals + [SIGCONT]
        let notes = try SignalNotes(watching: watched)
        self.notes = notes

        let source = DispatchSource.makeReadSource(fileDescriptor: notes.descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            for sig in notes.drain() {
                sig == SIGCONT ? self.resumeAfterStop() : self.forward(sig)
            }
        }
        source.setCancelHandler { notes.close() }
        noteSource = source
        source.resume()

        // Now the dispositions: ignored so the kernel's default action cannot end
        // or stop this process behind the relay's back. The child gets them back
        // via POSIX_SPAWN_SETSIGDEF.
        for sig in watched { take(sig) }

        // Status output must never be able to end or stop a session that already
        // holds an assertion. A vanished reader would otherwise raise `SIGPIPE`,
        // and a write from the background group — which is what this process
        // becomes once the command owns the terminal — would raise `SIGTTOU` on a
        // terminal with `tostop` set. Writes are failure-tolerant instead. The
        // command gets both dispositions back, so it still dies on a broken pipe
        // and still stops on a background write, exactly as if it were run
        // directly. Neither is relayed, so neither needs a note.
        take(SIGPIPE)
        take(SIGTTOU)
    }

    /// Takes a signal over from the kernel, and records whether the command will
    /// need its default disposition restored.
    ///
    /// `SIG_IGN` is inherited across `exec`, so every signal this process ignores
    /// has to be reset in the child or the command would be deaf to it. Every
    /// signal — except one the surrounding shell was *already* ignoring: that
    /// disposition is inherited too, and the command would have inherited it
    /// without Guaranate in front. Resetting those would make a wrapped command
    /// die where the same command run directly survives.
    private func take(_ sig: Int32) {
        let previous = signal(sig, SIG_IGN)
        // Dispositions are C function pointers, which Swift will not compare
        // directly; `SIG_IGN` and `SIG_DFL` are sentinel addresses, so the bit
        // patterns are the comparison.
        let wasIgnored = unsafeBitCast(previous, to: UInt.self)
            == unsafeBitCast(SIG_IGN, to: UInt.self)
        if !wasIgnored {
            signalsToResetInChild.append(sig)
        }
    }

    /// Relays a termination signal to the command's process group and keeps waiting.
    ///
    /// The session deliberately does not end here: the assertion is held until
    /// the command has actually exited, so it is never left running against a
    /// machine that has been allowed to sleep. The command is signalled as a
    /// group, so its own descendants are signalled with it rather than left behind
    /// a released assertion — signalled, not guaranteed to die: one that ignores
    /// or survives the signal keeps running, exactly as it would have without
    /// Guaranate in front. It is signalled only from here — it has its own process
    /// group, so a terminal Ctrl+C reaches it directly and never reaches this
    /// process, which is what keeps a single keypress from arriving twice.
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

        renderer.renderDiagnostic("\(invocation.displayName) ended, but its exit status could not be read")
        exit(1)
    }

    /// Reports a launch failure with the shell's conventional exit codes and
    /// leaves no assertion behind.
    private func fail(_ error: ChildLaunchError) -> Never {
        teardown()
        // Through the renderer, not `FileHandle`: a closed stderr must not turn a
        // missing command into an abort, because 127 is the contract a script reads.
        renderer.renderDiagnostic("\(error)")
        exit(error.exitCode)
    }

    /// Reports a supervisor that could not be established, before any command was
    /// launched. `EX_OSERR`, the same code a watch that cannot be attached uses:
    /// the request was valid, the system could not carry it out.
    private func failToSupervise(_ error: Error) -> Never {
        teardown()
        renderer.renderDiagnostic("\(error)")
        exit(71)
    }

    /// Stops watching, gives the terminal back, and releases the assertion.
    /// Ordered so this process owns the terminal again before it writes anything.
    private func teardown() {
        stateSource?.cancel()
        stateSource = nil
        noteSource?.cancel()
        noteSource = nil
        notes = nil
        reportTerminal(terminal?.restore())
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

    /// Hands the terminal to `pgid`, reporting why the kernel refused if it did.
    ///
    /// A silently failed handover is the worst outcome available: the command would
    /// run in a background process group, where reading stdin stops it with
    /// `SIGTTIN` instead of working the way the same command works unwrapped.
    func give(to pgid: pid_t) -> TerminalHandoffFailure? {
        // `tcsetpgrp` from a background process group raises `SIGTTOU` at the
        // caller — which is exactly the situation when handing the terminal back.
        let previousDisposition = signal(SIGTTOU, SIG_IGN)
        defer { signal(SIGTTOU, previousDisposition) }
        while true {
            if tcsetpgrp(fd, pgid) == 0 { return nil }
            // Captured before the deferred `signal` call, or anything else, can
            // overwrite it: a diagnostic reading ambient `errno` later is a lie.
            let code = errno
            guard code == EINTR else {
                return TerminalHandoffFailure(pgid: pgid, code: code)
            }
        }
    }

    /// Gives the terminal back to whoever held it before this process took over.
    func restore() -> TerminalHandoffFailure? {
        give(to: previous)
    }
}

/// Why the kernel refused to move the terminal's foreground process group.
struct TerminalHandoffFailure: Error, CustomStringConvertible {
    let pgid: pid_t
    let code: Int32

    var description: String {
        "could not hand the terminal to process group \(pgid): "
            + String(cString: strerror(code))
    }
}
