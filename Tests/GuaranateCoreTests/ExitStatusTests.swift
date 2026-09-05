import XCTest

@testable import GuaranateCore

final class ExitStatusTests: XCTestCase {
    /// Builds a raw wait status the way the kernel does: `W_EXITCODE(code, signal)`.
    private func rawStatus(code: Int32 = 0, signal: Int32 = 0) -> Int32 {
        (code << 8) | signal
    }

    func testDecodesNormalExit() {
        XCTAssertEqual(ExitStatus(rawWaitStatus: rawStatus(code: 0)), .exited(code: 0))
        XCTAssertEqual(ExitStatus(rawWaitStatus: rawStatus(code: 7)), .exited(code: 7))
        XCTAssertEqual(ExitStatus(rawWaitStatus: rawStatus(code: 255)), .exited(code: 255))
    }

    func testDecodesSignalDeath() {
        XCTAssertEqual(ExitStatus(rawWaitStatus: rawStatus(signal: SIGTERM)), .signalled(signal: SIGTERM))
        XCTAssertEqual(ExitStatus(rawWaitStatus: rawStatus(signal: SIGKILL)), .signalled(signal: SIGKILL))
    }

    /// `exit(9)` and death by `SIGKILL` (9) must not decode to the same thing —
    /// this is precisely the distinction Foundation's `Process` loses.
    func testExitCodeNineIsNotSignalNine() {
        XCTAssertEqual(ExitStatus(rawWaitStatus: rawStatus(code: 9)), .exited(code: 9))
        XCTAssertEqual(ExitStatus(rawWaitStatus: rawStatus(signal: 9)), .signalled(signal: 9))
        XCTAssertEqual(ExitStatus.exited(code: 9).exitCode, 9)
        XCTAssertEqual(ExitStatus.signalled(signal: 9).exitCode, 137)
    }

    func testSignalDeathPropagatesAs128PlusSignal() {
        XCTAssertEqual(ExitStatus.signalled(signal: SIGINT).exitCode, 130)
        XCTAssertEqual(ExitStatus.signalled(signal: SIGTERM).exitCode, 143)
        XCTAssertEqual(ExitStatus.signalled(signal: SIGHUP).exitCode, 129)
    }

    func testNormalExitPropagatesItsOwnCode() {
        XCTAssertEqual(ExitStatus.exited(code: 0).exitCode, 0)
        XCTAssertEqual(ExitStatus.exited(code: 7).exitCode, 7)
    }

    func testOnlyZeroExitIsSuccess() {
        XCTAssertTrue(ExitStatus.exited(code: 0).isSuccess)
        XCTAssertFalse(ExitStatus.exited(code: 1).isSuccess)
        XCTAssertFalse(ExitStatus.signalled(signal: SIGINT).isSuccess)
    }

    func testSummaryReadsAsPlainLanguage() {
        XCTAssertEqual(ExitStatus.exited(code: 0).summary, "finished")
        XCTAssertEqual(ExitStatus.exited(code: 7).summary, "exited 7")
        XCTAssertEqual(ExitStatus.signalled(signal: SIGINT).summary, "interrupted")
        XCTAssertEqual(ExitStatus.signalled(signal: SIGTERM).summary, "killed by SIGTERM")
        XCTAssertEqual(ExitStatus.signalled(signal: 99).summary, "killed by signal 99")
    }
}
