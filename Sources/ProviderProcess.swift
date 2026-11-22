import Darwin
import Foundation

/// Own a separate group for each stdio request. Keeping the direct child waitable until
/// teardown reserves its PID, even if a wrapper exits before the worker closes our pipe.
struct ProviderProcess {
    private let pid: pid_t

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL, input: Pipe, output: Pipe)
        throws
    {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        try Self.check(posix_spawnattr_setpgroup(&attributes, 0))
        var mask = sigset_t()
        sigemptyset(&mask)
        try Self.check(posix_spawnattr_setsigmask(&attributes, &mask))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGPIPE, SIGINT, SIGHUP, SIGQUIT] { sigaddset(&defaults, signal) }
        try Self.check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        try Self.check(posix_spawnattr_setflags(&attributes, Int16(bitPattern: UInt16(flags))))
        try Self.check(
            posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO))
        try Self.check(
            posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
        try Self.check(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))
        if #available(macOS 26.0, *) {
            try Self.check(posix_spawn_file_actions_addchdir(&actions, directory.path))
        } else {
            try Self.check(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        }
        var child = pid_t(0)
        try Self.withStrings([executable.path] + arguments) { argv in
            try Self.withStrings(environment.map { $0.key + "=" + $0.value }) { envp in
                try Self.check(posix_spawn(&child, executable.path, &actions, &attributes, argv, envp))
            }
        }
        pid = child
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }

    private static func check(_ code: Int32) throws {
        guard code == 0 else { throw POSIXError(.init(rawValue: code) ?? .EIO) }
    }

    private static func withStrings<T>(
        _ values: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) throws -> T {
        var pointers = values.map { strdup($0) }
        defer { for pointer in pointers { free(pointer) } }
        guard !pointers.contains(where: { $0 == nil }) else { throw POSIXError(.ENOMEM) }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
    }

    private enum ChildState { case running, exited, unavailable }

    private func state() -> ChildState {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 {
            if errno != EINTR { return .unavailable }
        }
        return info.si_pid == pid ? .exited : .running
    }

    private func waitForExit(milliseconds: Int) -> ChildState {
        let end = DispatchTime.now() + .milliseconds(milliseconds)
        var current = state()
        while current == .running && DispatchTime.now() < end {
            usleep(10_000)
            current = state()
        }
        return current
    }

    func finish(graceMilliseconds: Int) {
        let current = waitForExit(milliseconds: graceMilliseconds)
        guard current != .unavailable else { return }
        // This group was created by posix_spawn. We have not reaped its leader,
        // so its numeric ID cannot be reused for an unrelated process group.
        _ = kill(-pid, SIGTERM)
        if current == .running { _ = waitForExit(milliseconds: 250) }
        if state() != .unavailable {
            _ = kill(-pid, SIGKILL)
            // A wrapper can also elect to leave the initial group itself.
            if state() == .running { _ = kill(pid, SIGKILL) }
        }
        if waitForExit(milliseconds: 250) == .running {
            let child = pid
            DispatchQueue.global(qos: .utility).async { Self.reap(child) }
        } else {
            Self.reap(pid)
        }
    }

    private static func reap(_ pid: pid_t) {
        var result: pid_t
        repeat { result = waitpid(pid, nil, 0) } while result < 0 && errno == EINTR
    }
}
