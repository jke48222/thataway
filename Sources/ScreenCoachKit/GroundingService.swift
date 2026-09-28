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
///
/// And two keep it from becoming a privacy hole:
///   * The sidecar is spawned with responsibility disclaimed
///     (`SidecarProcess`), in isolated mode, with a minimal environment. It
///     does not inherit the coach's Accessibility, Screen Recording or
///     Microphone grants, so whichever interpreter runs gets nothing the
///     user's own shell does not already have.
///   * No frame touches the disk when the sidecar can take the image inline.
///     With an older sidecar the frame goes to a 0600 file that is removed
///     when the answer comes back, and any frame a crash or force quit left
///     behind is swept at the next start and before every write.
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
    private var process: SidecarProcess?
    private var fromChildFD: Int32 = -1
    private var stderrSource: DispatchSourceRead?
    private var stderrTail = Data()
    /// Whether the running sidecar said it takes the frame inline
    /// (`"inline_image": true` in its ready line), so no frame file exists.
    private var sidecarTakesInlineImage = false
    private var lastFailureReason: String?
    /// Grounding calls in progress, so `shutdown()` can let each one finish
    /// deleting its frame before the process exits.
    private let inFlight = DispatchGroup()
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

    /// A frame file older than this cannot belong to a call still in
    /// progress anywhere (every call ends by `timeout`), so it is left over
    /// from a crash or force quit and is deleted.
    var staleFrameAge: TimeInterval { max(60, timeout * 2) }

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

    public convenience init(serverScript: URL, modelPath: String) {
        self.init(serverScript: serverScript, modelPath: modelPath, scratchDirectory: nil)
    }

    /// `scratchDirectory` is a seam for tests; the app uses the default,
    /// `$TMPDIR/screencoach-frames`, which is inside the per-user 0700
    /// temporary directory.
    init(serverScript: URL, modelPath: String, scratchDirectory: URL?) {
        self.serverScript = serverScript
        self.modelPath = modelPath
        self.scratch = scratchDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("screencoach-frames", isDirectory: true)
        // A frame a crash, force quit or power loss left behind from an
        // earlier run goes now, not whenever the OS next clears tmp.
        _ = prepareScratch()
    }

    /// Why the last `ground` call returned nil, in words the status line can
    /// show: a frame that could not be written reads differently from a model
    /// that looked and found nothing. Nil after a call that succeeded.
    public var lastFailure: String? {
        lock.lock(); defer { lock.unlock() }
        return lastFailureReason
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
            currentState = .failed("no model at \(modelPath): vision fallback disabled")
            lock.unlock(); return false
        }
        currentState = .loading
        lock.unlock()

        guard let python = resolvePython() else {
            failLaunch("no Python with mlx_vlm and Pillow found: set "
                       + "\(Self.pythonEnvironmentKey) or the \(Self.pythonDefaultsKey) "
                       + "default to an interpreter that has them")
            return false
        }

        // Disclaimed, isolated and with a minimal environment: see
        // `SidecarProcess`. `-I` ignores PYTHONPATH, PYTHONHOME,
        // PYTHONSTARTUP and user site-packages; holo_server.py adds its own
        // directory to sys.path itself. `-B` because `-I` also ignores
        // PYTHONDONTWRITEBYTECODE, and inside a signed bundle a __pycache__
        // written next to the script would break the seal.
        let p: SidecarProcess
        do {
            p = try SidecarProcess.spawn(
                executable: python,
                arguments: Self.interpreterFlags + [serverScript.path, modelPath],
                environment: SidecarProcess.minimalEnvironment(
                    from: ProcessInfo.processInfo.environment,
                    adding: ["PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1"]))
        } catch {
            failLaunch("could not launch \(python): \(error)")
            return false
        }

        // Keep the tail of stderr so a failure can say why. Draining it also
        // stops a chatty library from filling the pipe and blocking the child.
        let errFD = p.stderrFD
        let source = DispatchSource.makeReadSource(fileDescriptor: errFD,
                                                   queue: .global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = buf.withUnsafeMutableBytes { read(errFD, $0.baseAddress, $0.count) }
            guard n > 0 else {
                if n == 0 || (errno != EINTR && errno != EAGAIN) { source?.cancel() }
                return
            }
            guard let self else { return }
            self.lock.lock()
            self.stderrTail.append(contentsOf: buf[0..<n])
            if self.stderrTail.count > 4096 {
                self.stderrTail.removeFirst(self.stderrTail.count - 4096)
            }
            self.lock.unlock()
        }
        source.resume()

        lock.lock()
        process = p
        stderrSource = source
        fromChildFD = p.stdoutFD
        stderrTail.removeAll()
        sidecarTakesInlineImage = false
        lock.unlock()

        switch readLine(matching: nil, timeout: loadTimeout) {
        case .line(let hello):
            if let ready = hello["ready"] as? Bool, ready {
                lock.lock()
                currentState = .ready(model: hello["model"] as? String ?? modelPath,
                                      loadSeconds: hello["load_s"] as? Double ?? 0)
                sidecarTakesInlineImage = hello["inline_image"] as? Bool ?? false
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
    ///
    /// A grounding call in progress is also given until the same deadline to
    /// return, so its frame file (if any) is deleted before the app exits
    /// rather than left in $TMPDIR.
    public func shutdown(grace: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(grace)
        lock.lock(); let p = process; lock.unlock()
        if let p, p.isRunning {
            // No SIGPIPE: the descriptor is set to fail with EPIPE instead.
            _ = p.writeToStdin(Data("{\"op\":\"quit\"}\n".utf8),
                               deadline: Date().addingTimeInterval(0.2))
            // EOF also tells the sidecar to finish the request in hand and
            // exit, which in turn ends a `ground` call waiting on it.
            p.closeStdin()
            _ = p.waitForExit(timeout: max(0, deadline.timeIntervalSinceNow))
        }
        teardown(state: .notStarted)
        _ = inFlight.wait(timeout: .now() + max(0.1, deadline.timeIntervalSinceNow))
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
        inFlight.enter()
        defer { inFlight.leave() }   // declared first, so it runs last
        setFailure(nil)
        guard isReady else { return fail("vision is not running") }

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

        lock.lock()
        let id = nextID; nextID += 1
        let p = process
        let inline = sidecarTakesInlineImage
        lock.unlock()
        guard let p, p.isRunning else {
            teardown(state: .notStarted)
            return fail("the vision sidecar had exited; it restarts on the next miss")
        }

        guard let png = Self.pngData(sent) else {
            return fail("could not encode the screen frame")
        }

        // Nothing is persisted by default: that is the headline privacy
        // claim and it has to be true in the code, not only in the README.
        // A sidecar that takes the image inline gets the bytes over the pipe
        // and no path ever exists. An older one gets a 0600 file that is
        // deleted the moment the answer comes back or the attempt is
        // abandoned; one left by a crash is swept by the next write or start.
        var request: [String: Any] = ["id": id, "query": query]
        var frameURL: URL?
        if inline {
            request["image_png_b64"] = png.base64EncodedString()
        } else {
            switch writeFrame(png) {
            case .success(let url):
                frameURL = url
                request["image"] = url.path
            case .failure(let why):
                NSLog("ScreenCoach: \(why)")
                return fail(why)
            }
        }
        defer { if let frameURL { try? FileManager.default.removeItem(at: frameURL) } }

        guard let data = try? JSONSerialization.data(withJSONObject: request) else {
            return fail("could not encode the request")
        }
        switch p.writeToStdin(data + Data("\n".utf8),
                              deadline: Date().addingTimeInterval(timeout)) {
        case .written:
            break
        case .timedOut:
            teardown(state: .failed(String(format: "stopped reading requests for %.0f s; "
                                           + "restarts on the next miss", timeout)))
            return fail("the vision sidecar stopped responding")
        case .closed:
            // EPIPE: the sidecar is gone. The next miss starts a new one.
            teardown(state: .failed("sidecar exited" + stderrSuffix()
                                    + "; restarts on the next miss"))
            return fail("the vision sidecar exited")
        }

        let response: [String: Any]
        switch readLine(matching: id, timeout: timeout) {
        case .line(let obj):
            response = obj
        case .timedOut:
            // Never reuse a pipe that may still deliver this late answer:
            // kill the sidecar so the next miss relaunches clean.
            NSLog(String(format: "ScreenCoach: grounding timed out after %.0f s: "
                         + "restarting the sidecar on the next miss", timeout))
            teardown(state: .failed(String(format: "timed out after %.0f s; "
                                           + "restarts on the next miss", timeout)))
            return fail(String(format: "the vision model took longer than %.0f s", timeout))
        case .eof:
            teardown(state: .failed("sidecar exited" + stderrSuffix()
                                    + "; restarts on the next miss"))
            return fail("the vision sidecar exited")
        }

        if let error = response["error"] as? String {
            NSLog("ScreenCoach: grounding failed: \(error)")
            return fail("the vision model found nothing")
        }
        guard let rx = (response["x"] as? NSNumber)?.doubleValue,
              let ry = (response["y"] as? NSNumber)?.doubleValue else {
            return fail("the vision model found nothing")
        }
        // The model reads on-screen text, so what a page shows can steer its
        // reply. A point outside the image it was sent is not an answer.
        guard Self.pointIsInside(x: rx, y: ry, width: sent.width, height: sent.height) else {
            NSLog("ScreenCoach: discarding a vision answer outside the frame")
            return fail("the vision model's answer was outside the screen")
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
            guard Self.isTrustworthyExecutable(c) else {
                NSLog("ScreenCoach: not using \(c): it, or a folder above it, "
                      + "can be changed by other users")
                continue
            }
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
    ///
    /// Spawned exactly like the sidecar (disclaimed, isolated, minimal
    /// environment), so the probe runs nothing with the coach's grants and
    /// answers for the same module search path the sidecar will have.
    static func hasVisionModules(_ python: String) -> Bool {
        guard let p = try? SidecarProcess.spawn(
            executable: python,
            arguments: interpreterFlags + [
                "-c", "import importlib.util as u, sys; "
                    + "sys.exit(0 if u.find_spec('mlx_vlm') and u.find_spec('PIL') else 1)"],
            environment: SidecarProcess.minimalEnvironment(
                from: ProcessInfo.processInfo.environment)) else { return false }
        p.closeStdin()
        defer { p.closeAll() }
        guard let status = p.waitForExit(timeout: 10) else {
            p.terminate(grace: 0.5)
            return false
        }
        return status == 0
    }

    /// Isolated mode, and no bytecode written anywhere.
    static let interpreterFlags = ["-I", "-B"]

    /// Whether an interpreter may be run at all: the file, what it links to,
    /// and every folder above both are owned by this user or by root and
    /// cannot be written by everyone. An interpreter in a shared folder such
    /// as /tmp could be swapped by another account between two queries.
    static func isTrustworthyExecutable(_ path: String) -> Bool {
        let me = getuid()
        func ok(_ p: String) -> Bool {
            var st = stat()
            guard lstat(p, &st) == 0 else { return false }
            return (st.st_uid == me || st.st_uid == 0) && st.st_mode & S_IWOTH == 0
        }
        func chainOK(_ p: String) -> Bool {
            guard p.hasPrefix("/") else { return false }
            var current = (p as NSString).standardizingPath
            while true {
                guard ok(current) else { return false }
                if current == "/" { return true }
                current = (current as NSString).deletingLastPathComponent
                if current.isEmpty { return false }
            }
        }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return chainOK(path) && chainOK(resolved)
    }

    /// A reply's point lies on the image that was sent.
    static func pointIsInside(x: Double, y: Double, width: Int, height: Int) -> Bool {
        x.isFinite && y.isFinite && x >= 0 && y >= 0
            && x <= Double(width) && y <= Double(height)
    }

    // MARK: - Plumbing

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Makes sure the scratch folder exists (the system's tmp cleaner removes
    /// one left unused for days, and a menu bar app outlives that) and
    /// deletes frames old enough to be left over from a crash. Returns why
    /// the folder is unusable, or nil.
    @discardableResult
    func prepareScratch() -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            return "could not create \(scratch.path): \(error.localizedDescription)"
        }
        let cutoff = Date().addingTimeInterval(-staleFrameAge)
        let names = (try? fm.contentsOfDirectory(atPath: scratch.path)) ?? []
        for name in names where name.hasPrefix("frame-") && name.hasSuffix(".png") {
            let url = scratch.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if (modified ?? .distantPast) < cutoff {
                try? fm.removeItem(at: url)
            }
        }
        return nil
    }

    enum FrameWrite { case success(URL), failure(String) }

    /// Writes the frame to a new file only this user can read, refusing to
    /// follow or reuse anything already at the path.
    func writeFrame(_ png: Data) -> FrameWrite {
        if let why = prepareScratch() { return .failure(why) }
        let url = scratch.appendingPathComponent("frame-\(UUID().uuidString).png")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            return .failure("could not write the screen frame: "
                            + String(cString: strerror(errno)))
        }
        let ok = png.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else {
                    return false
                }
            }
            return true
        }
        let err = errno
        close(fd)
        guard ok else {
            try? FileManager.default.removeItem(at: url)
            return .failure("could not write the screen frame: " + String(cString: strerror(err)))
        }
        return .success(url)
    }

    private func setFailure(_ why: String?) {
        lock.lock(); lastFailureReason = why; lock.unlock()
    }

    private func fail(_ why: String) -> Result? {
        setFailure(why)
        return nil
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
        let source = stderrSource
        process = nil
        stderrSource = nil
        fromChildFD = -1
        sidecarTakesInlineImage = false
        currentState = newState
        lock.unlock()

        source?.cancel()
        guard let p else { return }
        // SIGTERM, then SIGKILL after 2 s for a process stuck inside a GPU
        // call, and reaped either way. The pipes close when the last
        // reference to `p` goes.
        p.closeStdin()
        p.terminate(grace: 2)
    }

    private func stderrSuffix() -> String {
        lock.lock(); let tail = stderrTail; lock.unlock()
        let text = String(decoding: tail, as: UTF8.self)
        guard let last = text.split(separator: "\n").last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return "" }
        return ": " + last.trimmingCharacters(in: .whitespaces).prefix(200)
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
        case .failed(let why): return "vision: unavailable (\(why))"
        }
    }
}
