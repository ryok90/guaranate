import XCTest

@testable import GuaranateCore

final class ProcessIdentityTests: XCTestCase {
    func testSameProcessComparesPIDAndStartTime() {
        let original = ProcessIdentity(pid: 42, startedAt: 1_000.5, name: "node")
        let recycled = ProcessIdentity(pid: 42, startedAt: 2_000.5, name: "node")
        let other = ProcessIdentity(pid: 43, startedAt: 1_000.5, name: "node")

        XCTAssertTrue(original.isSameProcess(as: original))
        XCTAssertFalse(original.isSameProcess(as: recycled), "a recycled pid is a different process")
        XCTAssertFalse(original.isSameProcess(as: other))
    }

    /// A process keeps its identity across `exec`, which replaces `p_comm`.
    func testSameProcessIgnoresName() {
        let before = ProcessIdentity(pid: 42, startedAt: 1_000.5, name: "sh")
        let after = ProcessIdentity(pid: 42, startedAt: 1_000.5, name: "node")
        XCTAssertTrue(before.isSameProcess(as: after))
    }

    func testDisplayNameIncludesNameWhenKnown() {
        XCTAssertEqual(ProcessIdentity(pid: 42, startedAt: 0, name: "node").displayName, "42 (node)")
        XCTAssertEqual(ProcessIdentity(pid: 42, startedAt: 0, name: nil).displayName, "42")
        XCTAssertEqual(ProcessIdentity(pid: 42, startedAt: 0, name: "").displayName, "42")
    }
}

final class SystemProcessInspectorTests: XCTestCase {
    private let inspector = SystemProcessInspector()

    /// Reads a real process (this test runner's parent) to prove the `sysctl`
    /// decoding produces a usable name and a plausible start time.
    func testResolvesALiveProcess() throws {
        let identity = try inspector.identity(of: getppid())
        XCTAssertEqual(identity.pid, getppid())
        XCTAssertNotNil(identity.name)
        XCTAssertGreaterThan(identity.startedAt, 0)
        XCTAssertLessThanOrEqual(identity.startedAt, Date().timeIntervalSince1970)
    }

    func testRejectsUnusedPID() {
        // Above the kernel's pid ceiling, so it can never be in use.
        XCTAssertThrowsError(try inspector.identity(of: 999_999)) { error in
            XCTAssertEqual(error as? ProcessLookupError, .noSuchProcess(999_999))
        }
    }

    /// `kill(0, 0)` addresses the whole process group and negative pids address
    /// groups too, so these must be rejected before any signal is sent.
    func testRejectsNonPositivePIDs() {
        XCTAssertThrowsError(try inspector.identity(of: 0)) { error in
            XCTAssertEqual(error as? ProcessLookupError, .invalidPID(0))
        }
        XCTAssertThrowsError(try inspector.identity(of: -1)) { error in
            XCTAssertEqual(error as? ProcessLookupError, .invalidPID(-1))
        }
    }

    /// Watching ourselves would hold the assertion until we exit, which never
    /// happens while we are waiting for ourselves.
    func testRejectsOwnPID() {
        XCTAssertThrowsError(try inspector.identity(of: getpid())) { error in
            XCTAssertEqual(error as? ProcessLookupError, .wouldWatchItself(getpid()))
        }
    }

    /// A zombie still answers `kill(pid, 0)`, so an existence check alone accepts
    /// it — and watching one would hold the assertion for work that already
    /// finished, until its parent happened to reap it.
    func testRejectsAZombie() throws {
        let child = ChildProcess()
        let pid = try child.launch(CommandInvocation(argv: ["/bin/sh", "-c", "exit 0"]), resettingSignals: [])
        child.resume(pid)
        defer { var ignored: Int32 = 0; waitpid(pid, &ignored, 0) }

        // Deliberately unreaped: poll until the kernel reports it as a zombie.
        var isZombie = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !isZombie {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            if sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 {
                isZombie = Int32(info.kp_proc.p_stat) == SZOMB
            }
            if !isZombie { usleep(5_000) }
        }
        try XCTSkipUnless(isZombie, "could not observe \(pid) as a zombie")

        XCTAssertEqual(kill(pid, 0), 0, "a zombie still exists as far as kill(2) is concerned")
        XCTAssertThrowsError(try inspector.identity(of: pid)) { error in
            XCTAssertEqual(error as? ProcessLookupError, .noSuchProcess(pid))
        }
    }
}
