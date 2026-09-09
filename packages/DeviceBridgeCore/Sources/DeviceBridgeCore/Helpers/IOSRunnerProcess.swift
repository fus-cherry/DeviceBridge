import Foundation
import Darwin

/// Owns one Xcode child process group. It never searches for or terminates unrelated processes.
/// TERM grace lasts only while the group leader is alive. Leader exit immediately triggers cleanup
/// of remaining group members before reaping; descendants are not promised their own flush window.
/// Signal deadlines are bounded, but kernel-stalled exit/reaping and parent death are not guaranteed.
public actor IOSRunnerProcess {
    public enum Exit: Sendable, Equatable {
        case exited(Int32), signaled(Int32), observationFailed
        public var code: Int32? { if case let .exited(value) = self { value } else { nil } }
        public var signal: Int32? { if case let .signaled(value) = self { value } else { nil } }
    }

    private let pid: pid_t
    private let deadline: ContinuousClock.Instant
    private let terminationGrace: Duration
    private var killDeadline: ContinuousClock.Instant?
    private var sentKill = false
    private var exit: Exit?
    private var waiters: [CheckedContinuation<Exit, Never>] = []

    private init(pid: pid_t, lifetime: Duration, terminationGrace: Duration) {
        self.pid = pid
        self.deadline = ContinuousClock.now.advanced(by: lifetime)
        self.terminationGrace = terminationGrace
    }

    public static func start(executableURL: URL, arguments: [String], environment: [String: String],
                             lifetime: Duration, terminationGrace: Duration = .seconds(2)) throws -> IOSRunnerProcess {
        try Task.checkCancellation()
        guard executableURL.isFileURL, lifetime > .zero, terminationGrace > .zero else { throw Failure.launch }
        let values = [executableURL.path] + arguments
        let variables = environment.map { "\($0.key)=\($0.value)" }
        guard !(values + variables).contains(where: { $0.contains("\0") }),
              environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") }) else { throw Failure.launch }
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw Failure.launch }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure.launch }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
        var mask = sigset_t(); sigemptyset(&mask)
        var defaults = sigset_t(); sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGPIPE] { sigaddset(&defaults, signal) }
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0 else { throw Failure.launch }
        // No inherited streams, UI, or retained Xcode output. Caller owns any result-bundle policy.
        for descriptor: Int32 in [0, 1, 2] {
            guard posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0) == 0 else {
                throw Failure.launch
            }
        }
        var argv = values.map { strdup($0) } + [nil]
        var envp = variables.map { strdup($0) } + [nil]
        defer { for pointer in argv + envp { if let pointer { free(pointer) } } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else { throw Failure.launch }
        var pid: pid_t = 0
        let status = argv.withUnsafeMutableBufferPointer { arguments in
            envp.withUnsafeMutableBufferPointer { environment in
                posix_spawn(&pid, executableURL.path, &actions, &attributes, arguments.baseAddress!, environment.baseAddress!)
            }
        }
        guard status == 0, pid > 0 else { throw Failure.launch }
        let owner = IOSRunnerProcess(pid: pid, lifetime: lifetime, terminationGrace: terminationGrace)
        Task { await owner.monitor() }
        return owner
    }

    /// Observation does not transfer lifecycle ownership. Stop explicitly before abandoning a launch.
    public func waitForExit() async -> Exit {
        if let exit { return exit }
        return await withCheckedContinuation { waiters.append($0) }
    }

    public func exitStatus() -> Exit? { exit }

    public func stop() async {
        beginStop()
        _ = await waitForExit()
    }

    private func monitor() async {
        while exit == nil {
            if observeExit() { return }
            let now = ContinuousClock.now
            if now >= deadline { beginStop() }
            if let killDeadline, now >= killDeadline, !sentKill {
                sentKill = true
                kill(-pid, SIGKILL)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func beginStop() {
        guard exit == nil, killDeadline == nil else { return }
        if observeExit() { return }
        killDeadline = ContinuousClock.now.advanced(by: terminationGrace)
        kill(-pid, SIGTERM)
    }

    private func observeExit() -> Bool {
        var info = siginfo_t()
        // WNOWAIT keeps the leader's PID reserved until group cleanup has been signalled.
        // Reaping first could allow PID reuse before a delayed group kill.
        let status = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if status != 0 {
            if errno == EINTR { return false }
            publish(.observationFailed)
            return true
        }
        guard info.si_pid == pid else { return false }
        kill(-pid, SIGKILL)
        var waitStatus: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(pid, &waitStatus, 0) } while reaped == -1 && errno == EINTR
        guard reaped == pid else { publish(.observationFailed); return true }
        let signal = waitStatus & 0x7f
        publish(signal == 0 ? .exited((waitStatus >> 8) & 0xff) : .signaled(signal))
        return true
    }

    private func publish(_ value: Exit) {
        guard exit == nil else { return }
        exit = value
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: value) }
    }

    private enum Failure: Error { case launch }
}
