import AppKit
import ApplicationServices
import ScreenCoachCore

/// Keeps the frontmost app's accessibility tree warm and ready.
///
/// Phase 0 made this mandatory rather than optional. Walking an app's tree for
/// the first time costs 45–220 ms — the *target* app has to build and vend it —
/// while every walk after that costs 1–21 ms. The coach's exact situation is
/// "user just switched to an app and pressed the hotkey", which is the cold
/// path, so extracting on the hotkey would blow the 80 ms budget on every app
/// worth teaching.
///
/// Warmth also decays: Logic Pro drifted 21 → 64 ms after ten idle seconds and
/// Calendar went fully cold at 120 ms. So focus-change extraction alone is not
/// enough; a low-rate heartbeat holds the tree warm between queries.
///
/// Three things drive a refresh:
///   * **Focus change** — a different app or window is in front.
///   * **AXObserver events** — the window moved, resized, its focus moved,
///     a value, title or menu changed, an element appeared or went away.
///   * **Heartbeat** — nothing happened, but warmth decays anyway.
///
/// And two things make a cached tree unservable even when it is young: the
/// user scrolled, or clicked, after it was read. Neither raises an AX
/// notification the observer can hear, and both move or change what is on
/// screen.
///
/// Threading: walks run on one serial queue, including on-demand walks from
/// `tree()` and `refreshNow()`, so an on-demand request reuses a walk that is
/// already in flight instead of racing it. The AXObserver lives on the main
/// run loop and is only attached or detached on main.
public final class AXCache {

    public struct Entry {
        public let snapshot: AXTreeSnapshot
        public let capturedAtNs: UInt64
        public var ageMs: Double { Mono.msSince(capturedAtNs) }
    }

    /// Heartbeat interval. Chosen from the measured decay curve: trees are
    /// still near-warm at 5 s and clearly cooling by 10 s, so refreshing every
    /// 3 s keeps the fast path fast without hammering other apps.
    public var heartbeat: TimeInterval = 3.0

    /// Skip heartbeat walks while the user has not touched the machine.
    ///
    /// The heartbeat exists so the hotkey lands on a warm tree — but a hotkey
    /// press requires a human at the keyboard, and if nobody has produced an
    /// input event in over a minute, no press is imminent. Walking a heavy
    /// app's tree every three seconds through lunch is pure battery burn.
    /// Event- and focus-driven refreshes are exempt: they only fire when
    /// something is actually happening. The cost of the trade is one
    /// cold-ish serve (~45–220 ms, once) if the user returns and summons
    /// within the very first seconds.
    public var idleBackoffEnabled = true
    public var userIdleThreshold: TimeInterval = 60

    /// Beyond this the cached tree is treated as untrustworthy and re-read
    /// synchronously, as it is after any scroll or click newer than it.
    public var maxServeAgeMs: Double = 5_000

    /// Event bursts are coalesced: a walk runs this long after the last event
    /// of a burst (trailing edge), so the final geometry of a resize or drag
    /// is always read. `refreshMaxWaitMs` bounds how long a continuous stream
    /// of events can postpone a walk.
    public var refreshDebounceMs: Double = 120
    public var refreshMaxWaitMs: Double = 600

    /// After a walk fails (the app has no window), on-demand requests for the
    /// same app return nil for this long instead of paying for another
    /// failed walk. Any AX or focus event clears it.
    public var failureBackoffMs: Double = 1_000

    public var limits = AXExtractor.Limits.default

    /// Asked before any tree is read. Returning a reason means "do not touch
    /// this app at all".
    ///
    /// Gating only the screenshot was not enough, and testing found it: an
    /// accessibility tree contains the *content*, not just the controls. A
    /// query against Messages happily surfaced the text of a conversation as a
    /// match candidate — no frame was ever captured, and the private data
    /// leaked anyway.
    ///
    /// So exclusion means excluded: no capture, and no tree. The coach cannot
    /// help you inside your password manager, which is the correct trade.
    public var exclusionCheck: ((_ bundleID: String?, _ title: String?) -> String?)?

    /// Set when the last refresh was refused, so the UI can explain itself
    /// rather than looking broken.
    public var lastExclusionReason: String? {
        lock.lock(); defer { lock.unlock() }
        return exclusionReason
    }

    private let queue = DispatchQueue(label: "coach.axcache", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private var entry: Entry?
    private var exclusionReason: String?
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var timer: DispatchSourceTimer?
    private var running = false
    private var targetPID: pid_t = 0
    private var pinnedPID: pid_t = 0
    private var pendingRefresh: DispatchWorkItem?
    private var refreshSeq = 0
    private var burstStartNs: UInt64 = 0
    private var failedPID: pid_t = 0
    private var failedAtNs: UInt64 = 0
    /// Apps that have already been asked to turn on AXManualAccessibility.
    /// The ask sticks, and the 250 ms wait that follows it must not be paid
    /// on every walk of an app that simply has no window.
    private var forcedPIDs = Set<pid_t>()

    /// The app the coach is about, which is never the coach.
    ///
    /// `NSWorkspace.frontmostApplication` answers "who is in front right now",
    /// and once this process has an NSApplication that can briefly be us — on
    /// launch, and whenever the command bar takes keyboard focus. Asking about
    /// ourselves returns a process with no window, so the tree comes back
    /// empty exactly when the user is typing their question.
    ///
    /// Remembering the last frontmost app that was not us is the fix, and it
    /// is also the semantically right answer: the query is about the app the
    /// user was working in, not about the input box they are typing into.
    private func resolveTarget() -> NSRunningApplication? {
        lock.lock(); let pinned = pinnedPID; let remembered = targetPID; lock.unlock()
        if pinned != 0, let app = NSRunningApplication(processIdentifier: pinned),
           !app.isTerminated { return app }
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != me {
            lock.lock(); targetPID = front.processIdentifier; lock.unlock()
            return front
        }
        if remembered != 0, let app = NSRunningApplication(processIdentifier: remembered),
           !app.isTerminated {
            return app
        }
        // Nothing remembered yet: fall back to the frontmost regular app that
        // is not us, which is what the user would point at anyway.
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && !$0.isTerminated
                && $0.processIdentifier != me && $0.isActive
        }
    }

    /// Force the cache to follow one app regardless of focus. Used by the
    /// self-test so the pipeline can be exercised against an app that is not
    /// in front; the product itself always follows focus.
    public func pin(to pid: pid_t) {
        lock.lock(); pinnedPID = pid; entry = nil; lock.unlock()
        attachObserver()
        _ = refreshNow()
    }

    public var refreshes: Int { lock.lock(); defer { lock.unlock() }; return refreshCount }
    public var servedWarm: Int { lock.lock(); defer { lock.unlock() }; return warmCount }
    public var servedCold: Int { lock.lock(); defer { lock.unlock() }; return coldCount }
    private var refreshCount = 0
    private var warmCount = 0
    private var coldCount = 0

    public init() {
        queue.setSpecific(key: queueKey, value: true)
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + heartbeat, repeating: heartbeat,
                   leeway: .milliseconds(400))
        t.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            if self.idleBackoffEnabled,
               Self.secondsSinceUserInput() > self.userIdleThreshold {
                return
            }
            _ = self.extractNow(reason: "heartbeat")
        }
        t.resume()
        timer = t

        attachObserver()
        refresh(reason: "start", immediate: true)
    }

    public func stop() {
        running = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        timer?.cancel()
        timer = nil
        lock.lock(); pendingRefresh?.cancel(); pendingRefresh = nil; lock.unlock()
        if Thread.isMainThread {
            detachObserver()
        } else {
            DispatchQueue.main.async { [weak self] in self?.detachObserver() }
        }
    }

    deinit {
        running = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        timer?.cancel()
        pendingRefresh?.cancel()
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(obs), .commonModes)
        }
    }

    // MARK: - Serving

    /// Whether a cached tree may be served, given how old it is and how long
    /// ago the user last scrolled and clicked.
    ///
    /// A scroll or a click after the tree was read means the screen may no
    /// longer look like the tree: rows moved, a pane changed, a sheet opened.
    /// None of that raises an AX notification the observer can hear, and a
    /// solid ring drawn where a button used to be is the worst answer the
    /// coach can give. A warm walk costs 1–21 ms, so re-reading is cheap.
    public static func shouldServe(ageMs: Double, maxAgeMs: Double,
                                   msSinceLastScroll: Double,
                                   msSinceLastClick: Double) -> Bool {
        guard ageMs >= 0, ageMs <= maxAgeMs else { return false }
        return msSinceLastScroll > ageMs && msSinceLastClick > ageMs
    }

    private static func msSinceLastEvent(_ type: CGEventType) -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type) * 1000
    }

    private func servable(for pid: pid_t?) -> AXTreeSnapshot? {
        lock.lock(); let cached = entry; lock.unlock()
        guard let cached, let pid, cached.snapshot.pid == pid else { return nil }
        let click = min(Self.msSinceLastEvent(.leftMouseUp),
                        Self.msSinceLastEvent(.rightMouseUp))
        guard Self.shouldServe(ageMs: cached.ageMs, maxAgeMs: maxServeAgeMs,
                               msSinceLastScroll: Self.msSinceLastEvent(.scrollWheel),
                               msSinceLastClick: click) else { return nil }
        return cached.snapshot
    }

    /// The current tree. Serves the cache when it is fresh enough, otherwise
    /// pays for a synchronous extraction rather than handing back stale
    /// geometry — pointing confidently at where a button used to be is worse
    /// than being slow.
    public func tree() -> AXTreeSnapshot? {
        let pid = resolveTarget()?.processIdentifier
        if let warm = servable(for: pid) {
            lock.lock(); warmCount += 1; lock.unlock()
            return warm
        }
        return onQueue { [self] in
            // A walk that was in flight when we asked may have just produced
            // exactly what we need.
            if let warm = servable(for: pid) {
                lock.lock(); warmCount += 1; lock.unlock()
                return warm
            }
            if let pid, recentlyFailed(pid) { return nil }
            lock.lock(); coldCount += 1; lock.unlock()
            return extractNow(reason: "on demand")
        }
    }

    /// A synchronous read that ignores the cache's age, for callers that know
    /// the screen has just changed: the recorder's after-state, and the
    /// menu's "Refresh Tree Now".
    @discardableResult
    public func refreshNow() -> AXTreeSnapshot? {
        onQueue { [self] in
            lock.lock(); failedPID = 0; lock.unlock()
            return extractNow(reason: "refresh now")
        }
    }

    /// Drop the cached tree, so nothing from before this call is served
    /// again, and schedule a fresh read. For events that make every cached
    /// coordinate or gate decision suspect without any AX notification: a
    /// display arrangement change, an exclusion rule change. Callers that
    /// need the new tree at once follow this with `refreshNow()`.
    public func invalidate() {
        lock.lock()
        entry = nil
        failedPID = 0
        let live = running
        lock.unlock()
        if live { refresh(reason: "invalidated", immediate: true) }
    }

    public var cachedEntry: Entry? {
        lock.lock(); defer { lock.unlock() }
        return entry
    }

    private func onQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return work() }
        return queue.sync(execute: work)
    }

    private func recentlyFailed(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return failedPID == pid && Mono.msSince(failedAtNs) < failureBackoffMs
    }

    // MARK: - Refresh

    @objc private func appActivated(_ note: Notification) {
        // Our own activation is not a focus change worth reacting to; it just
        // means the user summoned us.
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return
        }
        attachObserver()
        refresh(reason: "focus change", immediate: true)
    }

    /// Coalesces bursts on the trailing edge. Stage Manager and window
    /// animations fire AX events in storms; re-walking a tree on each one
    /// would cost more than the cache saves, but dropping the last event of a
    /// burst would leave the cache holding geometry from before a resize or
    /// drag ended.
    private func refresh(reason: String, immediate: Bool = false) {
        let now = Mono.nowNs()
        lock.lock()
        // Something happened in the app; a failed walk is worth retrying.
        failedPID = 0
        pendingRefresh?.cancel()
        if pendingRefresh == nil { burstStartNs = now }
        let waited = Mono.ms(from: burstStartNs, to: now)
        let delayMs = (immediate || waited >= refreshMaxWaitMs) ? 0 : refreshDebounceMs
        refreshSeq += 1
        let mySeq = refreshSeq
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.refreshSeq == mySeq { self.pendingRefresh = nil }
            self.lock.unlock()
            guard self.running else { return }
            _ = self.extractNow(reason: reason)
        }
        pendingRefresh = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delayMs / 1000, execute: work)
    }

    /// Runs on `queue` only.
    @discardableResult
    private func extractNow(reason: String = "on demand") -> AXTreeSnapshot? {
        guard let app = resolveTarget() else { return nil }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier

        if let check = exclusionCheck {
            // 1. The bundle ID alone, before any AX call on the app.
            if let why = check(bundleID, nil) {
                refuse(pid: pid, reason: why)
                return nil
            }
            // 2. The window title, before the walk. The window server's title
            //    needs no AX call but is withheld without Screen Recording
            //    permission, so the focused window's AXTitle — one attribute
            //    of an app whose bundle is allowed — is checked as well.
            //    Failing open on a nil title would make every title rule
            //    inert for a user who has only granted Accessibility.
            let titles = [WindowServer.frontWindowTitle(pid: pid),
                          AXExtractor.focusedWindowTitle(pid: pid,
                                                         messagingTimeout: limits.messagingTimeout)]
            for title in titles.compactMap({ $0 }) {
                if let why = check(bundleID, title) {
                    refuse(pid: pid, reason: why)
                    return nil
                }
            }
        }

        lock.lock()
        let force = !forcedPIDs.contains(pid)
        forcedPIDs.insert(pid)
        lock.unlock()

        let snapshot: AXTreeSnapshot
        do {
            snapshot = try AXExtractor.windowTree(
                pid: pid,
                appName: app.localizedName ?? "pid \(pid)",
                bundleID: bundleID, limits: limits, forceElectron: force
            )
        } catch {
            lock.lock()
            failedPID = pid
            failedAtNs = Mono.nowNs()
            // A failed re-read cannot vouch for the old geometry either: the
            // window may be mid-resize or gone. Serving it warm would point
            // confidently at where a control used to be.
            if entry?.snapshot.pid == pid { entry = nil }
            lock.unlock()
            return nil
        }

        // 3. Backstop: the walk read the window's own title. If the window
        //    switched to an excluded title between the check and the walk,
        //    the tree is dropped here, before it is cached or served.
        if let check = exclusionCheck, let why = check(bundleID, snapshot.windowTitle) {
            refuse(pid: pid, reason: why)
            return nil
        }

        lock.lock()
        entry = Entry(snapshot: snapshot, capturedAtNs: Mono.nowNs())
        exclusionReason = nil
        failedPID = 0
        refreshCount += 1
        let observing = observedPID == pid
        lock.unlock()

        // An app that was excluded when it came to the front has no observer;
        // attach one now that it is allowed.
        if !observing && running {
            DispatchQueue.main.async { [weak self] in self?.attachObserver() }
        }
        return snapshot
    }

    private func refuse(pid: pid_t, reason: String) {
        lock.lock()
        entry = nil
        exclusionReason = reason
        let observing = observedPID == pid
        lock.unlock()
        if observing {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let still = self.observedPID == pid; self.lock.unlock()
                if still { self.detachObserver() }
            }
        }
    }

    /// Seconds since the user last touched the machine, from the window
    /// server — no event tap needed. `kCGAnyInputEventType` is not a valid
    /// Swift enum case, so this takes the minimum over the input types that
    /// matter; any one of them recent means the user is here.
    static func secondsSinceUserInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown,
                                    .mouseMoved, .scrollWheel, .flagsChanged]
        return types.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
    }

    // MARK: - AXObserver

    /// Watches the frontmost app for the events that invalidate the cache.
    /// This layer never reads geometry — events only mean "the cache is
    /// stale", exactly the discipline WindowPet's Tier 2 settled on.
    ///
    /// The exclusion check runs first, on the bundle ID and the window
    /// server's title, before `AXUIElementCreateApplication` or any other AX
    /// call. An excluded app is never subscribed to, so it never sends the
    /// coach its focus changes. Main thread only.
    private func attachObserver() {
        guard let app = resolveTarget() else { detachObserver(); return }
        let pid = app.processIdentifier
        if let check = exclusionCheck,
           check(app.bundleIdentifier, WindowServer.frontWindowTitle(pid: pid)) != nil {
            detachObserver()
            return
        }
        lock.lock(); let already = observedPID == pid; lock.unlock()
        guard !already else { return }
        detachObserver()

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.1)

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AXCache>.fromOpaque(refcon).takeUnretainedValue()
            me.refresh(reason: "ax event")
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let created = obs else {
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var subscribed = false
        // Geometry and focus, plus the content changes that complete a lesson
        // step or follow a recorded click: a value, a title or a menu
        // changed, an element appeared or went away. A title change also
        // matters for privacy: a tab that switches to an excluded title is
        // re-checked straight away rather than at the next heartbeat.
        for note in [kAXWindowMovedNotification, kAXWindowResizedNotification,
                     kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification,
                     kAXFocusedUIElementChangedNotification, kAXValueChangedNotification,
                     kAXTitleChangedNotification, kAXMenuOpenedNotification,
                     kAXMenuClosedNotification, kAXCreatedNotification,
                     kAXUIElementDestroyedNotification] {
            if AXObserverAddNotification(created, appElement, note as CFString, refcon) == .success {
                subscribed = true
            }
        }
        guard subscribed else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(created), .commonModes)
        lock.lock()
        observer = created
        observedPID = pid
        lock.unlock()
    }

    /// Main thread only.
    private func detachObserver() {
        lock.lock()
        let obs = observer
        observer = nil
        observedPID = 0
        lock.unlock()
        if let obs {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(obs), .commonModes)
        }
    }

    public var statusLine: String {
        lock.lock(); defer { lock.unlock() }
        if let why = exclusionReason { return "excluded — \(why)" }
        guard let e = entry else { return "no tree cached" }
        return String(format: "%@ — %d nodes, %.0f ms old, %d refreshes, %d warm / %d cold",
                      e.snapshot.appName, e.snapshot.nodeCount, e.ageMs,
                      refreshCount, warmCount, coldCount)
    }
}
