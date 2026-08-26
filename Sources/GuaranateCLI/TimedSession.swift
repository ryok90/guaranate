import Dispatch
import Foundation
import GuaranateCore

/// Drives an interactive timed keep-awake session.
///
/// Lifecycle:
/// 1. Acquire the requested power assertion.
/// 2. Render elapsed / remaining / end time once per second.
/// 3. On expiry, Ctrl+C (SIGINT), or SIGTERM: release the assertion and exit.
///
/// The assertion is released on every exit path, so no stale sleep inhibitor is
/// left behind. All state is touched only on the main dispatch queue.
final class TimedSession: @unchecked Sendable {
    private let deadline: Deadline
    private let assertionType: PowerAssertionType
    private let reason: String
    private let power: PowerAsserting
    private let renderer: TerminalRenderer

    private var token: PowerAssertionToken?
    private var renderTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var finished = false

    init(
        durationSeconds: Int,
        assertionType: PowerAssertionType,
        reason: String,
        power: PowerAsserting,
        renderer: TerminalRenderer = TerminalRenderer(),
        now: Date = Date()
    ) {
        self.deadline = Deadline(start: now, duration: TimeInterval(durationSeconds))
        self.assertionType = assertionType
        self.reason = reason
        self.power = power
        self.renderer = renderer
    }

    /// Acquires the assertion and blocks the process until the session ends.
    func run() throws {
        token = try power.acquire(assertionType, reason: reason)
        renderer.renderStart(deadline: deadline, type: assertionType)

        installSignalHandlers()
        startRenderTimer()

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

    private func tick() {
        let now = Date()
        if deadline.isExpired(at: now) {
            finish(interrupted: false)
        } else {
            renderer.renderFrame(deadline: deadline, type: assertionType, now: now)
        }
    }

    // MARK: - Teardown

    private func finish(interrupted: Bool) {
        guard !finished else { return }
        finished = true

        renderTimer?.cancel()
        renderTimer = nil

        if let token {
            power.release(token)
            self.token = nil
        }

        let elapsed = deadline.elapsed(at: Date())
        renderer.renderFinished(elapsed: elapsed, interrupted: interrupted)

        // SIGINT conventionally maps to 128 + signal number.
        exit(interrupted ? 130 : 0)
    }
}
