import AppKit
import CoreGraphics
import ThatawayCore

/// Listen-only tap for left-clicks, on its own thread — the same shape as
/// `HotKeyTap` and for the same reasons: the system disables a tap whose
/// callback runs long, and `.listenOnly` means a hung coach can never eat the
/// user's clicks. The callback does nothing but forward the point; every
/// decision happens on the main queue.
///
/// `CGEvent.location` is already in global CG space — top-left origin at the
/// primary display, the same space AX bounds live in — so the click can be
/// hit-tested against the tree with no conversion at all. One of the few
/// places in this project where two coordinate systems agree for free.
public final class MouseTap {

    public var onClick: ((CGPoint, UInt64) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    public init() {}

    public func start() throws {
        var thrown: Error?
        let t = Thread { [weak self] in
            guard let self else { return }
            do { try self.install() } catch {
                thrown = error
                self.ready.signal()
                return
            }
            self.runLoop = CFRunLoopGetCurrent()
            self.ready.signal()
            CFRunLoopRun()
        }
        t.name = "com.jalenedusei.thataway.mouse"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
        if let thrown { throw thrown }
    }

    private func install() throws {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MouseTap>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if type == .leftMouseDown {
                me.onClick?(event.location, Mono.machToNs(event.timestamp))
            }
            return Unmanaged.passUnretained(event)
        }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: callback, userInfo: refcon
        ) else { throw HotKeyTap.TapError.tapCreationFailed }
        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop {
            if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            CFRunLoopStop(runLoop)
        }
        source = nil
        tap = nil
        runLoop = nil
        thread = nil
    }

    deinit { stop() }
}

/// "Watch me" mode: the user clicks through a task once, and each click
/// becomes a semantic step — described by what it *is*, never where it was.
///
/// The pipeline per click: grab the warm tree (the before-state), hit-test
/// the click against it, synthesize the resolver-vocabulary query for the
/// element, then wait for the UI to settle and diff the trees to learn what
/// the click *did* — which becomes the step's completion condition, so replay
/// advances exactly when the learner's click has the effect the author's had.
///
/// The settle wait has an escape hatch: if the next click arrives first, that
/// click's before-tree IS the previous click's after-state. The state of the
/// world when the author moved on is, by definition, the state their step
/// produced — and it makes fast clickers record correctly instead of racing
/// the timer.
public final class WorkflowRecorder {

    public struct Recorded {
        public let step: Step
        public let clickedLabel: String
    }

    private let cache: AXCache
    private let mouse = MouseTap()
    private var steps: [Recorded] = []
    private var pending: (query: String, label: String, before: [AXNode], deadline: DispatchWorkItem)?
    private var appName = ""
    private var bundleID: String?
    /// True while any menu of this process is open — the status-item menu
    /// the author stops the recording from, most of all.
    private var menuTracking = false
    private var menuObservers: [NSObjectProtocol] = []

    public private(set) var isRecording = false

    /// Fired on the main queue as each step is understood, so the UI can show
    /// "3 steps so far" while the author works.
    public var onStep: ((Recorded, Int) -> Void)?
    public var onSkipped: ((String) -> Void)?

    /// How long after a click we wait for its consequences before diffing.
    /// Sheets animate in around 300 ms; menus are faster. Interrupted early
    /// by the next click, so slow is safe and fast is automatic.
    public var settleSeconds: TimeInterval = 0.7

    public init(cache: AXCache) {
        self.cache = cache
    }

    deinit {
        for o in menuObservers { NotificationCenter.default.removeObserver(o) }
    }

    public func start() throws {
        guard !isRecording else { return }
        steps = []
        pending = nil
        let tree = cache.tree()
        appName = tree?.appName ?? "this app"
        bundleID = tree?.bundleID
        observeMenuTracking()
        let me = ProcessInfo.processInfo.processIdentifier
        mouse.onClick = { [weak self] point, _ in
            // Decided here, on the tap thread, at the moment of the click:
            // by the time main runs, a menu that was clicked may already
            // have closed. The coach is an accessory app whose UI (the
            // status-item menu, the command bar, the overlay) never makes it
            // frontmost, so "is the coach frontmost" can never recognise a
            // click on it; "is the point inside one of our windows" can.
            let onCoach = WindowServer.window(ownedBy: me, contains: point)
            DispatchQueue.main.async {
                self?.handleClick(at: point, onCoach: onCoach)
            }
        }
        try mouse.start()
        isRecording = true
    }

    private func observeMenuTracking() {
        guard menuObservers.isEmpty else { return }
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                               queue: .main) { [weak self] _ in self?.menuTracking = true },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil,
                               queue: .main) { [weak self] _ in self?.menuTracking = false },
        ]
    }

    /// Stop and produce the lesson. Any pending step is finalized against the
    /// current tree first — the recording ends, the last click still counts.
    public func finish() -> Lesson? {
        guard isRecording else { return nil }
        mouse.stop()
        isRecording = false
        finalizePending(with: cache.refreshNow()?.nodes ?? [])

        guard !steps.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return Lesson(
            title: "\(appName): recorded \(formatter.string(from: Date()))",
            bundleID: bundleID,
            steps: steps.map(\.step)
        )
    }

    public func cancel() {
        mouse.stop()
        isRecording = false
        pending?.deadline.cancel()
        pending = nil
        steps = []
    }

    // MARK: - Click handling

    private func handleClick(at point: CGPoint, onCoach: Bool) {
        // A click handled after the recording stopped is not part of it.
        guard isRecording else { return }
        // Clicks on the coach itself — the menu bar item, its menu, the
        // command bar — are the author steering the recorder, not part of
        // the workflow. The menu may sit over the recorded app's window, so
        // hit-testing that click against the app's tree would invent a step.
        if onCoach || menuTracking { return }

        guard let tree = cache.tree(), !tree.nodes.isEmpty else {
            onSkipped?("no accessible tree at click time")
            return
        }

        // This click's before-tree closes out the previous step, if one is
        // still waiting on its settle timer.
        finalizePending(with: tree.nodes)

        guard let node = WorkflowInference.hitTest(point, in: tree.nodes) else {
            onSkipped?("click did not land on a labelled element")
            return
        }
        guard let query = WorkflowInference.semanticQuery(for: node, in: tree.nodes) else {
            onSkipped?("clicked element has no usable label")
            return
        }
        let label = WorkflowInference.bestLabel(node) ?? query

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // A forced read, not the cache: a click that toggles a checkbox
            // or opens a menu may not have refreshed it yet, and diffing the
            // before-tree against itself would record every step as manual.
            self.finalizePending(with: self.cache.refreshNow()?.nodes ?? [])
        }
        pending = (query, label, tree.nodes, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds, execute: work)
    }

    private func finalizePending(with after: [AXNode]) {
        guard let p = pending else { return }
        pending = nil
        p.deadline.cancel()

        let completion = after.isEmpty
            ? Step.Completion.manual
            : WorkflowInference.inferCompletion(clickedQuery: p.query,
                                                before: p.before, after: after)
        let step = Step(instruction: "Click \(p.label)", target: p.query,
                        completion: completion)
        let recorded = Recorded(step: step, clickedLabel: p.label)
        steps.append(recorded)
        onStep?(recorded, steps.count)
    }
}

/// Recorded workflows on disk: one readable JSON file per lesson, in a
/// directory the user can browse, edit, and copy to another machine — moving
/// the file IS the "teach it on someone else's Mac" story, because nothing in
/// it refers to this machine: no coordinates, no window sizes, no display
/// geometry. Only names.
public final class LessonStore {

    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? ConfigFolder.url.appendingPathComponent("lessons")
        try? FileManager.default.createDirectory(at: self.directory,
                                                 withIntermediateDirectories: true)
    }

    public func save(_ lesson: Lesson) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let slug = lesson.title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        var url = directory.appendingPathComponent("\(slug).json")
        // Never silently replace an existing recording.
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(slug)-\(counter).json")
            counter += 1
        }
        try encoder.encode(lesson).write(to: url)
        return url
    }

    /// Largest lesson file read. Lessons are a few kilobytes of names; the
    /// cap exists because they are also meant to be copied from other
    /// people's Macs, which makes them untrusted input.
    public var maxLessonBytes = 1_000_000

    private var titleCache: [URL: (modified: Date, size: Int, title: String?)] = [:]
    private let cacheLock = NSLock()

    /// The saved lessons, by title. Called every time the menu opens, on
    /// main, so a title is re-parsed only when its file changed.
    public func list() -> [(title: String, url: URL)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey,
                                      .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        )) ?? []
        var out: [(title: String, url: URL)] = []
        var seen = Set<URL>()
        for url in urls where url.pathExtension == "json" {
            guard let v = safeAttributes(url) else { continue }
            seen.insert(url)
            cacheLock.lock(); let hit = titleCache[url]; cacheLock.unlock()
            let title: String?
            if let hit, hit.modified == v.modified, hit.size == v.size {
                title = hit.title
            } else {
                title = load(url)?.title
                cacheLock.lock(); titleCache[url] = (v.modified, v.size, title); cacheLock.unlock()
            }
            if let title { out.append((title, url)) }
        }
        cacheLock.lock()
        titleCache = titleCache.filter { seen.contains($0.key) }
        cacheLock.unlock()
        return out.sorted { $0.title < $1.title }
    }

    /// Loads a lesson, refusing anything that is not a plain regular file of
    /// modest size: a symlink to /dev/zero or a multi-gigabyte file must not
    /// be able to hang the menu.
    public func load(_ url: URL) -> Lesson? {
        guard safeAttributes(url) != nil,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxLessonBytes + 1),
              data.count <= maxLessonBytes else { return nil }
        return try? JSONDecoder().decode(Lesson.self, from: data)
    }

    private func safeAttributes(_ url: URL) -> (modified: Date, size: Int)? {
        var url = url
        url.removeAllCachedResourceValues()
        guard let v = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]) else { return nil }
        guard v.isSymbolicLink != true, v.isRegularFile == true,
              let size = v.fileSize, size <= maxLessonBytes else { return nil }
        return (v.contentModificationDate ?? .distantPast, size)
    }
}
