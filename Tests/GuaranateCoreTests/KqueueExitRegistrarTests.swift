import Darwin
import XCTest

@testable import GuaranateCore

/// Exercises the real `kqueue` registration against short-lived helpers.
final class KqueueExitRegistrarTests: XCTestCase {
    private let child = ChildProcess()
    private let inspector = SystemProcessInspector()
    private let registrar = KqueueExitRegistrar()

    /// Launches a helper and returns the identity the kernel reports for it.
    private func startHelper(_ argv: [String]) throws -> (pid: pid_t, identity: ProcessIdentity) {
        let pid = try child.launch(CommandInvocation(argv: argv), resettingSignals: [])
        child.resume(pid)
        return (pid, try inspector.identity(of: pid))
    }

    private func reap(_ pid: pid_t) {
        child.send(SIGKILL, toProcessGroup: pid)
        var discarded: Int32 = 0
        waitpid(pid, &discarded, 0)
    }

    /// The registration has to become readable when that process ends, and not
    /// before: readability is the only thing the session waits on.
    func testDescriptorBecomesReadableWhenTheProcessExits() throws {
        let helper = try startHelper(["/bin/sh", "-c", "exit 0"])
        let descriptor = try registrar.registerExit(of: helper.identity)
        defer { close(descriptor) }

        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&poller, 1, 10_000), 1, "exit was never reported")
        XCTAssertEqual(poller.revents & Int16(POLLIN), Int16(POLLIN))
        reap(helper.pid)
    }

    /// A live process must not be reported as ended — the assertion is held for
    /// exactly as long as the work runs.
    func testDescriptorStaysQuietWhileTheProcessRuns() throws {
        let helper = try startHelper(["/bin/sh", "-c", "sleep 5"])
        defer { reap(helper.pid) }
        let descriptor = try registrar.registerExit(of: helper.identity)
        defer { close(descriptor) }

        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&poller, 1, 300), 0, "a running process was reported as exited")
    }

    /// The registration is what pins the watch to one process, so a pid whose
    /// start time no longer matches must be refused rather than watched: that is
    /// a recycled pid, and it must never inherit the assertion.
    func testRejectsAPidWhoseIdentityNoLongerMatches() throws {
        let helper = try startHelper(["/bin/sh", "-c", "sleep 5"])
        defer { reap(helper.pid) }
        let recycled = ProcessIdentity(
            pid: helper.identity.pid,
            startedAt: helper.identity.startedAt + 1,
            name: helper.identity.name
        )

        XCTAssertThrowsError(try registrar.registerExit(of: recycled)) { error in
            XCTAssertEqual(error as? ProcessLookupError, .noSuchProcess(helper.pid))
        }
    }

    /// Nothing to register against reads as "already over", never as success.
    func testRejectsAPidThatIsNotRunning() {
        let identity = ProcessIdentity(pid: 999_999, startedAt: 0, name: nil)
        XCTAssertThrowsError(try registrar.registerExit(of: identity)) { error in
            XCTAssertEqual(error as? ProcessLookupError, .noSuchProcess(999_999))
        }
    }
}
