import CoreGraphics
import Darwin
import Foundation
import ImageIO
import ScreenCoachCore

/// Talks to the Holo1.5 sidecar.
///
/// Started lazily and never eagerly: the model costs ~5.6 GB resident, and on a
/// 24 GB machine that is not something to hold for a user whose apps all expose
/// good accessibility trees and who therefore never needs it. The first AX miss
/// pays the ~0.5 s load; everything after that is warm.
///
/// Failure here is expected and survivable. There may be no Python, no MLX, no
/// weights on disk. The coach must degrade to accessibility-only rather than
/// break, so every path returns nil instead of throwing into the UI.
///
/// Three rules keep a sick sidecar from taking the app down with it:
///   * Every read has a real deadline (`poll` on the pipe), so a wedged model
///     costs one timeout, after which the process is killed and the next
///     miss starts a fresh one.
///   * Every answer is matched to its request `id`. A late reply to an
///     abandoned query is discarded, never returned for the next one.
///   * Writes to the sidecar never raise SIGPIPE. A sidecar that died between
///     queries (jetsam, an MLX crash) makes the write fail with EPIPE, which
///     is handled, instead of killing the coach.
public final class GroundingService {

    public struct Result {
        public let point: ScreenPoint
        public let ttftMs: Double
        public let totalMs: Double
        public let imageTokens: Int
    }

    public enum State: Equatable {
        case notStarted
        case loading
        case ready(model: String, loadSeconds: Double)
        case failed(String)
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return currentState
    }

    private var currentState: State = .notStarted
    private var process: Process?
    private var toChild: FileHandle?
    private var fromChildFD: Int32 = -1
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stderrTail = Data()
    private let lock = NSLock()
    private var nextID = 1
    /// After a launch failure, when the next launch may be attempted. A
    /// missing module will not appear between two queries, and re-spawning
    /// Python on every miss would add its start-up cost to each one.
    private var retryNotBefore: Date?
    private var resolvedPython: String?

    private let serverScript: URL
    private let modelPath: String
    private let scratch: URL

    /// Hard ceiling on one grounding call. Measured worst case is ~7 s on a
    /// full frame; beyond 20 s something is wrong and the user should get an
    /// answer from the tree rather than a spinner.
    public var timeout: TimeInterval = 20

    /// Ceiling on loading the model at start-up.
    public var loadTimeout: TimeInterval = 180

    /// How long to wait before trying to launch again after a failed launch.
    public var relaunchBackoff: TimeInterval = 30

    /// An explicit interpreter. When nil, `SCREENCOACH_PYTHON`, then the
    /// `pythonPath` user default (`defaults write <bundle id> pythonPath …`),
    /// then a list of usual install locations are tried, and the first one
    /// that can import `mlx_vlm` and `PIL` is used.
    ///
    /// Never `/usr/bin/env python3`: an app launched from Finder, the Dock or
    /// a login item gets launchd's PATH, where `python3` is the system stub
    /// without MLX, so vision would work from a shell and never from the app.
    public var pythonPath: String?

    /// Decides whether an interpreter can run the sidecar. A seam for tests,
    /// which drive the service with a stand-in sidecar that needs no MLX.
    var interpreterProbe: (String) -> Bool = GroundingService.hasVisionModules

    public static let pythonDefaultsKey = "pythonPath"
    public static let pythonEnvironmentKey = "SCREENCOACH_PYTHON"

    public init(serverScript: URL, modelPath: String) {
        self.serverScript = serverScript
        self.modelPath = modelPath
        self.scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("screencoach-frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch,
                                                 withIntermediateDirectories: true)
    }

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    // MARK: - Lifecycle

    /// Blocks until the model is loaded or the attempt fails. Callers run this
    /// off the main thread; it is only ever paid once while the sidecar lives.
    @discardableResult
    public func startIfNeeded() -> Bool {
        lock.lock()
        if case .ready = currentState {
            if process?.isRunning == true { lock.unlock(); return true }
            // Died between queries. Start again below.
            lock.unlock()
            teardown(state: .notStarted)
            lock.lock()
        }
        if case .loading = currentState { lock.unlock(); return false }
        if let notBefore = retryNotBefore, Date() < notBefore {
            lock.unlock(); return false
        }
        guard FileManager.default.fileExists(atPath: serverScript.path) else {
            currentState = .failed("holo_server.py not found at \(serverScript.path)")
            lock.unlock(); return false
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            currentState = .failed("no model at \(modelPath) — vision fallback disabled")
            lock.unlock(); return false
        }
        currentState = .loading
        lock.unlock()

        guard let python = resolvePython() else {
            failLaunch("no Python with mlx_vlm and Pillow found — set "
                       + "\(Self.pythonEnvironmentKey) or the \(Self.pythonDefaultsKey) "
                       + "default to an interpreter that has them")
            return false
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [serverScript.path, modelPath]
        // Never write bytecode next to the script: inside a signed bundle a
        // __pycache__ would break the seal. holo_server.py also turns it off
        // itself; this covers anything imported before that line runs.
        p.environment = ProcessInfo.processInfo.environment
            .merging(["PYTHONDONTWRITEBYTECODE": "1"]) { $1 }
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        // The write end must report EPIPE rather than raise SIGPIPE, whose
        // default action would terminate the whole app.
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        // Keep the tail of stderr so a failure can say why. Draining it also
        // stops a chatty library from filling the pipe and blocking the child.
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self else { return }
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            self.lock.lock()
            self.stderrTail.append(chunk)
            if self.stderrTail.count > 4096 {
                self.stderrTail.removeFirst(self.stderrTail.count - 4096)
            }
            self.lock.unlock()
        }

        do { try p.run() } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            failLaunch("could not launch \(python): \(error.localizedDescription)")
            return false
        }
        lock.lock()
        process = p
        toChild = inPipe.fileHandleForWriting
        stdoutHandle = outPipe.fileHandleForReading
        stderrHandle = errPipe.fileHandleForReading
        fromChildFD = outPipe.fileHandleForReading.fileDescriptor
        stderrTail.removeAll()
        lock.unlock()

        switch readLine(matching: nil, timeout: loadTimeout) {
        case .line(let hello):
            if let ready = hello["ready"] as? Bool, ready {
                lock.lock()
                currentState = .ready(model: hello["model"] as? String ?? modelPath,
                                      loadSeconds: hello["load_s"] as? Double ?? 0)
                retryNotBefore = nil
                lock.unlock()
                return true
            }
            teardown(state: .failed(hello["error"] as? String ?? "sidecar failed to load"))
        case .timedOut:
            teardown(state: .failed(String(format: "sidecar did not report ready in %.0f s",
                                           loadTimeout)))
        case .eof:
            teardown(state: .failed("sidecar exited during load" + stderrSuffix()))
        }
        lock.lock(); retryNotBefore = Date().addingTimeInterval(relaunchBackoff); lock.unlock()
        return false
    }

    /// Ask the sidecar to quit, give it up to `grace` seconds to exit on its
    /// own (it finishes the request in hand and exits on quit or EOF), and
    /// only then terminate it. Killing it mid-request is the fallback, not
    /// the plan.
    public func shutdown(grace: TimeInterval = 2) {
        // Take the handle so no request can start writing to it while it is
        // being closed.
        lock.lock(); let handle = toChild; toChild = nil; let p = process; lock.unlock()
        if let handle, let p, p.isRunning {
            // No SIGPIPE: the descriptor is set to fail with EPIPE instead.
            try? handle.write(contentsOf: Data("{\"op\":\"quit\"}\n".utf8))
            try? handle.close()
            let deadline = Date().addingTimeInterval(grace)
            while p.isRunning && Date() < deadline { usleep(50_000) }
        }
        teardown(state: .notStarted)
    }

    deinit { shutdown() }

    // MARK: - Grounding

    /// Ground `query` in `image`, optionally restricted to `crop`.
    ///
    /// `crop` and the returned point are both in the image's own pixel space.
    /// The caller converts to screen coordinates, because only the caller knows
    /// which display the frame came from — and that index has to survive the
    /// whole round trip or the pointer lands on the wrong monitor.
    public func ground(image: CGImage, query: String, cropPixels: CGRect?,
                       screenIndex: Int, displayScale: CGFloat,
                       displayOrigin: CGPoint) -> Result? {
        guard isReady else { return nil }

        // Crop here rather than in the sidecar. Encoding a 5K frame costs
        // ~90 ms and decoding it again another ~65 ms, for pixels the model
        // never sees when the tree has already aimed a crop.
        var sent = image
        var offset = CGPoint.zero
        if let c = cropPixels?.integral.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height)),
           !c.isEmpty, let cropped = image.cropping(to: c) {
            sent = cropped
            offset = c.origin
        }

        let frameURL = scratch.appendingPathComponent("frame-\(UUID().uuidString).png")
        guard write(sent, to: frameURL) else { return nil }
        // The frame is deleted the moment the answer comes back, or the
        // moment the attempt is abandoned. Nothing is persisted by default —
        // that is the headline privacy claim and it has to be true in the
        // code, not only in the README.
        defer { try? FileManager.default.removeItem(at: frameURL) }

        lock.lock()
        let id = nextID; nextID += 1
        let handle = toChild
        let alive = process?.isRunning == true
        lock.unlock()
        guard alive, let handle else {
            teardown(state: .notStarted)
            return nil
        }

        let request: [String: Any] = ["id": id, "image": frameURL.path, "query": query]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        do {
            try handle.write(contentsOf: data + Data("\n".utf8))
        } catch {
            // EPIPE: the sidecar is gone. The next miss starts a new one.
            teardown(state: .failed("sidecar exited" + stderrSuffix()
                                    + "; restarts on the next miss"))
            return nil
        }

        let response: [String: Any]
        switch readLine(matching: id, timeout: timeout) {
        case .line(let obj):
            response = obj
        case .timedOut:
            // Never reuse a pipe that may still deliver this late answer:
            // kill the sidecar so the next miss relaunches clean.
            NSLog(String(format: "ScreenCoach: grounding timed out after %.0f s — "
                         + "restarting the sidecar on the next miss", timeout))
            teardown(state: .failed(String(format: "timed out after %.0f s; "
                                           + "restarts on the next miss", timeout)))
            return nil
        case .eof:
            teardown(state: .failed("sidecar exited" + stderrSuffix()
                                    + "; restarts on the next miss"))
            return nil
        }

        if let error = response["error"] as? String {
            NSLog("ScreenCoach: grounding failed — \(error)")
            return nil
        }
        guard let rx = response["x"] as? Double, let ry = response["y"] as? Double else {
            return nil
        }
        let px = rx + Double(offset.x), py = ry + Double(offset.y)

        // Image pixels → display points → global CG, keeping the screen index.
        let cg = CGPoint(x: displayOrigin.x + px / displayScale,
                         y: displayOrigin.y + py / displayScale)
        return Result(
            point: ScreenPoint(cg: cg, screenIndex: screenIndex),
            ttftMs: response["ttft_ms"] as? Double ?? 0,
            totalMs: response["total_ms"] as? Double ?? 0,
            imageTokens: response["tokens"] as? Int ?? 0
        )
    }

    // MARK: - Interpreter

    /// Every interpreter worth trying, in order. Pure apart from reading the
    /// file system for installed Python.framework versions.
    static func candidateInterpreters(explicit: String?, environment: [String: String],
                                      defaultsValue: String?, modelPath: String) -> [String] {
        var out: [String] = []
        func add(_ p: String?) {
            guard let p, !p.isEmpty else { return }
            let expanded = (p as NSString).expandingTildeInPath
            if !out.contains(expanded) { out.append(expanded) }
        }
        add(explicit)
        add(environment[pythonEnvironmentKey])
        add(defaultsValue)

        let model = URL(fileURLWithPath: modelPath)
        add(model.appendingPathComponent(".venv/bin/python3").path)
        add(model.deletingLastPathComponent().appendingPathComponent(".venv/bin/python3").path)

        let framework = "/Library/Frameworks/Python.framework/Versions"
        add("\(framework)/Current/bin/python3")
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: framework)) ?? [])
            .filter { $0.first?.isNumber == true }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in versions { add("\(framework)/\(v)/bin/python3") }

        add("/opt/homebrew/bin/python3")
        add("/usr/local/bin/python3")
        add("/usr/bin/python3")
        return out
    }

    private func resolvePython() -> String? {
        lock.lock(); let cached = resolvedPython; lock.unlock()
        if let cached { return cached }
        let candidates = Self.candidateInterpreters(
            explicit: pythonPath,
            environment: ProcessInfo.processInfo.environment,
            defaultsValue: UserDefaults.standard.string(forKey: Self.pythonDefaultsKey),
            modelPath: modelPath)
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            if interpreterProbe(c) {
                lock.lock(); resolvedPython = c; lock.unlock()
                return c
            }
        }
        return nil
    }

    /// Asks an interpreter whether it can import what the sidecar needs,
    /// without importing it: `find_spec` answers in tens of milliseconds
    /// where importing MLX takes seconds.
    static func hasVisionModules(_ python: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-c", "import importlib.util as u, sys; "
                       + "sys.exit(0 if u.find_spec('mlx_vlm') and u.find_spec('PIL') else 1)"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return false }
        if done.wait(timeout: .now() + 10) == .timedOut {
            p.terminate()
            return false
        }
        return p.terminationStatus == 0
    }

    // MARK: - Plumbing

    private func write(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    private func failLaunch(_ why: String) {
        lock.lock()
        currentState = .failed(why)
        retryNotBefore = Date().addingTimeInterval(relaunchBackoff)
        lock.unlock()
    }

    /// Kills the sidecar (if any) and resets every piece of per-process state,
    /// so the next miss starts from nothing rather than from a half-read pipe.
    private func teardown(state newState: State) {
        lock.lock()
        let p = process
        stderrHandle?.readabilityHandler = nil
        process = nil
        toChild = nil
        stdoutHandle = nil
        stderrHandle = nil
        fromChildFD = -1
        currentState = newState
        lock.unlock()

        guard let p, p.isRunning else { return }
        p.terminate()
        // A process stuck inside a GPU call may ignore SIGTERM.
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func stderrSuffix() -> String {
        lock.lock(); let tail = stderrTail; lock.unlock()
        let text = String(decoding: tail, as: UTF8.self)
        guard let last = text.split(separator: "\n").last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return "" }
        return " — " + last.trimmingCharacters(in: .whitespaces).prefix(200)
    }

    enum ReadOutcome {
        case line([String: Any])
        case timedOut
        case eof
    }

    /// Reads newline-delimited JSON until an object with `id` arrives (any
    /// object when `id` is nil), the deadline passes, or the pipe closes.
    ///
    /// The deadline is enforced inside the wait, with `poll`, not between
    /// reads: a sidecar that stops writing mid-request would otherwise block
    /// the caller for ever. Objects for other ids are stale answers to
    /// abandoned queries and are dropped.
    ///
    /// The buffer is local on purpose. The protocol is one reply per
    /// request, so anything left over after the matching line is a stale
    /// reply, and nothing survives from one query into the next.
    private func readLine(matching id: Int?, timeout: TimeInterval) -> ReadOutcome {
        lock.lock(); let fd = fromChildFD; lock.unlock()
        guard fd >= 0 else { return .eof }
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var buffer = Data()

        while true {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let obj = try? JSONSerialization.jsonObject(with: lineData)
                        as? [String: Any] else { continue }
                if let id {
                    guard (obj["id"] as? Int) == id else {
                        NSLog("ScreenCoach: discarding a stale sidecar reply")
                        continue
                    }
                }
                return .line(obj)
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .timedOut }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ms = Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up))
            let ready = poll(&pfd, 1, max(ms, 1))
            if ready < 0 {
                if errno == EINTR { continue }
                return .eof
            }
            if ready == 0 { return .timedOut }

            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                return .eof   // the sidecar exited
            } else if errno != EINTR && errno != EAGAIN {
                return .eof
            }
        }
    }

    public var statusLine: String {
        switch state {
        case .notStarted: return "vision: not loaded (loads on first AX miss)"
        case .loading: return "vision: loading…"
        case .ready(let m, let s):
            return String(format: "vision: ready (%@, %.1fs)",
                          (m as NSString).lastPathComponent, s)
        case .failed(let why): return "vision: unavailable — \(why)"
        }
    }
}
