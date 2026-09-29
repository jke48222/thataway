// The promo film's scenes, played live on the stage for the recorder.
// Debug builds only.
//
// Rules the choreography keeps, because the film must show the product as it
// is: the pointer starts from wherever the person's mouse is; that mouse never
// moves on camera and nothing is ever clicked on camera. When a lesson or a
// Watch me recording needs the person to click, the scene marks a cut
// (`"event": "cut"`) and the next shot starts with the mouse where they
// clicked and the window already changed. The editor cuts there.
#if DEBUG

import AppKit
import SwiftUI
import ThatawayCore
import ThatawayKit

enum PromoScene: String, CaseIterable {
    case hero
    case uncertain
    case excluded
    case lesson
    case watchme

    var title: String {
        switch self {
        case .hero: return "The tree first, vision second"
        case .uncertain: return "It says when it is guessing"
        case .excluded: return "Excluded means never read"
        case .lesson: return "Lessons wait for you"
        case .watchme: return "Show it once with Watch me"
        }
    }

    var summary: String {
        switch self {
        case .hero:
            return "Option Space opens the bar; “the Share button” is typed and the shortlist re-ranks on every keystroke; Return closes the bar and the pointer arcs from the resting mouse to Share with a solid ring; it clears after 4.5 s, as the app's answer does."
        case .uncertain:
            return "“the access menu” is typed; the tree's best match (the Link access pop-up) is below the hit threshold, so the pointer lands with a dashed amber ring and the caption “Link access?”."
        case .excluded:
            return "A browser window titled “Online Banking” is in front. Option Space opens the bar with no tree behind it: the bar states that the window is excluded by a default title rule. No pointer."
        case .lesson:
            return "The Watch me lesson replays in Studio. Step 1 dims everything but Sharing. After a cut, step 2 flies from where the person clicked to Advanced Options…. After the next cut the Link Settings sheet is open and step 3 lights Require a passcode. After the last cut the switch is on, the mouse has moved off it, and the lesson ends."
        case .watchme:
            return "The menu bar item reads “Recording: 0 steps”; three cuts, each after one click in Studio, count it up to 3; cut; the Teach Me menu lists the saved recording; cut; replay starts at step 1."
        }
    }
}

@MainActor
final class PromoDirector {
    let stage: PromoStageView
    private(set) var marks: [[String: Any]] = []
    private var startedAt = Date()
    private var random = PromoRandom(seed: 0x7A7A_2026)
    private var caretTask: Task<Void, Never>?

    private var model: PromoStageModel { stage.model }

    init(stage: PromoStageView) {
        self.stage = stage
    }

    var elapsed: Double { Date().timeIntervalSince(startedAt) }

    private func mark(_ event: String, _ note: String? = nil) {
        var entry: [String: Any] = ["t": (elapsed * 1000).rounded() / 1000, "event": event]
        if let note { entry["note"] = note }
        marks.append(entry)
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Setup

    /// The first frame of each scene, shown while the recorder warms up.
    func prepare(_ scene: PromoScene) {
        stage.setMouse(PromoGeometry.mouseRest)
        switch scene {
        case .hero, .uncertain:
            model.studio = StudioState()
        case .excluded:
            model.showStudio = false
            model.showBrowser = true
            model.frontApp = PromoScript.browserName
        case .lesson:
            model.studio = PromoScript.recordingStart
        case .watchme:
            model.studio = PromoScript.recordingStart
            model.statusActivity = "Recording: 0 steps"
        }
    }

    /// Work that would stall the main thread mid-take, done before `go`.
    func warmUp(_ scene: PromoScene) async {
        // Let SwiftUI lay the desktop out before it is snapshotted.
        try? await Task.sleep(nanoseconds: 300_000_000)
        if [.hero, .uncertain, .excluded].contains(scene) { stage.prepareBar() }
    }

    func play(_ scene: PromoScene) async {
        startedAt = Date()
        mark("start")
        switch scene {
        case .hero: await ask(PromoScript.exactQuery)
        case .uncertain: await ask(PromoScript.uncertainQuery)
        case .excluded: await excluded()
        case .lesson: await lesson()
        case .watchme: await watchMe()
        }
        mark("end")
    }

    // MARK: Asking

    private func ask(_ query: String) async {
        let tree = PromoTreeBuilder.studio(model.studio)
        guard let answer = PromoPipeline.answer(query, tree: tree) else {
            PromoStage.fail("promo query “\(query)” has no answer")
        }
        await sleep(1.0)

        // Option Space, tapped: `summon` opens the bar listening, and the
        // key-up a moment later turns it into a typing turn.
        stage.presentBar(status: "Listening. Release to go · "
                         + PromoPipeline.summonStatus(tree: tree, treeAgeMs: PromoScript.treeAgeMs))
        stage.bar.showsCaret = true
        mark("summon")
        await sleep(0.16)
        stage.updateBar(status: "type a target, or hold ⌥Space to speak")
        blinkCaret()
        await sleep(0.6)

        mark("typing")
        for i in 1...query.count {
            let prefix = String(query.prefix(i))
            stopCaretBlink()
            stage.updateBar(query: prefix, suggestions: PromoPipeline.shortlist(prefix, tree: tree))
            let ch = query[query.index(query.startIndex, offsetBy: i - 1)]
            await sleep(ch == " " ? random.uniform(0.10, 0.15) : random.uniform(0.055, 0.105))
        }
        blinkCaret()
        mark("typed", query)
        // A person reads the shortlist before pressing Return; the film's
        // shot is already settled on the resting mouse by then.
        await sleep(1.0)

        // Return: the bar goes down first, then the pointer flies.
        stopCaretBlink()
        stage.dismissBar()
        mark("return")
        stage.point(at: answer.target, caption: answer.caption, exact: answer.exact)
        mark("flight", String(format: "%@ ring, “%@”, score %.2f",
                              answer.exact ? "solid" : "dashed amber", answer.caption, answer.score))
        await sleep(0.55)
        mark("landed")
        await sleep(4.5 - 0.55)
        stage.hidePointer()
        mark("dismissed")
        await sleep(1.0)
    }

    // MARK: Privacy

    private func excluded() async {
        guard let refusal = PromoPipeline.refusal(appName: PromoScript.browserName,
                                                  bundleID: PromoScript.browserBundleID,
                                                  windowTitle: PromoScript.browserTitle) else {
            PromoStage.fail("the default exclusions no longer match “\(PromoScript.browserTitle)”")
        }
        await sleep(1.0)
        stage.presentBar(status: refusal)
        stage.bar.showsCaret = true
        blinkCaret()
        mark("refused", refusal)
        await sleep(3.8)
        stopCaretBlink()
        stage.dismissBar()
        mark("dismissed", "Escape")
        await sleep(1.0)
    }

    // MARK: Lessons

    private func target(of step: Step, in state: StudioState) -> (rect: CGRect, exact: Bool) {
        let tree = PromoTreeBuilder.studio(state)
        guard let best = AXResolver.rank(query: step.target, in: tree.nodes,
                                         windowBounds: tree.windowBounds, limit: 1).first else {
            PromoStage.fail("lesson step “\(step.target)” resolves to nothing")
        }
        return (best.node.bounds.cg, best.score >= AXResolver.hitThreshold)
    }

    /// The learner's click, between shots: move the mouse there, change the
    /// window, and check with `LessonEngine` that the step completes.
    private func learnerClicks(_ index: Int, progress: inout LessonProgress, animated: Bool) async {
        let click = PromoScript.recordingClicks[index]
        guard let step = progress.current else { return }
        let before = PromoTreeBuilder.studio(model.studio).nodes
        mark("cut", "the person clicks \(step.instruction.replacingOccurrences(of: "Click ", with: ""))")
        stage.setMouse(click.point)
        if animated {
            withAnimation(.easeOut(duration: 0.24)) { model.studio = click.after }
        } else {
            model.studio = click.after
        }
        let after = PromoTreeBuilder.studio(model.studio).nodes
        guard LessonEngine.isSatisfied(step.completion, target: step.target, before: before, after: after) else {
            PromoStage.fail("lesson step \(progress.stepNumber) would not advance")
        }
        progress.advance()
    }

    private func showStep(_ progress: LessonProgress) {
        guard let step = progress.current else { return }
        let t = target(of: step, in: model.studio)
        stage.teach(t.rect, caption: progress.caption(appName: StudioLayout.appName),
                    step: progress.stepNumber, exact: t.exact, animated: true)
        mark("step", "\(progress.stepNumber)/\(progress.totalSteps) \(t.exact ? "solid" : "dashed") ring")
    }

    private func lesson() async {
        var progress = LessonProgress(lesson: PromoScript.recordedLesson)
        await sleep(1.0)
        showStep(progress)
        await sleep(2.6)

        await learnerClicks(0, progress: &progress, animated: false)
        await sleep(0.35)
        showStep(progress)
        await sleep(2.9)

        await learnerClicks(1, progress: &progress, animated: true)
        await sleep(0.45)
        showStep(progress)
        await sleep(2.6)

        await learnerClicks(2, progress: &progress, animated: true)
        // Still inside the cut: the person moves their mouse off the switch
        // they just flipped, so the last shot has one arrow on it, the drawn
        // pointer, until the dim lifts.
        stage.setMouse(PromoGeometry.mouseParked)
        mark("parked", "the mouse is off the switch")
        await sleep(0.8)
        // `onStep(nil)`: the lesson is done and the overlay comes down.
        stage.hidePointer()
        mark("done", progress.caption(appName: StudioLayout.appName))
        await sleep(1.6)
    }

    // MARK: Watch me

    private func watchMe() async {
        await sleep(1.2)
        for (i, click) in PromoScript.recordingClicks.enumerated() {
            let n = i + 1
            mark("cut", "the author clicks \(PromoScript.recordedLesson.steps[i].instruction.replacingOccurrences(of: "Click ", with: ""))")
            stage.setMouse(click.point)
            withAnimation(.easeOut(duration: 0.24)) { model.studio = click.after }
            model.statusActivity = "Recording: \(n) step\(n == 1 ? "" : "s")"
            await sleep(1.35)
        }

        // Stop Recording & Save, then the menu opened again: the recording is
        // listed under Teach Me….
        mark("cut", "Stop Recording & Save; the menu is opened again")
        model.statusActivity = nil
        model.savedLessons = [PromoScript.recordingTitle]
        model.highlightedSavedLesson = PromoScript.recordingTitle
        model.teachMenuOpen = true
        stage.setMouse(PromoStatusMenu.savedRowCenter(0))
        mark("saved", PromoScript.recordingTitle)
        await sleep(2.8)

        // Chosen: the menu closes and step 1 flies from the menu to Sharing,
        // in a window reset to where the recording began.
        mark("cut", "the saved lesson is chosen")
        model.teachMenuOpen = false
        model.studio = PromoScript.recordingStart
        await sleep(0.3)
        showStep(LessonProgress(lesson: PromoScript.recordedLesson))
        await sleep(2.8)
    }

    // MARK: Caret

    private func blinkCaret() {
        caretTask?.cancel()
        stage.bar.setCaretVisible(true)
        caretTask = Task { @MainActor [weak self] in
            var on = true
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 530_000_000)
                guard !Task.isCancelled else { return }
                on.toggle()
                self?.stage.bar.setCaretVisible(on)
            }
        }
    }

    private func stopCaretBlink() {
        caretTask?.cancel()
        caretTask = nil
        stage.bar.setCaretVisible(true)
    }
}

/// A small deterministic generator for the typing rhythm (SplitMix64).
struct PromoRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(next() >> 11) / Double(1 << 53)
    }
}

#endif
