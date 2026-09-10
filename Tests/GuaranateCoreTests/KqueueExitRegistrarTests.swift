import Darwin
import XCTest

@testable import GuaranateCore

/// Exercises the real `kqueue` registration against short-lived helpers.
///
/// Helpers stay suspended through lookup and registration: a helper that is
/// already running can exit first, and a process that has exited is a different
/// case (`ProcessIdentityTests` owns that one). Suspending removes the race
/// instead of tolerating it.
final class KqueueExitRegistrarTests: XCTestCase {
    private let child = ChildProcess()
    private let inspector = SystemProcessInspector()
    private let registrar = KqueueExitRegistrar()

    /// Launches a suspended helper. Cleanup belongs to the caller's `defer`,
    /// installed before anything that can throw, so a failure cannot leak it.
    private func launchSuspended(_ argv: [String]) throws -> pid_t {
        try child.launch(CommandInvocation(argv: argv), resettingSignals: [])
    }

    private func reap(_ pid: pid_t) {
        child.send(SIGCONT, toProcessGroup: pid)
        child.send(SIGKILL, toProcessGroup: pid)
        var discarded: Int32 = 0
        waitpid(pid, &discarded, 0)
    }

    private func isReadable(_ descriptor: Int32, within milliseconds: Int32) -> Bool {
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&poller, 1, milliseconds) == 1 && poller.revents & Int16(POLLIN) != 0
    }

    /// The registration has to become readable when that process ends, and not
    /// before: readability is the only thing the session waits on.
    func testDescriptorBecomesReadableWhenTheProcessExits() throws {
        let pid = try launchSuspended(["/bin/sh", "-c", "exit 0"])
        defer { reap(pid) }

        let descriptor = try registrar.registerExit(of: inspector.identity(of: pid))
        defer { close(descriptor) }

        XCTAssertFalse(isReadable(descriptor, within: 100), "reported an exit before the process ran")
        child.resume(pid)
        XCTAssertTrue(isReadable(descriptor, within: 10_000), "exit was never reported")
    }

    /// A live process must not be reported as ended — the assertion is held for
    /// exactly as long as the work runs.
    func testDescriptorStaysQuietWhileTheProcessRuns() throws {
        let pid = try launchSuspended(["/bin/sh", "-c", "sleep 5"])
        defer { reap(pid) }

        let descriptor = try registrar.registerExit(of: inspector.identity(of: pid))
        defer { close(descriptor) }
        child.resume(pid)

        XCTAssertFalse(isReadable(descriptor, within: 300), "a running process was reported as exited")
    }

    /// The registration is what pins the watch to one process, so a pid whose
    /// start time no longer matches must be refused rather than watched: that is
    /// a recycled pid, and it must never inherit the assertion.
    func testRejectsAPidWhoseIdentityNoLongerMatches() throws {
        let pid = try launchSuspended(["/bin/sh", "-c", "sleep 5"])
        defer { reap(pid) }

        let real = try inspector.identity(of: pid)
        let recycled = ProcessIdentity(pid: real.pid, startedAt: real.startedAt + 1, name: real.name)

        XCTAssertThrowsError(try registrar.registerExit(of: recycled)) { error in
            XCTAssertEqual(error as? ProcessLookupError, .noSuchProcess(pid))
        }
    }

    /// Nothing to register against reads as "already over", never as success —
    /// and never as an operational failure, which callers treat differently.
    func testRejectsAPidThatIsNotRunning() {
        let identity = ProcessIdentity(pid: 999_999, startedAt: 0, name: nil)
        XCTAssertThrowsError(try registrar.registerExit(of: identity)) { error in
            XCTAssertEqual(error as? ProcessLookupError, .noSuchProcess(999_999))
        }
    }
}
