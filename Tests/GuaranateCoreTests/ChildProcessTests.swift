import XCTest

@testable import GuaranateCore

/// Exercises the real `posix_spawnp` path. Spawning short-lived helpers is safe
/// here — unlike the power assertions, it does not touch host state.
final class ChildProcessTests: XCTestCase {
    private let child = ChildProcess()

    /// `reap` is non-blocking by design (it runs inside a dispatch exit handler),
    /// so tests poll it.
    private func waitForExit(
        pid: pid_t,
        timeout: TimeInterval = 10
    ) throws -> ExitStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = child.reap(pid) { return status }
            usleep(2_000)
        }
        throw XCTSkip("child \(pid) did not exit within \(timeout)s")
    }

    func testPropagatesChildExitCode() throws {
        let pid = try child.launch(
            CommandInvocation(argv: ["/bin/sh", "-c", "exit 7"]),
            resettingSignals: []
        )
        XCTAssertEqual(try waitForExit(pid: pid), .exited(code: 7))
    }

    func testReportsSignalDeath() throws {
        let pid = try child.launch(
            CommandInvocation(argv: ["/bin/sh", "-c", "kill -TERM $$"]),
            resettingSignals: []
        )
        XCTAssertEqual(try waitForExit(pid: pid), .signalled(signal: SIGTERM))
    }

    /// Resolving through `PATH` is what makes `guaranate while npm test` work
    /// without an absolute path.
    func testResolvesExecutableThroughPATH() throws {
        let pid = try child.launch(
            CommandInvocation(argv: ["true"]),
            resettingSignals: []
        )
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

        let ignored = try child.launch(
            CommandInvocation(argv: ["/bin/sh", "-c", "kill -INT $$; exit 0"]),
            resettingSignals: []
        )
        XCTAssertEqual(
            try waitForExit(pid: ignored),
            .exited(code: 0),
            "without a reset the child inherits SIG_IGN and survives its own SIGINT"
        )

        let reset = try child.launch(
            CommandInvocation(argv: ["/bin/sh", "-c", "kill -INT $$; exit 0"]),
            resettingSignals: [SIGINT]
        )
        XCTAssertEqual(
            try waitForExit(pid: reset),
            .signalled(signal: SIGINT),
            "with the reset the child dies from SIGINT as it would if run directly"
        )
    }

    /// Omitting `POSIX_SPAWN_SETPGROUP` keeps the child in the terminal's
    /// foreground process group, which is how Ctrl+C reaches it at all.
    func testChildInheritsOurProcessGroup() throws {
        let pid = try child.launch(
            CommandInvocation(argv: ["/bin/sh", "-c", "exit 0"]),
            resettingSignals: []
        )
        // Read the group before reaping, while the pid is still valid.
        let group = getpgid(pid)
        XCTAssertEqual(group, getpgrp())
        _ = try waitForExit(pid: pid)
    }
}
