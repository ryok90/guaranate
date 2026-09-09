import XCTest

@testable import GuaranateCore

/// Exercises the real `posix_spawnp` path. Spawning short-lived helpers is safe
/// here — unlike the power assertions, it does not touch host state.
final class ChildProcessTests: XCTestCase {
    private let child = ChildProcess()

    /// `wait` is non-blocking by design (it runs inside a dispatch event
    /// handler), so tests poll it.
    private func waitForExit(
        pid: pid_t,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ExitStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .ended(let status) = child.wait(pid) { return status }
            usleep(2_000)
        }
        // Never a skip: a `wait` that stopped reporting exits has to fail the
        // suite, not quietly excuse itself from it. Take the child down with it,
        // so a failing test cannot leak a process into the rest of the run.
        child.send(SIGKILL, toProcessGroup: pid)
        var discarded: Int32 = 0
        waitpid(pid, &discarded, 0)
        XCTFail("child \(pid) did not exit within \(timeout)s", file: file, line: line)
        throw ChildLaunchError.spawnFailed(command: "\(pid)", code: ETIMEDOUT)
    }

    /// Every child comes back suspended, so tests share one "launch and go".
    private func start(_ argv: [String], resettingSignals: [Int32] = []) throws -> pid_t {
        let pid = try child.launch(CommandInvocation(argv: argv), resettingSignals: resettingSignals)
        child.resume(pid)
        return pid
    }

    /// A command can die before it is ever resumed — something else kills it, or the
    /// system does. The supervisor's first wait is the only one that will ever see
    /// that status, so it must report the real signal death instead of treating a
    /// never-started command as a clean exit.
    func testReportsARealSignalDeathForACommandKilledWhileSuspended() throws {
        let pid = try child.launch(
            CommandInvocation(argv: ["/bin/sh", "-c", "exit 0"]),
            resettingSignals: []
        )
        // Never resumed: killed where the supervisor's startup sequence would find
        // it, between the spawn and the first wait.
        XCTAssertEqual(kill(pid, SIGKILL), 0, "could not kill the suspended command")

        // `wait` never blocks, and the initial suspension may be reported once
        // before the death is, so both non-final outcomes are polled through.
        var outcome = child.wait(pid)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .ended = outcome { break }
            usleep(5_000)
            outcome = child.wait(pid)
        }
        XCTAssertEqual(outcome, .ended(.signalled(signal: SIGKILL)))
    }

    private func waitUntil(
        _ timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(5_000)
        }
        return false
    }

    func testPropagatesChildExitCode() throws {
        let pid = try start(["/bin/sh", "-c", "exit 7"])
        XCTAssertEqual(try waitForExit(pid: pid), .exited(code: 7))
    }

    func testReportsSignalDeath() throws {
        let pid = try start(["/bin/sh", "-c", "kill -TERM $$"])
        XCTAssertEqual(try waitForExit(pid: pid), .signalled(signal: SIGTERM))
    }

    /// Resolving through `PATH` is what makes `guaranate while npm test` work
    /// without an absolute path.
    func testResolvesExecutableThroughPATH() throws {
        let pid = try start(["true"])
        XCTAssertEqual(try waitForExit(pid: pid), .exited(code: 0))
    }

    func testMissingCommandExitsWith127() throws {
        let invocation = try CommandInvocation(argv: ["guaranate-does-not-exist"])
        XCTAssertThrowsError(try child.launch(invocation, resettingSignals: [])) { error in
            XCTAssertEqual(
                error as? ChildLaunchError,
                .notFound(command: "guaranate-does-not-exist")
            )
            XCTAssertEqual((error as? ChildLaunchError)?.exitCode, 127)
        }
    }

    func testUnrunnableCommandExitsWith126() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("guaranate-not-executable-\(getpid())")
        try Data("nope".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        defer { try? FileManager.default.removeItem(at: path) }

        let invocation = try CommandInvocation(argv: [path.path])
        XCTAssertThrowsError(try child.launch(invocation, resettingSignals: [])) { error in
            XCTAssertEqual(error as? ChildLaunchError, .notExecutable(command: path.path))
            XCTAssertEqual((error as? ChildLaunchError)?.exitCode, 126)
        }
    }

    /// The parent sets termination signals to `SIG_IGN` so its dispatch sources
    /// are the sole handlers — and `SIG_IGN` is inherited across `exec`. Without
    /// `POSIX_SPAWN_SETSIGDEF` the child would silently become immune to Ctrl+C,
    /// so this asserts the child can still be killed by the signal it was sent.
    func testResetsInheritedIgnoredSignals() throws {
        let previous = signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, previous) }

        let ignored = try start(["/bin/sh", "-c", "kill -INT $$; exit 0"])
        XCTAssertEqual(
            try waitForExit(pid: ignored),
            .exited(code: 0),
            "without a reset the child inherits SIG_IGN and survives its own SIGINT"
        )

        let reset = try start(["/bin/sh", "-c", "kill -INT $$; exit 0"], resettingSignals: [SIGINT])
        XCTAssertEqual(
            try waitForExit(pid: reset),
            .signalled(signal: SIGINT),
            "with the reset the child dies from SIGINT as it would if run directly"
        )
    }

    /// The command leads a process group of its own. That is what lets a terminal
    /// signal reach the command and its descendants without also reaching the
    /// supervisor — which would deliver a single Ctrl+C to the command twice.
    func testChildLeadsItsOwnProcessGroup() throws {
        let pid = try start(["/bin/sh", "-c", "exit 0"])
        // Read the group before reaping, while the pid is still valid.
        XCTAssertEqual(getpgid(pid), pid, "the child should be its own process-group leader")
        XCTAssertNotEqual(getpgid(pid), getpgrp(), "the child must not share our group")
        _ = try waitForExit(pid: pid)
    }

    /// Nothing of the command runs before `resume`, which is what lets the
    /// supervisor hand over the terminal and print its start line first.
    func testChildStartsSuspended() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("guaranate-suspended-\(getpid())")
        try? FileManager.default.removeItem(at: marker)
        defer { try? FileManager.default.removeItem(at: marker) }

        let pid = try child.launch(
            CommandInvocation(argv: ["/bin/sh", "-c", "echo ran > \(marker.path)"]),
            resettingSignals: []
        )
        usleep(200_000)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "the command ran before it was resumed"
        )

        child.resume(pid)
        XCTAssertEqual(try waitForExit(pid: pid), .exited(code: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    /// A forwarded signal has to reach the command's own children too: signalling
    /// the command alone would kill the shell and leave its work running while
    /// the supervisor exits and the machine is allowed to sleep again.
    func testSignallingTheGroupReachesTheCommandsChildren() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("guaranate-grandchild-\(getpid())")
        try? FileManager.default.removeItem(at: pidFile)
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let pid = try start(["/bin/sh", "-c", "sleep 30 & echo $! > \(pidFile.path); wait"])

        var grandchild: pid_t = 0
        XCTAssertTrue(
            waitUntil {
                guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
                    let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
                else { return false }
                grandchild = value
                return true
            },
            "the command never reported its child's pid"
        )

        child.send(SIGTERM, toProcessGroup: pid)
        XCTAssertEqual(try waitForExit(pid: pid), .signalled(signal: SIGTERM))
        XCTAssertTrue(
            waitUntil { kill(grandchild, 0) != 0 && errno == ESRCH },
            "the command's child \(grandchild) outlived the signalled group"
        )
    }

    /// Ctrl+Z has to be distinguishable from an ending: the command still exists,
    /// still owns the terminal, and still needs the machine kept awake.
    func testWaitReportsAStopSeparatelyFromAnEnd() throws {
        let pid = try start(["/bin/sleep", "30"])

        child.send(SIGSTOP, toProcessGroup: pid)
        XCTAssertTrue(
            waitUntil { child.wait(pid) == .stopped(signal: SIGSTOP) },
            "a stopped command was not reported as stopped"
        )

        child.send(SIGCONT, toProcessGroup: pid)
        child.send(SIGTERM, toProcessGroup: pid)
        XCTAssertEqual(try waitForExit(pid: pid), .signalled(signal: SIGTERM))
    }

    /// A pid this process is not the parent of yields no status at all. The
    /// supervisor turns that into a failure rather than a fabricated exit 0.
    func testWaitReportsUnavailableWhenThereIsNothingToWaitFor() {
        XCTAssertEqual(child.wait(999_999), .unavailable)
    }
}
