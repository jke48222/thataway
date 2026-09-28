import Darwin
import Foundation

/// A child process that does not act with the coach's privacy grants.
///
/// A process started with `Process` (or plain `posix_spawn`) inherits the
/// coach as its TCC "responsible process". Whatever it runs could then capture
/// the screen, read every app's accessibility tree and open the microphone
/// under Screen Coach's Accessibility, Screen Recording and Microphone grants,
/// with no prompt. The vision sidecar needs none of them: it reads a frame the
/// coach already captured and writes a line of JSON. So it is spawned with
/// responsibility disclaimed, as Chromium, LLDB and VS Code do for their
/// helpers, and would have to ask for any grant in its own name.
///
/// The spawn also passes only the file descriptors it names (stdin, stdout,
/// stderr), resets signal dispositions and the signal mask, and takes an
/// explicit environment rather than the coach's.
final class SidecarProcess {

    enum SpawnError: Error, CustomStringConvertible {
        case disclaimUnavailable
        case pipe(Int32)
        case spawn(Int32)

        var description: String {
            switch self {
            case .disclaimUnavailable:
                return "this macOS cannot start a helper without the coach's permissions"
            case .pipe(let e): return "pipe failed: \(String(cString: strerror(e)))"
            case .spawn(let e): return String(cString: strerror(e))
            }
        }
    }

    let pid: pid_t
    /// Parent ends. Owned here and closed by `closeAll()` or on deinit.
    private(set) var stdinFD: Int32
    private(set) var stdoutFD: Int32
    private(set) var stderrFD: Int32

    private let lock = NSLock()
    private var exitStatus: Int32?

    private init(pid: pid_t, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32) {
        self.pid = pid
        self.stdinFD = stdinFD
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
    }

    deinit { closeAll() }

    // MARK: - Responsibility

    private typealias SetDisclaim = @convention(c) (
        UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    /// `responsibility_spawnattrs_setdisclaim`, present since macOS 10.14 but
    /// not in the SDK headers, so it is looked up rather than linked.
    private static let setDisclaim: SetDisclaim? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),   // RTLD_DEFAULT
                              "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(sym, to: SetDisclaim.self)
    }()

    /// Which process TCC holds responsible for `pid`, when the system will
    /// say. For tests: a disclaimed child is responsible for itself.
    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "responsibility_get_pid_responsible_for_pid") else { return nil }
        let r = unsafeBitCast(sym, to: ResponsiblePID.self)(pid)
        return r > 0 ? r : nil
    }

    // MARK: - Environment

    /// The environment a helper gets: enough to find the home folder and the
    /// private temporary directory, and nothing that changes what Python
    /// loads (`PYTHONPATH`, `PYTHONHOME`, `PYTHONSTARTUP`, `DYLD_*` and the
    /// rest of the coach's environment are left behind).
    static func minimalEnvironment(from env: [String: String],
                                   adding extra: [String: String] = [:]) -> [String: String] {
        var out: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"] {
            if let v = env[key], !v.isEmpty { out[key] = v }
        }
        return out.merging(extra) { $1 }
    }

    // MARK: - Spawning

    /// Starts `executable` with `arguments` (not including argv[0]).
    ///
    /// Fails closed: if responsibility cannot be disclaimed, nothing is
    /// started, because the alternative is a helper holding the coach's
    /// screen, accessibility and microphone grants.
    static func spawn(executable: String, arguments: [String],
                      environment: [String: String]) throws -> SidecarProcess {
        guard let setDisclaim else { throw SpawnError.disclaimUnavailable }

        var inFDs: [Int32] = [-1, -1], outFDs: [Int32] = [-1, -1], errFDs: [Int32] = [-1, -1]
        func closeAllPipes() {
            for fd in inFDs + outFDs + errFDs where fd >= 0 { close(fd) }
        }
        guard pipe(&inFDs) == 0 else { throw SpawnError.pipe(errno) }
        guard pipe(&outFDs) == 0 else { let e = errno; closeAllPipes(); throw SpawnError.pipe(e) }
        guard pipe(&errFDs) == 0 else { let e = errno; closeAllPipes(); throw SpawnError.pipe(e) }
        // The parent's ends must not leak into anything else this process
        // starts, and the write end must report EPIPE rather than raise
        // SIGPIPE, whose default action would terminate the whole app.
        for fd in [inFDs[1], outFDs[0], errFDs[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(inFDs[1], F_SETNOSIGPIPE, 1)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        // Only the three descriptors named below reach the child.
        let flags = Int32(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                          | POSIX_SPAWN_SETSIGMASK)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setflags(&attr, Int16(truncatingIfNeeded: flags))
        guard setDisclaim(&attr, 1) == 0 else {
            closeAllPipes()
            throw SpawnError.disclaimUnavailable
        }

        posix_spawn_file_actions_adddup2(&actions, inFDs[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outFDs[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errFDs[1], STDERR_FILENO)

        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
        defer {
            for p in cArgs { free(p) }
            for p in cEnv { free(p) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, &cArgs, &cEnv)
        // The child's ends belong to the child now (or to nobody).
        close(inFDs[0]); close(outFDs[1]); close(errFDs[1])
        guard rc == 0 else {
            close(inFDs[1]); close(outFDs[0]); close(errFDs[0])
            throw SpawnError.spawn(rc)
        }
        return SidecarProcess(pid: pid, stdinFD: inFDs[1], stdoutFD: outFDs[0],
                              stderrFD: errFDs[0])
    }

    // MARK: - Lifetime

    /// Whether the child is still running. Reaps it the first time it is
    /// seen to have exited, so no zombie is left behind.
    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        guard exitStatus == nil else { return false }
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        if r == 0 { return true }
        if r == pid {
            exitStatus = status
        } else if r < 0 && errno != EINTR {
            exitStatus = -1   // already reaped, or not our child
        } else {
            return true
        }
        return false
    }

    /// The exit code once the child has exited, or nil after `timeout`.
    func waitForExit(timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning {
            if Date() >= deadline { return nil }
            usleep(10_000)
        }
        lock.lock(); defer { lock.unlock() }
        guard let s = exitStatus, s >= 0 else { return nil }
        // WIFEXITED / WEXITSTATUS, which Swift cannot import as macros.
        return (s & 0x7f) == 0 ? (s >> 8) & 0xff : nil
    }

    func signal(_ sig: Int32) {
        guard isRunning else { return }
        kill(pid, sig)
    }

    /// SIGTERM now, SIGKILL after `grace` if it is still running (a process
    /// stuck inside a GPU call may ignore SIGTERM), and reaped either way.
    func terminate(grace: TimeInterval = 2) {
        guard isRunning else { return }
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            if self.isRunning { kill(self.pid, SIGKILL) }
            _ = self.waitForExit(timeout: 5)
        }
    }

    func closeStdin() {
        lock.lock(); let fd = stdinFD; stdinFD = -1; lock.unlock()
        if fd >= 0 { close(fd) }
    }

    func closeAll() {
        lock.lock()
        let fds = [stdinFD, stdoutFD, stderrFD]
        stdinFD = -1; stdoutFD = -1; stderrFD = -1
        lock.unlock()
        for fd in fds where fd >= 0 { close(fd) }
    }

    // MARK: - Writing with a deadline

    enum WriteOutcome: Equatable { case written, timedOut, closed }

    /// Writes all of `data` to the child's stdin, giving up at `deadline`.
    ///
    /// A request can carry a whole encoded frame, far larger than a pipe's
    /// buffer, so a sidecar that has stopped reading must cost a timeout
    /// rather than block the caller for ever.
    func writeToStdin(_ data: Data, deadline: Date) -> WriteOutcome {
        lock.lock(); let fd = stdinFD; lock.unlock()
        guard fd >= 0 else { return .closed }
        let old = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, old | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, old) }

        return data.withUnsafeBytes { raw -> WriteOutcome in
            guard let base = raw.baseAddress else { return .written }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno != EAGAIN { return .closed }   // EPIPE: it is gone
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return .timedOut }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ms = Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up))
                let ready = poll(&pfd, 1, max(ms, 1))
                if ready == 0 { return .timedOut }
                if ready < 0 && errno != EINTR { return .closed }
                if pfd.revents & Int16(POLLERR | POLLHUP) != 0 { return .closed }
            }
            return .written
        }
    }
}
