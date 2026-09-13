import Darwin
import Foundation

/// Failures while starting the helper that wakes a stopped process supervisor.
public enum ExitWakeupGuardianError: Error, Equatable, CustomStringConvertible {
    case cannotCreatePipe(code: Int32)
    case cannotConfigureSpawn(code: Int32)
    case cannotSpawn(code: Int32)
    case registrationFailed(code: Int32)
    case readinessLost

    public var description: String {
        switch self {
        case .cannotCreatePipe(let code):
            return "Cannot create exit-wakeup guardian pipe: \(String(cString: strerror(code)))"
        case .cannotConfigureSpawn(let code):
            return "Cannot configure exit-wakeup guardian: \(String(cString: strerror(code)))"
        case .cannotSpawn(let code):
            return "Cannot start exit-wakeup guardian: \(String(cString: strerror(code)))"
        case .registrationFailed(let code):
            return "Cannot register exit-wakeup guardian: \(String(cString: strerror(code)))"
        case .readinessLost:
            return "Exit-wakeup guardian ended before confirming registration"
        }
    }
}

/// A registered helper that can be cancelled and reaped without signalling a pid.
public protocol ExitWakeupGuardian: AnyObject {
    /// Cancels the helper through its private pipe and waits for it to exit.
    func cancelAndWait()
}

/// Starting a helper that wakes a stopped supervisor when its command exits.
public protocol ExitWakeupGuarding: Sendable {
    /// Starts the helper and returns only after all kernel registrations are live.
    func start(commandPID: pid_t, supervisorPID: pid_t) throws -> any ExitWakeupGuardian
}

/// `posix_spawn`-backed exit-wakeup guardian.
///
/// The same executable is launched in a hidden internal mode. Only readiness and
/// cancellation pipe ends survive the exec; standard streams point at `/dev/null`,
/// so this helper cannot keep a caller's pipes or terminal open.
public struct PosixSpawnExitWakeupGuardian: ExitWakeupGuarding {
    private static let mode = "_exit-wakeup-guardian"
    private let executablePath: String

    public init(executablePath: String) {
        self.executablePath = executablePath
    }

    public func start(commandPID: pid_t, supervisorPID: pid_t) throws -> any ExitWakeupGuardian {
        let readiness = try Self.makePipe()
        var readinessOwned = readiness
        defer {
            if readinessOwned.0 >= 0 { close(readinessOwned.0) }
            if readinessOwned.1 >= 0 { close(readinessOwned.1) }
        }

        let cancellation = try Self.makePipe()
        var cancellationOwned = cancellation
        defer {
            if cancellationOwned.0 >= 0 { close(cancellationOwned.0) }
            if cancellationOwned.1 >= 0 { close(cancellationOwned.1) }
        }

        var actions: posix_spawn_file_actions_t?
        var code = posix_spawn_file_actions_init(&actions)
        guard code == 0 else { throw ExitWakeupGuardianError.cannotConfigureSpawn(code: code) }
        defer { posix_spawn_file_actions_destroy(&actions) }

        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            code = posix_spawn_file_actions_addopen(
                &actions,
                descriptor,
                "/dev/null",
                descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY,
                0
            )
            guard code == 0 else {
                throw ExitWakeupGuardianError.cannotConfigureSpawn(code: code)
            }
        }
        for descriptor in [readiness.1, cancellation.0] {
            code = posix_spawn_file_actions_addinherit_np(&actions, descriptor)
            guard code == 0 else {
                throw ExitWakeupGuardianError.cannotConfigureSpawn(code: code)
            }
        }

        var attributes: posix_spawnattr_t?
        code = posix_spawnattr_init(&attributes)
        guard code == 0 else { throw ExitWakeupGuardianError.cannotConfigureSpawn(code: code) }
        defer { posix_spawnattr_destroy(&attributes) }

        code = posix_spawnattr_setpgroup(&attributes, 0)
        guard code == 0 else { throw ExitWakeupGuardianError.cannotConfigureSpawn(code: code) }
        code = posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
        )
        guard code == 0 else { throw ExitWakeupGuardianError.cannotConfigureSpawn(code: code) }

        let argv = [
            executablePath,
            Self.mode,
            "\(supervisorPID)",
            "\(commandPID)",
            "\(readiness.1)",
            "\(cancellation.0)",
        ]
        var guardianPID = pid_t()
        code = withCStrings(argv) { pointers in
            posix_spawn(&guardianPID, executablePath, &actions, &attributes, pointers, environ)
        }
        guard code == 0 else { throw ExitWakeupGuardianError.cannotSpawn(code: code) }

        close(readinessOwned.1)
        readinessOwned.1 = -1
        close(cancellationOwned.0)
        cancellationOwned.0 = -1

        var readinessCode: Int32 = 0
        let bytesRead = withUnsafeMutableBytes(of: &readinessCode) { buffer in
            Self.readFully(readiness.0, into: buffer)
        }
        close(readinessOwned.0)
        readinessOwned.0 = -1

        guard bytesRead == MemoryLayout<Int32>.size else {
            close(cancellationOwned.1)
            cancellationOwned.1 = -1
            Self.waitForChild(guardianPID)
            throw ExitWakeupGuardianError.readinessLost
        }
        guard readinessCode == 0 else {
            close(cancellationOwned.1)
            cancellationOwned.1 = -1
            Self.waitForChild(guardianPID)
            throw ExitWakeupGuardianError.registrationFailed(code: readinessCode)
        }

        let handle = SpawnedExitWakeupGuardian(
            pid: guardianPID,
            cancellationDescriptor: cancellationOwned.1
        )
        cancellationOwned.1 = -1
        return handle
    }

    private static func makePipe() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw ExitWakeupGuardianError.cannotCreatePipe(code: errno)
        }

        var result = (descriptors[0], descriptors[1])
        do {
            result.0 = try moveAboveStandardStreams(result.0)
            result.1 = try moveAboveStandardStreams(result.1)
            return result
        } catch {
            close(result.0)
            close(result.1)
            throw error
        }
    }

    private static func moveAboveStandardStreams(_ descriptor: Int32) throws -> Int32 {
        guard descriptor <= STDERR_FILENO else { return descriptor }
        let replacement = fcntl(descriptor, F_DUPFD, STDERR_FILENO + 1)
        guard replacement >= 0 else {
            throw ExitWakeupGuardianError.cannotCreatePipe(code: errno)
        }
        close(descriptor)
        return replacement
    }

    private static func readFully(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) -> Int {
        var offset = 0
        while offset < buffer.count {
            let count = read(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
            if count > 0 {
                offset += count
            } else if count == 0 {
                break
            } else if errno != EINTR {
                break
            }
        }
        return offset
    }

    fileprivate static func waitForChild(_ pid: pid_t) {
        var discarded: Int32 = 0
        while waitpid(pid, &discarded, 0) == -1 && errno == EINTR {}
    }

    private func withCStrings<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}

/// The hidden mode's kqueue loop. Public only so the CLI entrypoint can invoke it.
public enum ExitWakeupGuardianMode {
    /// Registers both processes, confirms readiness, then waits for cancellation or
    /// for the command to exit while the supervisor has received `SIGSTOP`.
    public static func run(
        supervisorPID: pid_t,
        commandPID: pid_t,
        readinessDescriptor: Int32,
        cancellationDescriptor: Int32
    ) -> Int32 {
        run(
            supervisorPID: supervisorPID,
            commandPID: commandPID,
            readinessDescriptor: readinessDescriptor,
            cancellationDescriptor: cancellationDescriptor,
            requireParentIdentity: true
        )
    }

    static func run(
        supervisorPID: pid_t,
        commandPID: pid_t,
        readinessDescriptor: Int32,
        cancellationDescriptor: Int32,
        requireParentIdentity: Bool
    ) -> Int32 {
        defer { close(readinessDescriptor) }
        let queue = kqueue()
        guard queue >= 0 else {
            reportReadiness(errno, to: readinessDescriptor)
            return 1
        }
        defer { close(queue) }

        let registrations = [
            Darwin.kevent(
                ident: UInt(commandPID),
                filter: Int16(EVFILT_PROC),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
                fflags: NOTE_EXIT,
                data: 0,
                udata: nil
            ),
            Darwin.kevent(
                ident: UInt(supervisorPID),
                filter: Int16(EVFILT_PROC),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
                fflags: NOTE_EXIT | UInt32(NOTE_SIGNAL),
                data: 0,
                udata: nil
            ),
            Darwin.kevent(
                ident: UInt(cancellationDescriptor),
                filter: Int16(EVFILT_READ),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
                fflags: 0,
                data: 0,
                udata: nil
            ),
        ]

        for var registration in registrations {
            guard kevent(queue, &registration, 1, nil, 0, nil) != -1 else {
                reportReadiness(errno, to: readinessDescriptor)
                return 1
            }
        }
        var commandExited = false
        var supervisorSignalled = processState(supervisorPID) == .stopped
        reportReadiness(0, to: readinessDescriptor)
        var events = [Darwin.kevent](repeating: Darwin.kevent(), count: 3)
        while true {
            let count = kevent(queue, nil, 0, &events, Int32(events.count), nil)
            if count < 0 {
                if errno == EINTR { continue }
                return 1
            }

            for event in events.prefix(Int(count)) {
                if event.filter == Int16(EVFILT_READ), event.ident == UInt(cancellationDescriptor) {
                    return 0
                }
                guard event.filter == Int16(EVFILT_PROC) else { continue }
                if event.ident == UInt(commandPID), event.fflags & NOTE_EXIT != 0 {
                    commandExited = true
                }
                if event.ident == UInt(supervisorPID) {
                    if event.fflags & NOTE_EXIT != 0 { return 0 }
                    if event.fflags & UInt32(NOTE_SIGNAL) != 0 {
                        supervisorSignalled = true
                    }
                }
            }

            if commandExited, supervisorSignalled,
                waitUntilStopped(supervisorPID, cancellationDescriptor: cancellationDescriptor)
            {
                // This executable was spawned directly by the supervisor. If it is
                // no longer our parent, its pid is no longer safe to address.
                guard !requireParentIdentity || getppid() == supervisorPID else { return 0 }
                _ = kill(supervisorPID, SIGCONT)
                return 0
            }
        }
    }

    /// `NOTE_SIGNAL` reports that a signal was sent, but not which one in the
    /// returned event. Confirm the supervisor's kernel state so an unrelated
    /// signal cannot be mistaken for the `SIGSTOP` this helper exists to pair with.
    private static func waitUntilStopped(
        _ pid: pid_t,
        cancellationDescriptor: Int32
    ) -> Bool {
        while true {
            switch processState(pid) {
            case .stopped:
                return true
            case .gone:
                return false
            case .running:
                var cancellation = pollfd(
                    fd: cancellationDescriptor,
                    events: Int16(POLLIN),
                    revents: 0
                )
                let result = poll(&cancellation, 1, 1)
                if result > 0 { return false }
                if result < 0, errno != EINTR { return false }
            }
        }
    }

    private static func processState(_ pid: pid_t) -> GuardedProcessState {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
            return errno == ESRCH ? .gone : .running
        }
        guard size > 0 else {
            return .gone
        }
        switch Int32(info.kp_proc.p_stat) {
        case SSTOP: return .stopped
        case SZOMB: return .gone
        default: return .running
        }
    }

    private static func reportReadiness(_ code: Int32, to descriptor: Int32) {
        var code = code
        withUnsafeBytes(of: &code) { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}

private enum GuardedProcessState {
    case running
    case stopped
    case gone
}

private final class SpawnedExitWakeupGuardian: ExitWakeupGuardian {
    private var pid: pid_t?
    private var cancellationDescriptor: Int32?

    init(pid: pid_t, cancellationDescriptor: Int32) {
        self.pid = pid
        self.cancellationDescriptor = cancellationDescriptor
    }

    func cancelAndWait() {
        guard let pid else { return }
        self.pid = nil
        let descriptor = cancellationDescriptor
        cancellationDescriptor = nil

        // Closing is the cancellation message. No pid is signalled, so a helper
        // that raced to exit can never turn cancellation into a pid-reuse hazard.
        if let descriptor { close(descriptor) }
        PosixSpawnExitWakeupGuardian.waitForChild(pid)
    }

    deinit {
        cancelAndWait()
    }
}
