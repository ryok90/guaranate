import Darwin
import XCTest

@testable import GuaranateCore

/// Exercises the guardian's real kqueue registrations against short-lived helpers.
final class ExitWakeupGuardianTests: XCTestCase {
    private let child = ChildProcess()

    func testWakesSupervisorWhenCommandExitArrivesBeforeItsStop() throws {
        let supervisorPID = try child.launch(
            CommandInvocation(argv: ["/bin/sleep", "30"]),
            resettingSignals: []
        )
        let commandPID = try child.launch(
            CommandInvocation(argv: ["/bin/sleep", "30"]),
            resettingSignals: []
        )
        defer {
            reap(supervisorPID)
            reap(commandPID)
        }
        child.resume(supervisorPID)
        child.resume(commandPID)

        var readiness: [Int32] = [0, 0]
        var cancellation: [Int32] = [0, 0]
        guard pipe(&readiness) == 0 else {
            return XCTFail("could not create readiness pipe")
        }
        guard pipe(&cancellation) == 0 else {
            close(readiness[0])
            close(readiness[1])
            return XCTFail("could not create cancellation pipe")
        }
        let readinessRead = readiness[0]
        let readinessWrite = readiness[1]
        let cancellationRead = cancellation[0]
        let cancellationWrite = cancellation[1]
        defer {
            close(readinessRead)
            close(cancellationWrite)
        }

        let finished = expectation(description: "guardian exited after waking the supervisor")
        Thread.detachNewThread {
            _ = ExitWakeupGuardianMode.run(
                supervisorPID: supervisorPID,
                commandPID: commandPID,
                readinessDescriptor: readinessWrite,
                cancellationDescriptor: cancellationRead,
                requireParentIdentity: false
            )
            close(cancellationRead)
            finished.fulfill()
        }

        var registrationCode: Int32 = -1
        let count = withUnsafeMutableBytes(of: &registrationCode) { buffer in
            read(readinessRead, buffer.baseAddress, buffer.count)
        }
        XCTAssertEqual(count, MemoryLayout<Int32>.size)
        XCTAssertEqual(registrationCode, 0, "guardian did not confirm both registrations")

        // Deliberately deliver exit first. The guardian must wait for the later
        // supervisor stop, then wake it; either event order has to close the race.
        child.send(SIGKILL, toProcessGroup: commandPID)
        usleep(100_000)
        XCTAssertEqual(kill(supervisorPID, SIGSTOP), 0)
        wait(for: [finished], timeout: 5)

        XCTAssertTrue(
            waitUntil { processState(supervisorPID) != SSTOP },
            "the guardian observed both events but left the supervisor stopped"
        )
    }

    func testWakesSupervisorThatStoppedBeforeRegistration() throws {
        let supervisorPID = try child.launch(
            CommandInvocation(argv: ["/bin/sleep", "30"]),
            resettingSignals: []
        )
        let commandPID = try child.launch(
            CommandInvocation(argv: ["/bin/sleep", "30"]),
            resettingSignals: []
        )
        defer {
            reap(supervisorPID)
            reap(commandPID)
        }
        child.resume(supervisorPID)
        child.resume(commandPID)
        XCTAssertEqual(kill(supervisorPID, SIGSTOP), 0)
        XCTAssertTrue(waitUntil { processState(supervisorPID) == SSTOP })

        var readiness: [Int32] = [0, 0]
        var cancellation: [Int32] = [0, 0]
        guard pipe(&readiness) == 0 else {
            return XCTFail("could not create readiness pipe")
        }
        guard pipe(&cancellation) == 0 else {
            close(readiness[0])
            close(readiness[1])
            return XCTFail("could not create cancellation pipe")
        }
        let readinessRead = readiness[0]
        let readinessWrite = readiness[1]
        let cancellationRead = cancellation[0]
        let cancellationWrite = cancellation[1]
        defer {
            close(readinessRead)
            close(cancellationWrite)
        }

        let finished = expectation(description: "guardian exited after waking the supervisor")
        Thread.detachNewThread {
            _ = ExitWakeupGuardianMode.run(
                supervisorPID: supervisorPID,
                commandPID: commandPID,
                readinessDescriptor: readinessWrite,
                cancellationDescriptor: cancellationRead,
                requireParentIdentity: false
            )
            close(cancellationRead)
            finished.fulfill()
        }

        var registrationCode: Int32 = -1
        let count = withUnsafeMutableBytes(of: &registrationCode) { buffer in
            read(readinessRead, buffer.baseAddress, buffer.count)
        }
        XCTAssertEqual(count, MemoryLayout<Int32>.size)
        XCTAssertEqual(registrationCode, 0, "guardian did not confirm both registrations")

        child.send(SIGKILL, toProcessGroup: commandPID)
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(
            waitUntil { processState(supervisorPID) != SSTOP },
            "the guardian missed the supervisor's pre-registration stop"
        )
    }

    private func reap(_ pid: pid_t) {
        _ = kill(pid, SIGCONT)
        _ = kill(pid, SIGKILL)
        var discarded: Int32 = 0
        while waitpid(pid, &discarded, 0) == -1 && errno == EINTR {}
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            usleep(5_000)
        }
        return false
    }

    private func processState(_ pid: pid_t) -> Int32 {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return SZOMB
        }
        return Int32(info.kp_proc.p_stat)
    }
}
