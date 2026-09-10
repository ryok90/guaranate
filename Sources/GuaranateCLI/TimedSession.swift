import Dispatch
import Foundation
import GuaranateCore

/// Drives an interactive keep-awake session that ends on a deadline, on a
/// watched process exiting, or on user interruption.
///
/// Lifecycle:
/// 1. Acquire the requested power assertion.
/// 2. Render elapsed / remaining / end time once per second.
/// 3. On expiry, on the watched process exiting, or on `q`/Ctrl+C (SIGINT) or
///    SIGTERM: release the assertion and exit.
///
/// The assertion is released on every exit path, so no stale sleep inhibitor is
/// left behind. All state is touched only on the main dispatch queue.
final class TimedSession: @unchecked Sendable {
    private let start: Date
    private let deadline: Deadline?
    private let assertionType: PowerAssertionType
    private let reason: String
    private let power: PowerAsserting
    private let renderer: TerminalRenderer
    private let watching: ProcessIdentity?
    private let registrar: ProcessExitRegistering
    private let signalRegistrar: SignalNoteRegistering

    private var token: PowerAssertionToken?
    private var renderTimer: DispatchSourceTimer?
    private var notes: (any SignalNoteReading)?
    private var noteSource: DispatchSourceRead?
    private var keyboardSource: DispatchSourceRead?
    private var watchSource: DispatchSourceRead?
    private var originalTerminal: termios?
    private var finished = false

    init(
        durationSeconds: Int?,
        watching: ProcessIdentity? = nil,
        assertionType: PowerAssertionType,
        reason: String,
        power: PowerAsserting,
        registrar: ProcessExitRegistering = KqueueExitRegistrar(),
        signalRegistrar: SignalNoteRegistering = KqueueSignalNotes(),
        renderer: TerminalRenderer = TerminalRenderer(),
        now: Date = Date()
    ) {
        self.start = now
        self.deadline = durationSeconds.map { Deadline(start: now, duration: TimeInterval($0)) }
        self.watching = watching
        self.assertionType = assertionType
        self.reason = reason
        self.power = power
        self.registrar = registrar
        self.signalRegistrar = signalRegistrar
        self.renderer = renderer
    }

    /// Acquires the assertion and blocks the process until the session ends.
    func run() throws {
        token = try power.acquire(assertionType, reason: reason, onBehalfOf: watching?.pid)

        // Before the first write, and before anything else can end the process:
        // once the assertion exists, neither a signal nor a vanished reader on
        // stdout may cut the session short.
        do {
            try installSignalHandlers()
        } catch {
            failToSupervise(error)
            return
        }
        renderer.renderStart(deadline: deadline, type: assertionType, watching: watching?.displayName)

        startRenderTimer()
        installKeyboard()
        installWatch()

        dispatchMain()
    }

    // MARK: - Timers and signals

    private func startRenderTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        renderTimer = timer
        timer.resume()
    }

    private func installSignalHandlers() throws {
        // The same order and the same reasons as the process session: dispositions
        // first and process-wide, because a mask is per-thread and cannot stop every
        // thread from taking a default action; then the watch, blocked, so a signal
        // arriving in between is neither lost nor acted on; then `SIG_IGN`, which
        // discards what is pending and so must come after the note exists.
        //
        // `SIGPIPE` and `SIGTTOU` are taken over too, and never relayed: neither a
        // vanished reader nor a background write on a `tostop` terminal may end a
        // session the user asked to last a fixed time. The frame writes tolerate
        // failure instead.
        let watched = [SIGINT, SIGTERM]
        let taken = watched + [SIGPIPE, SIGTTOU]
        _ = claimSignals(taken)

        let notes = try withSignalsBlocked(taken) {
            let notes = try signalRegistrar.registerNotes(watching: watched)
            for sig in taken { signal(sig, SIG_IGN) }
            return notes
        }
        self.notes = notes

        let source = DispatchSource.makeReadSource(fileDescriptor: notes.descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, !notes.drain().isEmpty else { return }
            self.finish(interrupted: true)
        }
        source.setCancelHandler { notes.close() }
        noteSource = source
        source.resume()
    }

    /// Ends the session when the watched process exits.
    ///
    /// Registration is synchronous, and the identity is re-read only once it has
    /// landed: any other order leaves a window where the watched process exits,
    /// its pid is recycled, and the watch attaches to an unrelated process that
    /// would then own our assertion. A process that ends inside that window is
    /// reported by registration itself, so the session still finishes exactly once.
    private func installWatch() {
        guard let watching else { return }

        let descriptor: Int32
        do {
            descriptor = try registrar.registerExit(of: watching)
        } catch ProcessLookupError.noSuchProcess {
            // The work ended inside the startup window: that is a finished
            // session, and the assertion must not outlive it.
            finish(interrupted: false)
            return
        } catch {
            // Anything else means the kernel would not report the exit — a
            // resource or permission failure, not an ending. Reporting success
            // here would release the assertion and exit 0 while the process it was
            // asked to protect is still running.
            failToSupervise(error)
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in self?.finish(interrupted: false) }
        source.setCancelHandler { close(descriptor) }
        watchSource = source
        source.resume()
    }

    /// Puts the terminal in cbreak mode (no line buffering, no echo) so a lone
    /// `q`/`Q` keypress ends the session. `ISIG` stays enabled so Ctrl+C still
    /// raises SIGINT. The original attributes are restored on every exit path via
    /// `restoreTerminal` in `finish`.
    ///
    /// Skipped unless both stdin and stdout are TTYs (the live frame's control)
    /// *and* this process owns the terminal. A background session must not reach
    /// for the keyboard at all: changing modes there fights the shell for the
    /// user's line editing, and reading the terminal raises `SIGTTIN`, which would
    /// stop the session on the first keystroke while it still holds the assertion.
    private func installKeyboard() {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return }
        guard tcgetpgrp(STDIN_FILENO) == getpgrp() else { return }
        var attrs = termios()
        guard tcgetattr(STDIN_FILENO, &attrs) == 0 else { return }
        originalTerminal = attrs
        attrs.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &attrs)

        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        source.setEventHandler { [weak self] in
            var byte: UInt8 = 0
            let n = read(STDIN_FILENO, &byte, 1)
            guard n > 0 else { self?.keyboardSource?.cancel(); return }
            if byte == UInt8(ascii: "q") || byte == UInt8(ascii: "Q") {
                self?.finish(interrupted: true)
            }
        }
        keyboardSource = source
        source.resume()
    }

    /// Restores the terminal attributes saved by `installKeyboard`, if any.
    private func restoreTerminal() {
        guard var attrs = originalTerminal else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &attrs)
        originalTerminal = nil
    }

    private func tick() {
        let now = Date()
        if let deadline, deadline.isExpired(at: now) {
            finish(interrupted: false)
        } else {
            renderer.renderFrame(
                deadline: deadline,
                start: start,
                type: assertionType,
                now: now,
                watching: watching?.displayName
            )
        }
    }

    // MARK: - Teardown

    private func finish(interrupted: Bool) {
        guard !finished else { return }
        finished = true

        renderTimer?.cancel()
        renderTimer = nil
        keyboardSource?.cancel()
        keyboardSource = nil
        watchSource?.cancel()
        watchSource = nil
        restoreTerminal()

        if let token {
            power.release(token)
            self.token = nil
        }

        let elapsed = max(0, Date().timeIntervalSince(start))
        renderer.renderFinished(elapsed: elapsed, interrupted: interrupted, type: assertionType)

        // SIGINT conventionally maps to 128 + signal number.
        renderer.flush()
        exit(interrupted ? 130 : 0)
    }

    /// The session cannot do the one thing it exists for: either the watched
    /// process's exit cannot be reported, or this process cannot be signalled.
    /// Releases, says so, and exits nonzero — a caller that reads exit codes must
    /// be able to tell this apart from work that finished.
    private func failToSupervise(_ error: Error) {
        guard !finished else { return }
        finished = true

        renderTimer?.cancel()
        renderTimer = nil
        keyboardSource?.cancel()
        keyboardSource = nil
        restoreTerminal()

        if let token {
            power.release(token)
            self.token = nil
        }

        renderer.renderDiagnostic("\(error)")
        // EX_OSERR: the request was valid, the system could not carry it out.
        renderer.flush()
        exit(71)
    }
}
