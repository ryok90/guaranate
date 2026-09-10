import Darwin
import XCTest

@testable import GuaranateCore

/// The registration-before-disposition contract, exercised against the real
/// kernel: these use `SIGUSR1`/`SIGUSR2`, which nothing else in the suite touches,
/// and always ignore them first so a raised signal cannot end the test process.
final class SignalNotesTests: XCTestCase {
    private let registrar = KqueueSignalNotes()
    private var restore: [Int32: sig_t] = [:]

    private func ignore(_ sig: Int32) {
        restore[sig] = signal(sig, SIG_IGN)
    }

    override func tearDown() {
        for (sig, disposition) in restore { signal(sig, disposition) }
        restore = [:]
        super.tearDown()
    }

    /// Signals are sent the way a shell or the kernel sends them — to the process,
    /// not to a thread: `raise` is thread-directed and never becomes the
    /// process-level note this whole mechanism is built on.
    private func send(_ sig: Int32) {
        XCTAssertEqual(kill(getpid(), sig), 0, "could not signal this process")
    }

    func testReportsASignalRaisedAfterItsDispositionWasTakenOver() throws {
        let notes = try registrar.registerNotes(watching: [SIGUSR1])
        defer { notes.close() }

        // The order the supervisor uses: watch first, ignore second.
        ignore(SIGUSR1)
        XCTAssertEqual(notes.drain(), [], "no signal has been raised yet")

        send(SIGUSR1)
        XCTAssertEqual(notes.drain(), [SIGUSR1])
    }

    /// Why the order is not a matter of taste: an ignored signal leaves nothing
    /// behind on this platform, so a supervisor that took the disposition over
    /// before the kernel was watching would silently drop the signal — a Ctrl+C
    /// swallowed at startup instead of relayed to the command.
    func testASignalRaisedBeforeRegistrationIsGoneForGood() throws {
        ignore(SIGUSR2)
        send(SIGUSR2)

        let notes = try registrar.registerNotes(watching: [SIGUSR2])
        defer { notes.close() }
        XCTAssertEqual(notes.drain(), [], "an ignored signal is discarded, not queued")
    }

    func testReportsEverySignalItWatches() throws {
        let notes = try registrar.registerNotes(watching: [SIGUSR1, SIGUSR2])
        defer { notes.close() }
        ignore(SIGUSR1)
        ignore(SIGUSR2)

        send(SIGUSR1)
        send(SIGUSR2)
        XCTAssertEqual(notes.drain().sorted(), [SIGUSR1, SIGUSR2].sorted())
    }

    /// Repeat arrivals coalesce, exactly as they do for a dispatch signal source:
    /// a relay is per signal, not per delivery.
    func testCoalescesRepeatArrivalsOfOneSignal() throws {
        let notes = try registrar.registerNotes(watching: [SIGUSR1])
        defer { notes.close() }
        ignore(SIGUSR1)

        send(SIGUSR1)
        send(SIGUSR1)
        XCTAssertEqual(notes.drain(), [SIGUSR1])
        XCTAssertEqual(notes.drain(), [], "the note is consumed by the drain that reports it")
    }

    /// The order a session installs in: blocked, registered, then ignored. Blocked
    /// is what makes it airtight — the signal can neither take its default action
    /// nor be discarded by the disposition change, and its note is still recorded.
    func testRecordsASignalThatArrivesDuringABlockedInstall() throws {
        var notes: (any SignalNoteReading)?
        defer { notes?.close() }

        try withSignalsBlocked([SIGUSR1]) {
            notes = try registrar.registerNotes(watching: [SIGUSR1])
            send(SIGUSR1)  // would end this process unblocked: SIGUSR1 defaults to death
            ignore(SIGUSR1)
        }

        XCTAssertEqual(notes?.drain(), [SIGUSR1], "the note outlived both the block and the ignore")
    }

    func testClosingTwiceIsHarmless() throws {
        let notes = try registrar.registerNotes(watching: [SIGUSR1])
        notes.close()
        notes.close()
        XCTAssertEqual(notes.drain(), [], "a closed registration reports nothing")
    }

    /// Masks are per-thread, dispositions are not — which is why the disposition is
    /// what stands between a signal and the default action. `SIGUSR1` defaults to
    /// death, and this test process has other threads that mask nothing, so surviving
    /// it is the whole assertion.
    func testClaimedSignalCannotEndThisProcess() {
        restore[SIGUSR1] = signal(SIGUSR1, SIG_DFL)
        XCTAssertEqual(claimSignals([SIGUSR1]), [SIGUSR1], "a default disposition is one this changed")

        send(SIGUSR1)
        XCTAssertTrue(true, "still running, so no thread took the default action")
    }

    /// The caller's own choices are reported as untouched, so they are not reset in a
    /// command that would have inherited them.
    func testClaimReportsOnlyTheDispositionsItChanged() {
        restore[SIGUSR1] = signal(SIGUSR1, SIG_IGN)
        restore[SIGUSR2] = signal(SIGUSR2, SIG_DFL)

        XCTAssertEqual(claimSignals([SIGUSR1, SIGUSR2]), [SIGUSR2])
    }
}
