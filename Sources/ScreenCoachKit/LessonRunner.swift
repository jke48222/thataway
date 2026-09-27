import AppKit
import ScreenCoachCore

/// Drives a lesson: point at the step, watch the tree, advance when done.
///
/// The watching is nearly free. `AXCache` already re-reads on AXObserver
/// notifications — window moved, focus changed, element changed — which are
/// exactly the events that accompany "the user did the thing". So this polls
/// the cache rather than installing observers of its own, and the poll is a
/// pure comparison against the tree as it looked when the step began.
///
/// Comparing against the step's *starting* tree rather than the previous poll
/// is the detail that makes it work. A change spread over several observer
/// events never looks like a change between consecutive polls — each one is
/// identical to the last — so a step that took a moment would never complete.
public final class LessonRunner {

    public private(set) var progress: LessonProgress?
    private let cache: AXCache
    private var stepStartTree: [AXNode] = []
    private var timer: DispatchSourceTimer?
    private var stepStartedAtNs: UInt64 = 0

    /// Fires whenever the visible step changes, including at the start and
    /// once more when the lesson finishes.
    public var onStep: ((LessonProgress, Step?) -> Void)?
    /// Fires when a step auto-advances, with how long it took the learner.
    public var onAdvance: ((Int, Double) -> Void)?

    /// Why the runner is waiting on the learner to say "next".
    public enum StallReason: Equatable {
        /// The step is `.manual`: nothing on screen says when it is done.
        case manualStep
        /// The step's completion was not seen within `stepTimeout`.
        case timedOut
    }

    /// Fires once per step when the runner cannot advance on its own, so the
    /// app can say "choose Next Step when you're done" instead of leaving
    /// the learner under a dimmed screen with no way forward. Call
    /// `advance()` from the app's Next Step action.
    public var onStall: ((LessonProgress, Step, StallReason) -> Void)?

    /// A step that never completes should not wait silently forever. After
    /// this the runner reports a stall — an honest "I can't tell, press Next
    /// when you're done" beats a lesson stuck on step 3 with no explanation.
    /// It keeps watching, so a late completion still advances.
    public var stepTimeout: TimeInterval = 120

    /// Whether the learner currently has to advance by hand.
    public private(set) var isStalled = false

    public init(cache: AXCache) {
        self.cache = cache
    }

    public var isRunning: Bool { progress != nil && !(progress?.isFinished ?? true) }

    public func start(_ lesson: Lesson) {
        let p = LessonProgress(lesson: lesson)
        progress = p
        beginCurrentStep()
        onStep?(p, p.current)
        reportManualStall()
        startWatching()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        progress = nil
        stepStartTree = []
        isStalled = false
    }

    /// Manual advance — for `.manual` steps, and for when the learner knows
    /// better than the tree does.
    public func advance() {
        guard var p = progress else { return }
        p.advance()
        progress = p
        if p.isFinished {
            timer?.cancel()
            timer = nil
            onStep?(p, nil)
            return
        }
        beginCurrentStep()
        onStep?(p, p.current)
        reportManualStall()
        if timer == nil { startWatching() }
    }

    public func back() {
        guard var p = progress else { return }
        p.back()
        progress = p
        beginCurrentStep()
        onStep?(p, p.current)
        reportManualStall()
        if timer == nil { startWatching() }
    }

    // MARK: - Watching

    private func beginCurrentStep() {
        stepStartTree = cache.tree()?.nodes ?? []
        stepStartedAtNs = Mono.nowNs()
        isStalled = false
    }

    private func reportManualStall() {
        guard let p = progress, let step = p.current, step.completion == .manual else { return }
        isStalled = true
        onStall?(p, step, .manualStep)
    }

    private func startWatching() {
        timer?.cancel()
        // 250 ms is comfortably faster than a person can complete a step and
        // slow enough to be invisible: the poll is a pure tree comparison
        // measured at well under a millisecond.
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(80))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard let p = progress, let rawStep = p.current else { return }

        let elapsed = Mono.msSince(stepStartedAtNs)
        if elapsed > stepTimeout * 1000, !isStalled {
            isStalled = true
            onStall?(p, rawStep, .timedOut)
        }

        // The cached tree, never a blocking walk: this runs on main four
        // times a second. The cache already refreshes on the AX events that
        // accompany "the user did the thing" (values, titles, menus,
        // elements appearing and going away), so it is current without the
        // runner paying for a walk — and an app with no window no longer
        // costs a failed 250 ms walk on every tick.
        guard let tree = cache.cachedEntry?.snapshot, !tree.nodes.isEmpty else { return }
        let now = tree.nodes
        let step = rawStep.resolved(appName: tree.appName)

        // A step whose starting tree was empty has nothing to compare against
        // — usually the app was mid-transition. Re-baseline instead of
        // comparing to nothing and completing spuriously.
        if stepStartTree.isEmpty {
            stepStartTree = now
            return
        }

        guard LessonEngine.isSatisfied(step.completion, target: step.target,
                                       before: stepStartTree, after: now)
        else { return }

        onAdvance?(p.stepNumber, elapsed)
        advance()
    }
}

/// The lessons that ship. Deliberately few and deliberately generic.
///
/// Per-app knowledge packs are the eventual shape, but a pack for an app the
/// user does not own is dead weight, and one written from memory rather than
/// from the app's real accessibility tree will name controls that do not
/// exist. These are the ones whose targets are named identically across
/// essentially every Mac app.
public enum BuiltInLessons {

    public static let all: [Lesson] = [preferences, findInApp]

    /// Settings lives in a menu named after the app — hence the `{app}`
    /// template. Step 1's completion works because of the extractor's menu
    /// gating: "Settings" enters the tree at the instant the menu opens, and
    /// not a moment before.
    ///
    /// Step 2's `elementDisappears` is the menu closing after the choice.
    /// Known caveat: if an app's settings window titles itself with the word
    /// "Settings", the label never fully vanishes and the step waits for the
    /// per-step timeout — most system apps title by pane name ("General"),
    /// so the common case advances cleanly.
    public static let preferences = Lesson(
        title: "Open this app's settings",
        steps: [
            Step(instruction: "Open the {app} menu — right next to the Apple menu",
                 target: "the {app} menu",
                 completion: .elementAppears("Settings")),
            Step(instruction: "Choose Settings",
                 target: "the Settings menu item",
                 completion: .elementDisappears("Settings")),
            Step(instruction: "That's the settings window — have a look around",
                 target: "the {app} Settings window",
                 completion: .manual),
        ]
    )

    public static let findInApp = Lesson(
        title: "Find something in this app",
        steps: [
            Step(instruction: "Open the Edit menu",
                 target: "the Edit menu",
                 completion: .elementAppears("Find")),
            Step(instruction: "Choose Find",
                 target: "the Find menu item",
                 completion: .elementAppears("the search field")),
            Step(instruction: "Type what you're looking for",
                 target: "the search field",
                 completion: .valueChanges("the search field")),
        ]
    )
}
