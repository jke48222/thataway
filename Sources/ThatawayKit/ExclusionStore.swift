import Foundation
import ThatawayCore

/// Loads the exclusion list from disk and reloads it the instant it changes.
///
/// Hot reload is a privacy requirement, not a convenience. If excluding your
/// bank means quitting and relaunching the coach, the realistic behaviour is
/// that nobody does it and the list stays at its defaults forever. Editing the
/// file has to take effect before the next query, which means watching it.
///
/// The file is plain text and lives somewhere the user can find it, so the
/// privacy control is auditable. A protection you cannot read is a promise,
/// not a mechanism.
///
/// Two rules keep the user's own list safe while editors save over it:
///
///   * The defaults are written to disk once, only when the file does not
///     exist at startup. The watcher never writes. An editor that briefly
///     removes the file mid-save must not get its work replaced by defaults.
///   * A file that exists but cannot be read, or that is missing or empty
///     for a moment during a save, leaves the list in memory as it was. Only
///     a successful read replaces it.
public final class ExclusionStore {

    public private(set) var list: ExclusionList
    public let url: URL

    /// Set when the file could not be read and the previous list was kept,
    /// so the menu can say so instead of looking as if the edit applied.
    public var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return error
    }

    /// How many times the file was re-read successfully after a change.
    public var reloadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return reloads
    }

    private var error: String?
    private var reloads = 0
    private var parseIssues: [ExclusionList.ParseIssue] = []
    private var source: DispatchSourceFileSystemObject?
    private let lock = NSLock()
    private let queue: DispatchQueue
    /// Bumped on every re-arm so a delayed retry from an older watch cannot
    /// replace a newer one.
    private var generation = 0

    /// Fired after a reload so the UI can show the new count.
    public var onChange: ((ExclusionList) -> Void)?

    /// - Parameter queue: where file events and `onChange` are delivered.
    ///   Main by default, which is what the app wants; tests pass their own.
    public init(url: URL? = nil, queue: DispatchQueue = .main) {
        let resolved = url ?? ConfigFolder.url.appendingPathComponent("exclusions.conf")
        self.url = resolved
        self.queue = queue
        self.list = ExclusionList.defaults
        seedIfMissing()
        load()
        watch(attempt: 0)
    }

    deinit { stopWatching() }

    // MARK: - Loading

    /// First run only: write the defaults out so the user can see exactly
    /// what is being excluded rather than having to trust a claim.
    private func seedIfMissing() {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? ExclusionList.defaults.serialized().write(to: url, atomically: true,
                                                       encoding: .utf8)
    }

    private enum LoadResult { case loaded, missing, empty, unreadable }

    /// Reads the file into `list`. Never writes to disk.
    @discardableResult
    private func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let why = "could not read \(url.lastPathComponent): \(error.localizedDescription)"
            lock.lock(); self.error = why; lock.unlock()
            return .unreadable
        }
        guard !data.isEmpty else { return .empty }

        // Lossy decode: one stray Latin-1 byte in a comment must not cost the
        // user every rule in the file.
        let report = ExclusionList.parseReport(String(decoding: data, as: UTF8.self))
        let parsed = report.list
        // A rule that is read as something other than what it says must be
        // said out loud, not silently reinterpreted.
        for issue in report.issues {
            NSLog("Thataway: \(url.lastPathComponent) line \(issue.line): "
                  + "\(issue.message): “\(issue.text)”")
        }
        lock.lock()
        parseIssues = report.issues
        // A file with no rules means the defaults, never "allow everything".
        // Failing open here would silently disable the whole protection the
        // moment someone deleted every line.
        list = parsed.rules.isEmpty ? .defaults : parsed
        error = nil
        lock.unlock()
        return .loaded
    }

    public func reload() {
        if load() == .loaded {
            lock.lock(); reloads += 1; lock.unlock()
        }
        onChange?(current)
    }

    public var current: ExclusionList {
        lock.lock(); defer { lock.unlock() }
        return list
    }

    // MARK: - The gate

    /// The single question every capture path must ask first.
    public func check(bundleID: String?, windowTitle: String?) -> ExclusionList.Verdict {
        current.check(bundleID: bundleID, windowTitle: windowTitle)
    }

    // MARK: - Watching

    /// Arms a watch on the file.
    ///
    /// Each source owns the descriptor it was created with and closes that
    /// descriptor, and only that one, in its own cancel handler. Cancel
    /// handlers run asynchronously; one that closed "the store's current
    /// descriptor" would close the descriptor of the watch that replaced it,
    /// which is how the watch used to die after the first editor save.
    private func watch(attempt: Int) {
        stopWatching()
        lock.lock(); generation += 1; let myGeneration = generation; lock.unlock()

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // The path can be missing for a few milliseconds while an editor
            // renames the old file away and creates the new one. Keep trying
            // for a while; the in-memory list stays as it was meanwhile.
            guard attempt < 60 else {
                lock.lock()
                error = "stopped watching \(url.lastPathComponent): the file is missing"
                lock.unlock()
                onChange?(current)
                return
            }
            let delay = attempt < 20 ? 0.05 : 1.0
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let stale = self.generation != myGeneration; self.lock.unlock()
                guard !stale else { return }
                self.watch(attempt: attempt + 1)
                // The file may have appeared with new contents while nobody
                // was watching it.
                self.reloadSettling(retriesLeft: 0)
            }
            return
        }

        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: queue
        )
        s.setEventHandler { [weak self, weak s] in
            guard let self, let s else { return }
            let flags = s.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Editors replace rather than write in place, which leaves
                // this descriptor on the old file. Re-arm on the path, then
                // read whatever is there now: the re-arm catches later saves,
                // the read catches this one.
                self.queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); let stale = self.generation != myGeneration; self.lock.unlock()
                    guard !stale else { return }
                    self.watch(attempt: 0)
                    self.reloadSettling(retriesLeft: 5)
                }
                return
            }
            self.reloadSettling(retriesLeft: 3)
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        lock.lock(); source = s; lock.unlock()
    }

    /// Reloads, retrying briefly while the file is missing or empty, which is
    /// what a save looks like from outside for a moment. The list in memory
    /// is kept throughout; only a successful read replaces it.
    private func reloadSettling(retriesLeft: Int) {
        switch load() {
        case .loaded:
            lock.lock(); reloads += 1; lock.unlock()
            onChange?(current)
        case .missing, .empty:
            if retriesLeft > 0 {
                queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.reloadSettling(retriesLeft: retriesLeft - 1)
                }
            }
        case .unreadable:
            onChange?(current)
        }
    }

    private func stopWatching() {
        lock.lock(); let s = source; source = nil; lock.unlock()
        s?.cancel()
    }

    /// Lines of the last file read that were not taken literally.
    public var issues: [ExclusionList.ParseIssue] {
        lock.lock(); defer { lock.unlock() }
        return parseIssues
    }

    public var statusLine: String {
        let l = current
        let bundles = l.rules.filter { $0.kind == .bundleID }.count
        let titles = l.rules.filter { $0.kind == .titleContains }.count
        var base = "\(bundles) apps, \(titles) title patterns excluded"
        let flagged = issues.count
        if flagged > 0 {
            base += " · \(flagged) line\(flagged == 1 ? "" : "s") not understood"
        }
        return lastError.map { "\(base) (\($0); previous rules kept)" } ?? base
    }
}
