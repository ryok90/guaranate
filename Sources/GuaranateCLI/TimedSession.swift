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
    private let inspector: ProcessInspecting

    private var token: PowerAssertionToken?
    private var renderTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var keyboardSource: DispatchSourceRead?
    private var watchSource: DispatchSourceProcess?
    private var originalTerminal: termios?
    private var finished = false

    init(
        durationSeconds: Int?,
        watching: ProcessIdentity? = nil,
        assertionType: PowerAssertionType,
        reason: String,
        power: PowerAsserting,
        inspector: ProcessInspecting = SystemProcessInspector(),
        renderer: TerminalRenderer = TerminalRenderer(),
        now: Date = Date()
    ) {
        self.start = now
        self.deadline = durationSeconds.map { Deadline(start: now, duration: TimeInterval($0)) }
        self.watching = watching
        self.assertionType = assertionType
        self.reason = reason
        self.power = power
        self.inspector = inspector
        self.renderer = renderer
    }

    /// Acquires the assertion and blocks the process until the session ends.
    func run() throws {
        token = try power.acquire(assertionType, reason: reason, onBehalfOf: watching?.pid)
        renderer.renderStart(deadline: deadline, type: assertionType, watching: watching?.displayName)

        installSignalHandlers()
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

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            // Ignore the default disposition so the dispatch source is the sole handler.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.finish(interrupted: true) }
            signalSources.append(source)
            source.resume()
        }
    }

    /// Ends the session when the watched process exits.
    ///
    /// libdispatch synthesizes an exit event when kqueue registration fails with
    /// `ESRCH`, so a process that dies between lookup and registration still ends
    /// the session exactly once. Re-reading the identity afterwards covers the
    /// inverse hazard: a pid recycled in that same window now belongs to an
    /// unrelated process, which must not inherit our assertion.
    private func installWatch() {
        guard let watching else { return }

        let source = DispatchSource.makeProcessSource(
            identifier: watching.pid,
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.finish(interrupted: false) }
        watchSource = source
        source.resume()

        let current = try? inspector.identity(of: watching.pid)
        if current?.isSameProcess(as: watching) != true {
            finish(interrupted: false)
        }
    }

    /// Puts the terminal in cbreak mode (no line buffering, no echo) so a lone
    /// `q`/`Q` keypress ends the session. `ISIG` stays enabled so Ctrl+C still
    /// raises SIGINT. No-op unless both stdin and stdout are TTYs (the live
    /// frame's control); the original attributes are restored on every exit
    /// path via `restoreTerminal` in `finish`.
    private func installKeyboard() {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return }
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
        exit(interrupted ? 130 : 0)
    }
}
