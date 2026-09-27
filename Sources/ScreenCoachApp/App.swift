import AppKit
import ScreenCoachCore
import ScreenCoachKit

/// The coach.
///
/// Hold the shortcut and say what you are looking for — or tap it and type —
/// and a cursor flies to the exact control. The accessibility tree answers
/// first, in about a millisecond; Holo1.5 runs locally only when the tree
/// cannot see the control; speech in and out are on-device. No cloud, no
/// network, nothing persisted.
///
/// That is already a different product from the state of the art: pure-vision
/// grounders are right 58% of the time on dense professional UIs, and are
/// confidently wrong the rest. This one either knows, says it is guessing, or
/// declines — and it never looks at an excluded app at all.
@main
final class ScreenCoachApp: NSObject, NSApplicationDelegate {

    private let cache = AXCache()
    private let overlay = OverlayController()
    private let commandBar = CommandBar()
    private var hotkey: HotKeyTap?
    private var statusItem: NSStatusItem?
    private var lastTrace = LatencyTrace()

    private let exclusions = ExclusionStore()
    private let voice = Voice()
    private lazy var lessons = LessonRunner(cache: cache)
    private lazy var recorder = WorkflowRecorder(cache: cache)
    private let lessonStore = LessonStore()
    private var teachSubmenu: NSMenu?
    private var recordItem: NSMenuItem?
    private var visionStatusItem: NSMenuItem?
    private var privacyStatusItem: NSMenuItem?
    /// Set on the first vision attempt. The sidecar is only looked at (and
    /// only shut down) once something has asked for it.
    private var visionUsed = false
    /// Hold versus tap, classified on the event tap's hardware timestamps.
    private var ptt = PushToTalk()
    /// Ends a hold whose key-up never arrives, so the microphone is bounded.
    private var holdExpiry: DispatchWorkItem?
    /// Whether the recogniser produced any words during the current hold.
    private var heardThisHold = false
    /// The turn the microphone was opened for. Transcripts from any other
    /// turn are dropped rather than typed into, or acted on in, a newer one.
    private var listeningTurn: UInt64 = 0
    /// Asked once per launch, and only from a bundle that carries the usage
    /// strings — asking without them is a TCC crash, not a prompt.
    private var voicePermissionAsked = false
    private var accessibilityPromptOffered = false

    /// Every turn advances this; late work checks it before touching the
    /// screen. See `TurnClock`.
    private let turns = TurnClock()
    /// Vision runs off the main thread and strictly serially — one 5.6 GB
    /// model, one query at a time.
    private let visionQueue = DispatchQueue(label: "coach.vision", qos: .userInitiated)
    /// The one queued vision request. A newer query cancels it, so a run of
    /// misses cannot stack up several multi-second jobs behind the model.
    private var pendingVision: DispatchWorkItem?

    /// A one-shot answer is on screen. While it is, the lesson layer waits;
    /// when it ends, the lesson layer is restored rather than everything
    /// being ordered out.
    private var oneShotVisible = false
    /// The one-shot answer on screen is a provisional "checking…" waiting on
    /// vision.
    private var provisionalVisible = false
    private var oneShotEnd: DispatchWorkItem?

    /// The lesson step as last drawn, so the step is redrawn whenever its
    /// target moves, reappears, or the overlay was cleared — and only then.
    private struct LessonFrame: Equatable {
        let stepNumber: Int
        let rect: ScreenRect
        let confident: Bool

        func matches(_ other: LessonFrame) -> Bool {
            stepNumber == other.stepNumber && confident == other.confident
                && rect.screenIndex == other.rect.screenIndex
                && abs(rect.cg.minX - other.rect.cg.minX) < 1
                && abs(rect.cg.minY - other.rect.cg.minY) < 1
                && abs(rect.cg.width - other.rect.cg.width) < 1
                && abs(rect.cg.height - other.rect.cg.height) < 1
        }
    }
    private var lessonDrawn: LessonFrame?
    private var lessonWaitingForTarget = false
    private var lessonRenderTimer: DispatchSourceTimer?
    private var spokenStepKey: String?

    /// Short progress text in the menu bar, for states where the command bar
    /// is deliberately not on screen (vision running, a lesson step waiting
    /// for its target). The owner lets one clear its own text only.
    private enum ActivityOwner { case vision, lesson }
    private var activityOwner: ActivityOwner?

    /// How long a one-shot answer stays up.
    private static let answerSeconds: TimeInterval = 4.5
    /// How long a provisional answer may wait for vision before it is taken
    /// down anyway. First model load can take minutes; a pointer left up
    /// that long with no context is worse than none.
    private static let provisionalSeconds: TimeInterval = 60
    private lazy var grounding = GroundingService(
        serverScript: Self.toolsDirectory.appendingPathComponent("holo_server.py"),
        modelPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("models/holo1.5-7b-4bit").path
    )

    /// Tools live beside the app when bundled, and beside the package when
    /// running from `swift build`. Try the bundle first, then the source tree.
    private static var toolsDirectory: URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Tools")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScreenCoachApp
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Tools")
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = ScreenCoachApp()
        app.delegate = delegate
        // Accessory, not regular: no Dock icon, and summoning the coach never
        // steals frontmost status from the app being taught.
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--lessontest") {
            runLessonTest()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--idlebench") {
            let seconds = CommandLine.arguments[safe: i + 1].flatMap(Int.init) ?? 60
            runIdleBench(seconds: seconds,
                         forceActive: CommandLine.arguments.contains("--force-active"))
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            let query = CommandLine.arguments[safe: i + 1] ?? "the close button"
            let app = CommandLine.arguments.firstIndex(of: "--app")
                .flatMap { CommandLine.arguments[safe: $0 + 1] }
            runSelfTest(query: query, appName: app)
            return
        }

        // The privacy gate goes in before anything can read a tree — the
        // menu's "Point at Something…" works before Accessibility is granted
        // and before the cache starts, and it must not be an ungated path.
        wirePrivacyGate()
        buildStatusItem()
        overlay.rebuildForCurrentDisplays()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.displaysChanged() }

        commandBar.onQueryChanged = { [weak self] q in self?.preview(q) }
        commandBar.onSubmit = { [weak self] q in self?.resolveAndPoint(q, spoken: false) }
        // Escape, and clicking away from the bar, end the turn the same way.
        commandBar.onCancel = { [weak self] in self?.cancelTurn() }

        guard AXExtractor.isTrusted else {
            promptForAccessibility()
            return
        }
        startServices()
    }

    /// Stop the vision sidecar with the app, so a 5.6 GB model is not left
    /// resident after Quit.
    func applicationWillTerminate(_ notification: Notification) {
        if visionUsed { grounding.shutdown() }
    }

    private func wirePrivacyGate() {
        cache.exclusionCheck = { [weak self] bundleID, title in
            guard let self else { return nil }
            let v = self.exclusions.check(bundleID: bundleID, windowTitle: title)
            return v.excluded ? (v.reason ?? "excluded") : nil
        }
        // A warm tree is served for up to five seconds without re-asking the
        // gate, so a rule change must drop it now, not at the next heartbeat.
        exclusions.onChange = { [weak self] _ in
            DispatchQueue.main.async { self?.privacyRulesChanged() }
        }
    }

    private var servicesStarted = false

    private func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true
        cache.start()
        wireVoice()
        wireLessons()

        let tap = HotKeyTap(binding: .optionSpace)
        tap.onHotKey = { [weak self] eventNs in
            DispatchQueue.main.async { self?.summon(at: eventNs, listen: true) }
        }
        // The key-up's own hardware timestamp, not "whenever main gets to
        // it": main may have been busy with a cold tree read for the whole
        // hold, and the hold's length is the tap-versus-speak decision.
        tap.onHotKeyUp = { [weak self] upNs in
            DispatchQueue.main.async { self?.releaseHold(at: upNs) }
        }
        do { try tap.start() } catch {
            NSLog("ScreenCoach: hotkey tap failed — \(error)")
        }
        hotkey = tap

        // Ask for Speech and Microphone now, up front. Nothing else ever
        // moves them out of "not determined", and until they are asked the
        // system does not even list the app in Privacy settings — so a hold
        // would stay silent forever.
        requestVoicePermissionsIfUndetermined()
    }

    // MARK: - Invalidation

    /// Screen geometry changed: the overlay's panels, the tree's CG
    /// coordinates, and its screen indices are all from the old arrangement.
    private func displaysChanged() {
        overlay.rebuildForCurrentDisplays()
        // Rebuilding discarded every pointer, including a one-shot answer.
        oneShotEnd?.cancel()
        oneShotEnd = nil
        oneShotVisible = false
        provisionalVisible = false
        // Making another display primary moves the CG origin without moving
        // any window, so no AX event fires; drop the cached tree and re-read
        // so indices and rects are attributed against the new arrangement.
        cache.invalidate()
        if servicesStarted { cache.refreshNow() }
        lessonDrawn = nil
        renderLesson()
    }

    /// The exclusion list changed on disk.
    private func privacyRulesChanged() {
        // Drop the cached tree first, whether or not the services are
        // running: the menu's "Point at Something…" can have read one.
        cache.invalidate()
        guard servicesStarted else { return }
        // Re-read through the gate: a newly excluded frontmost app's tree is
        // dropped here rather than served warm for up to five more seconds.
        cache.refreshNow()
        if commandBar.isVisible { preview(commandBar.query) }
        lessonDrawn = nil
        renderLesson()
    }

    // MARK: - Teaching

    private func wireLessons() {
        lessons.onStep = { [weak self] progress, step in
            guard let self else { return }
            guard let step else {
                self.stopLessonRendering()
                self.overlay.hide()
                self.voice.speak("That's it — \(progress.lesson.title) done.")
                NSLog("ScreenCoach: lesson finished")
                return
            }
            self.showStep(progress, step)
        }
        lessons.onAdvance = { [weak self] number, ms in
            NSLog(String(format: "ScreenCoach: step %d completed by the user in %.1f s",
                         number, ms / 1000))
            _ = self
        }
        // A step the runner cannot see finish must say how to move on, or
        // the learner is left under a dimmed screen with no way forward. A
        // manual step already says so as part of its spoken instruction (see
        // `showStep`); speaking again here would cut that sentence off.
        lessons.onStall = { [weak self] progress, _, reason in
            guard let self else { return }
            switch reason {
            case .manualStep:
                NSLog("ScreenCoach: step \(progress.stepNumber) is manual — waiting for Next Step")
            case .timedOut:
                NSLog("ScreenCoach: step \(progress.stepNumber) not seen to finish — waiting for Next Step")
                self.voice.speak("I can't tell whether that's done. "
                                 + "Choose Next Step from the menu to continue.")
                self.setActivity("Step \(progress.stepNumber): choose Next Step to continue",
                                 owner: .lesson)
            }
        }
    }

    /// A new step: say it, and draw it.
    ///
    /// The scrim is the affordance that turns pointing into teaching: during a
    /// step the rest of the screen recedes and the control you need is the
    /// only lit thing. A one-shot answer never does this — dimming the whole
    /// screen to answer a quick question would be obnoxious.
    private func showStep(_ progress: LessonProgress, _ rawStep: Step) {
        // Say each step once. Drawing is idempotent and re-evaluated on every
        // tick; speech is not, and a re-announced step would talk over itself.
        let key = "\(progress.lesson.title)#\(progress.stepNumber)"
        if key != spokenStepKey {
            spokenStepKey = key
            let appName = cache.cachedEntry?.snapshot.appName ?? "this app"
            var line = rawStep.resolved(appName: appName).instruction
            if rawStep.completion == .manual {
                line += " Choose Next Step from the menu when you're done."
            }
            voice.speak(line)
        }
        lessonDrawn = nil
        lessonWaitingForTarget = false
        startLessonRendering()
        renderLesson()
    }

    /// The step on screen is a function of state, re-evaluated four times a
    /// second rather than drawn once at step start: a target that appears
    /// late (the menu that the previous step opened), a window that moves, a
    /// display change, or a one-shot answer that borrowed the overlay all
    /// leave a stale or missing highlight otherwise.
    private func startLessonRendering() {
        guard lessonRenderTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(80))
        t.setEventHandler { [weak self] in self?.renderLesson() }
        t.resume()
        lessonRenderTimer = t
    }

    private func stopLessonRendering() {
        spokenStepKey = nil
        lessonRenderTimer?.cancel()
        lessonRenderTimer = nil
        lessonDrawn = nil
        lessonWaitingForTarget = false
        clearActivity(.lesson)
    }

    private func renderLesson() {
        guard lessons.isRunning, let progress = lessons.progress,
              let rawStep = progress.current else {
            if lessonRenderTimer != nil { stopLessonRendering() }
            return
        }
        // A one-shot answer has the overlay; the lesson comes back when it ends.
        guard !oneShotVisible else { return }

        let tree = cache.tree()
        let best = tree.flatMap { t in
            AXResolver.rank(query: rawStep.resolved(appName: t.appName).target,
                            in: t.nodes, windowBounds: extent(of: t), limit: 1).first
        }
        guard let best else {
            // The target is not on screen yet — normal right after a step
            // that opened a menu. Take the previous step's highlight down
            // (leaving it lit tells the learner to repeat what they just
            // did) and show where they are somewhere visible: the command
            // bar was dismissed when the lesson started.
            if lessonDrawn != nil || !lessonWaitingForTarget {
                overlay.hide()
                lessonDrawn = nil
                lessonWaitingForTarget = true
                setActivity(progress.caption, owner: .lesson)
            }
            return
        }

        let frame = LessonFrame(stepNumber: progress.stepNumber,
                                rect: reattributed(best.node.bounds),
                                confident: best.score >= AXResolver.hitThreshold)
        if let drawn = lessonDrawn, drawn.matches(frame) { return }
        // Fly in for a new step (or a forced redraw, which clears
        // lessonDrawn); a target that merely moved, such as a window being
        // dragged, is followed without replaying the flight every frame.
        overlay.teach(step: frame.rect,
                      caption: progress.caption,
                      stepNumber: progress.stepNumber,
                      confidence: frame.confident ? .exact : .uncertain,
                      animated: lessonDrawn?.stepNumber != progress.stepNumber)
        lessonDrawn = frame
        if lessonWaitingForTarget {
            lessonWaitingForTarget = false
            clearActivity(.lesson)
        }
    }

    @objc private func startLesson(_ sender: NSMenuItem) {
        guard let lesson = BuiltInLessons.all[safe: sender.tag] else { return }
        endTurnForLesson()
        stopLessonRendering()
        lessons.start(lesson)
    }

    /// A lesson takes over the overlay: whatever the last query was doing,
    /// including a vision call still in flight, is finished.
    private func endTurnForLesson() {
        beginNewTurn()
        stopListening()
        oneShotEnd?.cancel()
        oneShotEnd = nil
        oneShotVisible = false
        provisionalVisible = false
        commandBar.dismiss()
    }

    @objc private func startSavedLesson(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              let lesson = lessonStore.load(url) else { return }
        // A recording is app-specific in fact even though its steps are
        // semantic — warn rather than block when replayed elsewhere, because
        // re-grounding against a different app is allowed to work and
        // sometimes does (menus and toolbars share vocabulary).
        if let wanted = lesson.bundleID, let current = cache.tree()?.bundleID,
           wanted != current {
            voice.speak("This was recorded in a different app. I'll try anyway.")
        }
        endTurnForLesson()
        stopLessonRendering()
        lessons.start(lesson)
    }

    // MARK: - Recording

    @objc private func toggleRecording() {
        if recorder.isRecording {
            stopRecordingAndSave()
            return
        }
        recorder.onStep = { [weak self] recorded, count in
            self?.commandBar.setStatus("recorded \(count): \(recorded.clickedLabel)")
            NSLog("ScreenCoach: recorded step \(count) — \(recorded.step.target)")
        }
        recorder.onSkipped = { reason in
            NSLog("ScreenCoach: click skipped — \(reason)")
        }
        do {
            try recorder.start()
            recordItem?.title = "Stop Recording & Save"
            voice.speak("Recording. Click through the steps, then stop from the menu.")
        } catch {
            NSLog("ScreenCoach: recorder failed — \(error)")
        }
    }

    private func stopRecordingAndSave() {
        recordItem?.title = "Record a Workflow"
        guard let lesson = recorder.finish() else {
            voice.speak("Nothing recorded.")
            return
        }
        do {
            let url = try lessonStore.save(lesson)
            voice.speak("Saved \(lesson.steps.count) steps.")
            NSLog("ScreenCoach: workflow saved to \(url.path)")
        } catch {
            NSLog("ScreenCoach: save failed — \(error)")
        }
    }

    /// Next Step: the way forward from a manual step, from a step the
    /// watcher could not see finish, and for a learner who knows better than
    /// the tree does.
    @objc private func nextStep() {
        guard lessons.isRunning else { return }
        lessons.advance()
    }

    @objc private func previousStep() {
        guard lessons.isRunning else { return }
        lessons.back()
    }

    @objc private func stopLesson() {
        lessons.stop()
        stopLessonRendering()
        overlay.hide()
    }

    // MARK: - Voice

    private func wireVoice() {
        voice.onPartial = { [weak self] text in
            guard let self, self.turns.isCurrent(self.listeningTurn) else { return }
            // Live transcript goes straight into the same field typing uses,
            // so the two input paths converge before anything downstream has
            // to care which one produced the query.
            if !text.isEmpty { self.heardThisHold = true }
            self.commandBar.setQuery(text)
            self.preview(text)
        }
        voice.onFinal = { [weak self] text, sttMs in
            guard let self else { return }
            // An utterance belongs to the turn that opened the microphone. If
            // the user has since cancelled or asked something else, acting on
            // it would point at a target nobody is asking about any more.
            guard self.turns.isCurrent(self.listeningTurn) else {
                NSLog("ScreenCoach: dropped a transcript from an earlier turn")
                return
            }
            self.lastTrace.record(.stt, ms: sttMs)
            self.resolveAndPoint(text, spoken: true)
        }
        voice.onState = { [weak self] state in
            guard let self, self.turns.isCurrent(self.listeningTurn) else { return }
            self.commandBar.setStatus(state)
        }
    }

    /// Whether this process can ask for Speech and Microphone at all. The
    /// request needs the usage strings in Info.plist; an unbundled `swift
    /// build` binary has none, and asking from it kills the process.
    private var canAskForVoicePermission: Bool { Voice.canAskForPermission }

    private var voicePermissionUndetermined: Bool { Voice.permissionsUndetermined }

    private func requestVoicePermissionsIfUndetermined() {
        guard !voicePermissionAsked, voicePermissionUndetermined else { return }
        guard canAskForVoicePermission else {
            NSLog("ScreenCoach: voice needs the bundled app (no usage strings) — typing only")
            return
        }
        voicePermissionAsked = true
        voice.requestPermissions { [weak self] availability in
            guard let self else { return }
            NSLog("ScreenCoach: voice permissions — \(Voice.permissionSummary)")
            if self.commandBar.isVisible, !self.voice.isListening {
                self.commandBar.setStatus(self.voiceNote(for: availability) ?? "Voice ready — hold ⌥Space to speak")
            }
        }
    }

    /// Why a hold will not listen, in words the status line can show. Nil
    /// when voice is ready.
    private func voiceNote(for availability: Voice.Availability) -> String? {
        switch availability {
        case .ready:
            return nil
        case .needsPermission(let what):
            if voicePermissionUndetermined && canAskForVoicePermission {
                return "Allow \(what) access to speak — type for now"
            }
            if !canAskForVoicePermission {
                return "Voice needs the bundled app — type instead"
            }
            return "\(what) permission is off — type instead, or allow it in "
                 + "System Settings › Privacy & Security"
        case .unavailable(let why):
            return "Voice unavailable (\(why)) — type instead"
        }
    }

    /// Open the microphone for the current turn. Returns a note for the
    /// status line when it could not.
    private func startListening() -> String? {
        let availability = voice.availability
        if case .needsPermission = availability {
            // Ask at the moment of need too, in case the launch-time request
            // never ran (the grant arrived later, or it was declined as a
            // dialog rather than decided).
            requestVoicePermissionsIfUndetermined()
        }
        if let note = voiceNote(for: availability) { return note }
        listeningTurn = turns.current
        heardThisHold = false
        voice.begin()
        guard voice.isListening else { return "The microphone didn't start — type instead" }
        armHoldExpiry()
        return nil
    }

    /// The microphone must not outlive the turn. Every path that ends a turn
    /// — Escape, Return, focus loss, a lesson starting — comes through here.
    private func stopListening() {
        holdExpiry?.cancel()
        holdExpiry = nil
        ptt.reset()
        if voice.isListening { voice.cancel() }
    }

    private func armHoldExpiry() {
        holdExpiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .finishUtterance = self.ptt.expire(atNs: Mono.nowNs()), self.voice.isListening {
                NSLog("ScreenCoach: hold outlived its limit — closing the microphone")
                self.voice.end()
            }
        }
        holdExpiry = work
        let seconds = Double(ptt.maxHoldNs) / 1e9 + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Hold to speak, tap to type.
    ///
    /// The distinction is made on release rather than by a timer, so a hold
    /// that turns out to be short still delivers whatever was said. Under the
    /// threshold with nothing heard, the bar simply stays open for typing —
    /// which is also the graceful path when the microphone is unavailable.
    private func releaseHold(at upNs: UInt64) {
        let action = ptt.keyUp(atNs: upNs, heardText: heardThisHold)
        holdExpiry?.cancel()
        holdExpiry = nil
        guard voice.isListening, turns.isCurrent(listeningTurn) else { return }
        switch action {
        case .cancelToTyping:
            voice.cancel()
            commandBar.setStatus("type a target, or hold ⌥Space to speak")
        case .finishUtterance:
            voice.end()
        case .startListening, .restartListening, .ignore:
            break
        }
    }

    // MARK: - The turn

    /// Open the bar for a new turn.
    ///
    /// `listen` is true only for the hotkey, whose key-up closes the
    /// microphone. The menu item has no key to release, so it is typing only
    /// — otherwise it would open a microphone nothing ever closes.
    private func summon(at eventNs: UInt64, listen: Bool) {
        var voiceNote: String?
        if listen {
            switch ptt.keyDown(atNs: eventNs) {
            case .ignore:
                return   // auto-repeat of a hold already in progress
            case .restartListening:
                // The last key-up was lost. Close that capture before
                // starting this one, or begin() would refuse.
                holdExpiry?.cancel()
                if voice.isListening { voice.cancel() }
            default:
                break
            }
        } else {
            stopListening()
        }

        beginNewTurn()
        lastTrace = LatencyTrace()
        lastTrace.begin(.hotkeyToFrame, at: eventNs)

        // Start capturing before anything that can block the main thread.
        // A cold tree read after switching apps costs 45–220 ms, and every
        // one of those milliseconds would otherwise be clipped from the
        // front of the utterance — usually the word that names the target.
        if listen { voiceNote = startListening() }

        // The tree is usually warm — the payoff for the speculative
        // extraction Phase 0 proved mandatory — and reading it costs about a
        // millisecond instead of the 45–220 ms a cold walk would.
        lastTrace.begin(.axExtract)
        let tree = cache.tree()
        lastTrace.end(.axExtract)
        lastTrace.end(.hotkeyToFrame)

        guard let tree else {
            stopListening()
            commandBar.present(status: explainMissingTree())
            return
        }
        var status = String(
            format: "%@ · %d controls · tree %.0f ms old",
            tree.appName, tree.labelledCount, cache.cachedEntry?.ageMs ?? 0
        )
        if voice.isListening {
            status = "Listening — release to go · " + status
        } else if let voiceNote {
            status = voiceNote + " · " + status
        }
        commandBar.present(status: status)
    }

    /// Why there is no tree, rather than a generic "no window" that reads
    /// like a bug: missing permission and the privacy gate are both
    /// deliberate states the user can do something about.
    private func explainMissingTree() -> String {
        if !AXExtractor.isTrusted {
            if !accessibilityPromptOffered {
                accessibilityPromptOffered = true
                AXExtractor.requestPermission()
            }
            return "Accessibility access is off — allow Screen Coach in "
                 + "System Settings › Privacy & Security › Accessibility."
        }
        if let why = cache.lastExclusionReason {
            let me = ProcessInfo.processInfo.processIdentifier
            let front = NSWorkspace.shared.frontmostApplication
            let name = front.flatMap { $0.processIdentifier == me ? nil : $0.localizedName }
                ?? "this app"
            return "Not looking at \(name) — it is excluded (\(why))."
        }
        return "No accessible window in front."
    }

    /// Every turn starts here. Whatever the previous turn left in flight is
    /// abandoned: its queued vision job is cancelled (a running one finds its
    /// turn gone and discards its answer), and a provisional "checking…"
    /// pointer that will now never be refined is taken down.
    @discardableResult
    private func beginNewTurn() -> UInt64 {
        let turn = turns.advance()
        pendingVision?.cancel()
        pendingVision = nil
        clearActivity(.vision)
        if provisionalVisible { endOneShot() }
        return turn
    }

    /// Escape, or a click away from the bar.
    private func cancelTurn() {
        beginNewTurn()
        stopListening()
        commandBar.dismiss()
        // Only a one-shot answer is ours to take down; a lesson step stays.
        if oneShotVisible { endOneShot() }
    }

    /// Live shortlist as the user types. Cheap enough to run on every
    /// keystroke — the resolver is a lexical scan measured at 0.067 ms.
    private func preview(_ query: String) {
        guard query.count >= 2, let tree = cache.cachedEntry?.snapshot else {
            commandBar.showSuggestions([])
            return
        }
        let ranked = AXResolver.rank(query: query, in: tree.nodes,
                                     windowBounds: extent(of: tree), limit: 3)
        commandBar.showSuggestions(ranked.map { c in
            String(format: "%.2f  %@", c.score, c.node.semanticLabel.prefix(64) as CVarArg)
        })
    }

    private func resolveAndPoint(_ query: String, spoken: Bool) {
        // Typed Return while a hold is still open, or a final transcript:
        // either way the microphone's job for this turn is done.
        stopListening()
        let turn = beginNewTurn()

        guard let tree = cache.tree() else {
            notify(explainMissingTree())
            return
        }
        let bounds = extent(of: tree)

        lastTrace.begin(.axResolve)
        let ranked = AXResolver.rank(query: query, in: tree.nodes,
                                     windowBounds: bounds, limit: 3)
        lastTrace.end(.axResolve)
        // Down before anything else, and it stays down while vision runs:
        // the bar sits in the middle of the display that is about to be
        // captured, and the model should see the app, not our question.
        commandBar.dismiss()

        let axCandidate = ranked.first.map {
            Fusion.AXCandidate(bounds: $0.node.bounds, score: $0.score,
                               label: $0.node.title ?? $0.node.roleDescription
                                      ?? $0.node.humanRole)
        }
        let axOnly = Fusion.decide(ax: axCandidate, vision: nil,
                                   axHitThreshold: AXResolver.hitThreshold)

        // Does this even need vision? Measured at ~1.7 ms per image token, so
        // the answer is no whenever the tree already answered well — checking
        // a confident hit would trade two seconds for a second opinion that is
        // right 58% of the time.
        let wantsVision = Fusion.needsVision(
            axScore: axCandidate?.score, axHitThreshold: AXResolver.hitThreshold,
            labelledFraction: tree.labelledFraction
        )

        guard wantsVision else {
            present(axOnly, query: query, tree: tree, spoken: spoken)
            return
        }

        // A cheap early refusal on what the tree says. It is not the gate —
        // the tree can be seconds old by the time a capture would happen —
        // so the authoritative check runs again on the vision queue,
        // immediately before the capture. See `captureRefusal`.
        let verdict = exclusions.check(bundleID: tree.bundleID, windowTitle: tree.windowTitle)
        // The tree's title can be seconds old; a tab that has just switched
        // to an excluded title is caught here from the window server, so the
        // note says "not captured" instead of "checking…".
        let freshRefusal = verdict.excluded ? nil
            : ScreenGrab.frontWindowExclusion(pid: tree.pid, exclusions: exclusions.current)
        guard !verdict.excluded, freshRefusal == nil else {
            let why = verdict.reason ?? freshRefusal ?? "excluded"
            if axOnly != nil {
                present(axOnly, query: query, tree: tree, spoken: spoken,
                        note: "not captured — \(why)")
            } else {
                notify("Nothing in \(tree.appName)'s accessibility tree matches “\(query)”, "
                       + "and the screen was not captured — \(why).")
            }
            return
        }

        // Show the tree's answer immediately rather than making the user wait
        // on the model. The pointer is already flying while vision runs, and
        // the ring is upgraded or downgraded when the second opinion lands.
        // With no tree answer at all there is nothing to fly to yet: say
        // "looking" in the menu bar and keep quiet until vision decides,
        // rather than announcing "nothing matches" and then contradicting it.
        if let axOnly {
            present(axOnly, query: query, tree: tree, spoken: spoken,
                    note: "checking…", holdFor: Self.provisionalSeconds)
            provisionalVisible = true
        } else {
            setActivity("Looking for “\(query)”…", owner: .vision)
            CommandBar.announce("Looking for \(query)")
        }

        let job = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Skip work whose turn is already over — it would only occupy
            // the one model while the user waits on a newer query.
            guard self.turns.isCurrent(turn) else { return }
            let outcome = self.runVision(query: query, tree: tree, ax: axCandidate, turn: turn)
            DispatchQueue.main.async {
                self.finishVision(outcome, turn: turn, query: query, tree: tree,
                                  ax: axCandidate, provisional: axOnly, spoken: spoken)
            }
        }
        pendingVision = job
        visionQueue.async(execute: job)
    }

    private struct VisionOutcome {
        var candidate: Fusion.VisionCandidate?
        /// Why there is no candidate, when that is worth telling the user.
        var whyNot: String?
        var ms: Double?
    }

    /// Vision landed, on main. Only the turn that asked may use it.
    private func finishVision(_ outcome: VisionOutcome, turn: UInt64, query: String,
                              tree: AXTreeSnapshot, ax: Fusion.AXCandidate?,
                              provisional: Fusion.Decision?, spoken: Bool) {
        guard turns.isCurrent(turn) else {
            NSLog("ScreenCoach: dropped a vision answer for “\(query)” — a newer turn owns the screen")
            return
        }
        pendingVision = nil
        clearActivity(.vision)
        if let ms = outcome.ms { lastTrace.record(.visionGround, ms: ms) }

        guard let decision = Fusion.decide(ax: ax, vision: outcome.candidate,
                                           axHitThreshold: AXResolver.hitThreshold) else {
            // Both came back empty — only now is "nothing matches" true.
            var text = "Nothing in \(tree.appName) matches “\(query)”."
            if let why = outcome.whyNot { text += " (\(why))" }
            notify(text)
            return
        }
        present(decision, query: query, tree: tree, spoken: spoken, replacing: provisional)
    }

    /// Capture, aim, ground. Runs off the main thread; everything it needs
    /// about the target was captured in `tree` before it started.
    private func runVision(query: String, tree: AXTreeSnapshot,
                           ax: Fusion.AXCandidate?, turn: UInt64? = nil) -> VisionOutcome {
        visionUsed = true
        guard grounding.startIfNeeded() else {
            NSLog("ScreenCoach: \(grounding.statusLine)")
            return VisionOutcome(whyNot: grounding.statusLine)
        }
        // First use can spend minutes loading the model. The turn may have
        // ended meanwhile, and a capture nobody will look at must not happen.
        if let turn, !turns.isCurrent(turn) { return VisionOutcome() }

        // The privacy gate, at the moment of capture. What the tree said
        // seconds ago is not what is on the display now.
        let target = extent(of: tree)
        if let refusal = captureRefusal(for: tree, displayIndex: target.screenIndex) {
            NSLog("ScreenCoach: capture refused — \(refusal)")
            return VisionOutcome(whyNot: "screen not captured — \(refusal)")
        }
        // ScreenGrab applies the rules to the frame itself: excluded apps,
        // windows with excluded titles and the coach's own overlay are cut
        // out before any pixel exists, and the target's front window title
        // is re-read from the window server once more right before capture.
        // Nil means capture failed or that last check refused.
        guard let shot = ScreenGrab.display(containing: target,
                                            exclusions: exclusions.current,
                                            targetPID: tree.pid) else {
            return VisionOutcome(whyNot: "screen not captured")
        }

        // Aim the crop with the tree even though the tree could not answer.
        // Phase 0 measured this at full-frame accuracy for a third of the
        // latency; the sidecar test above showed 1337 ms versus 9676 ms on the
        // same target.
        let hint = AXResolver.cropHint(query: query, in: tree.nodes, windowBounds: target)
        let cropPixels = hint.isWholeWindow ? nil : CGRect(
            x: (hint.rect.cg.minX - shot.origin.x) * shot.scale,
            y: (hint.rect.cg.minY - shot.origin.y) * shot.scale,
            width: hint.rect.cg.width * shot.scale,
            height: hint.rect.cg.height * shot.scale
        )

        let started = Mono.nowNs()
        let result = grounding.ground(
            image: shot.image, query: query, cropPixels: cropPixels,
            screenIndex: shot.screenIndex, displayScale: shot.scale,
            displayOrigin: shot.origin
        )
        let ms = Mono.msSince(started)
        guard let result else {
            return VisionOutcome(whyNot: "the vision model found nothing", ms: ms)
        }
        NSLog(String(format: "ScreenCoach: vision %.0f ms ttft, %d tokens%@",
                     result.ttftMs, result.imageTokens,
                     cropPixels == nil ? " (full frame)" : " (AX-aimed crop)"))
        return VisionOutcome(candidate: Fusion.VisionCandidate(point: result.point), ms: ms)
    }

    /// The capture-time privacy gate. Returns why the display must not be
    /// captured at all, or nil when it may be.
    ///
    /// Other excluded apps and windows on the display do not refuse the
    /// capture: `ScreenGrab` removes them from the frame. What is refused
    /// here is a capture whose premise has gone — a different app came to
    /// the front, the target's own front window is now excluded, or the
    /// display the tree was on no longer exists.
    private func captureRefusal(for tree: AXTreeSnapshot, displayIndex: Int) -> String? {
        var refusal: String?
        let rules = exclusions.current
        let check = {
            let me = ProcessInfo.processInfo.processIdentifier
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != me, front.processIdentifier != tree.pid {
                refusal = "\(front.localizedName ?? "another app") came to the front"
                return
            }
            if let why = ScreenGrab.frontWindowExclusion(pid: tree.pid, exclusions: rules) {
                refusal = "\(tree.appName) is showing an excluded window (\(why))"
                return
            }
            if DisplaySpace.current().display(at: displayIndex) == nil {
                refusal = "the display changed"
            }
        }
        // On main, where the workspace is current; the self test calls this
        // from main already.
        if Thread.isMainThread { check() } else { DispatchQueue.main.sync(execute: check) }
        return refusal
    }

    /// Put an answer on screen.
    ///
    /// - `holdFor`: how long it stays up. A provisional answer waiting on
    ///   vision stays until the refinement lands (or a generous cap), rather
    ///   than vanishing at 4.5 s while the model is still working.
    /// - `replacing`: the provisional answer this refines. When the target
    ///   and ring are unchanged the pointer is left where it is instead of
    ///   flying in from the mouse a second time.
    private func present(_ decision: Fusion.Decision?, query: String,
                         tree: AXTreeSnapshot, spoken: Bool, note: String? = nil,
                         holdFor: TimeInterval = ScreenCoachApp.answerSeconds,
                         replacing provisional: Fusion.Decision? = nil) {
        guard let decision else {
            notify("Nothing in \(tree.appName) matches “\(query)”.")
            return
        }
        var caption = decision.label
        if decision.confidence == .uncertain { caption += "?" }
        if let note { caption += "  ·  \(note)" }

        let sameTarget = provisional.map { $0.target == decision.target } ?? false
        provisionalVisible = false
        let confidence: PointerLayer.Confidence = decision.confidence == .exact ? .exact : .uncertain
        if sameTarget && oneShotVisible
            && overlay.update(caption: caption, confidence: confidence) {
            // Same control: the ring settles in place (new caption, new
            // confidence) instead of flying in from the mouse a second time.
            scheduleOneShotEnd(after: holdFor)
        } else {
            lastTrace.begin(.pointerStart)
            overlay.point(at: reattributed(decision.target), caption: caption,
                          confidence: confidence, dismissAfter: holdFor + 0.5)
            lastTrace.end(.pointerStart)
            oneShotVisible = true
            scheduleOneShotEnd(after: holdFor)
        }

        if let why = decision.explanation { NSLog("ScreenCoach: \(why)") }
        NSLog("ScreenCoach: “\(query)” → \(decision.label) [\(decision.source.rawValue)]")

        // Speak only when spoken to. A voice that answers typed input is
        // startling in a shared office, and note never speaks — a spoken
        // "checking…" would be interrupted by the real answer a beat later.
        // VoiceOver users get the caption either way: without it a typed
        // query's answer is purely visual.
        if spoken && note == nil {
            voice.speak(spokenAnswer(for: decision))
        } else if note == nil {
            CommandBar.announce(spokenAnswer(for: decision))
        }
    }

    /// The one-shot answer's lifetime is owned here, not by the overlay's
    /// own timer, so that when it ends during a lesson the lesson's step is
    /// put back instead of every panel being ordered out.
    private func scheduleOneShotEnd(after seconds: TimeInterval) {
        oneShotEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endOneShot() }
        oneShotEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func endOneShot() {
        oneShotEnd?.cancel()
        oneShotEnd = nil
        oneShotVisible = false
        provisionalVisible = false
        if lessons.isRunning {
            lessonDrawn = nil
            renderLesson()
        } else {
            overlay.hide()
        }
    }

    /// Belt and braces for a rect whose screen index outlived its display
    /// arrangement: if the index no longer names a display the rect is on,
    /// attribute it again from its CG geometry.
    private func reattributed(_ r: ScreenRect) -> ScreenRect {
        let space = DisplaySpace.current()
        if let d = space.display(at: r.screenIndex), d.cgFrame.intersects(r.cg) { return r }
        guard let index = space.index(bestOverlapping: r.cg) else { return r }
        return ScreenRect(cg: r.cg, screenIndex: index)
    }

    // MARK: - Menu bar activity

    private func setActivity(_ text: String, owner: ActivityOwner) {
        guard let button = statusItem?.button else { return }
        let limit = 36
        let short = text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
        button.title = " " + short
        button.imagePosition = .imageLeading
        button.setAccessibilityValue(text)
        activityOwner = owner
    }

    private func clearActivity(_ owner: ActivityOwner) {
        guard activityOwner == owner, let button = statusItem?.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.setAccessibilityValue(nil)
        activityOwner = nil
    }

    /// The reference extent is the union of the tree's node bounds, never a
    /// window frame — Phase 0 found apps whose AX window element excludes its
    /// own children, and apps whose one window is three `SCWindow`s.
    private func extent(of tree: AXTreeSnapshot) -> ScreenRect {
        let union = tree.nodes.reduce(CGRect.null) { $0.union($1.bounds.cg) }
        if union.isNull {
            return tree.windowBounds ?? ScreenRect(cg: .zero, screenIndex: 0)
        }
        return ScreenRect(cg: union,
                          screenIndex: tree.windowBounds?.screenIndex
                              ?? DisplaySpace.current().index(bestOverlapping: union) ?? 0)
    }

    private func logTiming(query: String, best: AXResolver.Candidate, tree: AXTreeSnapshot) {
        let ax = lastTrace.samples(for: .axExtract)
        let resolve = lastTrace.samples(for: .axResolve)
        NSLog(String(format:
            "ScreenCoach: “%@” → %@ (%.2f) | tree %d nodes, read %.2f ms, resolve %.3f ms",
            query, best.node.title ?? best.node.role, best.score,
            tree.nodeCount, ax.p50, resolve.p50))
    }

    /// Exercises the teaching loop headlessly.
    ///
    /// Auto-advance is the claim that separates this from a tutorial video, so
    /// it gets verified rather than demoed: build a lesson whose completion
    /// condition is something this process can cause on its own, run the
    /// watcher, and check it fires. No screenshots, no human.
    private func runLessonTest() {
        guard AXExtractor.isTrusted else { print("Accessibility not granted."); exit(2) }
        cache.exclusionCheck = { [weak self] b, t in
            guard let self else { return nil }
            let v = self.exclusions.check(bundleID: b, windowTitle: t)
            return v.excluded ? (v.reason ?? "excluded") : nil
        }
        cache.start()
        overlay.rebuildForCurrentDisplays()
        Thread.sleep(forTimeInterval: 0.6)

        guard let tree = cache.tree(), !tree.nodes.isEmpty else {
            print("No accessible frontmost window."); exit(3)
        }
        print("App        \(tree.appName) — \(tree.nodeCount) nodes")

        // Two synthetic trees standing in for before/after, so the engine is
        // exercised against this app's real labels rather than fixtures.
        let before = tree.nodes
        guard let sample = before.first(where: { $0.isActionable && $0.hasLabel }),
              let label = sample.title ?? sample.roleDescription else {
            print("No labelled actionable element to build a step from."); exit(4)
        }
        let query = "the \(label) button"
        print("Step       “\(query)”")

        var after = before
        if let idx = after.firstIndex(where: { $0.id == sample.id }) {
            // Move it: the engine treats a moved control as evidence a panel
            // opened around it.
            let moved = AXNode(
                id: sample.id, parentID: sample.parentID, depth: sample.depth,
                role: sample.role, subrole: sample.subrole, title: sample.title,
                roleDescription: sample.roleDescription, helpText: sample.helpText,
                valueText: (sample.valueText ?? "") + "-changed",
                identifier: sample.identifier, enabled: sample.enabled,
                bounds: sample.bounds)
            after[idx] = moved
        }

        let unchanged = LessonEngine.isSatisfied(.targetChanges, target: query,
                                                 before: before, after: before)
        let changed = LessonEngine.isSatisfied(.targetChanges, target: query,
                                               before: before, after: after)
        print("Detect     unchanged tree → \(unchanged ? "COMPLETE (wrong)" : "pending (correct)")")
        print("Detect     value changed  → \(changed ? "COMPLETE (correct)" : "pending (WRONG)")")

        // Now the live runner, with a lesson whose only step is manual, to
        // confirm it renders and does not spuriously auto-advance.
        var advanced = false
        lessons.onAdvance = { _, _ in advanced = true }
        lessons.onStep = { [weak self] progress, step in
            guard let step else { print("Lesson     finished"); return }
            print("Lesson     showing \(progress.caption)")
            guard let self, let t = self.cache.tree() else { return }
            if let best = AXResolver.rank(query: step.target, in: t.nodes,
                                          windowBounds: self.extent(of: t), limit: 1).first {
                self.overlay.teach(step: best.node.bounds, caption: progress.caption,
                                   stepNumber: progress.stepNumber,
                                   confidence: best.score >= AXResolver.hitThreshold
                                       ? .exact : .uncertain)
                print(String(format: "Render     scrim + badge %d on %@ (score %.2f)",
                             progress.stepNumber, best.node.title ?? best.node.role, best.score))
            }
        }
        lessons.start(Lesson(title: "Self test", steps: [
            Step(instruction: "Look at this control", target: query, completion: .manual),
        ]))

        // "Watch me" mode, verified without a human clicking: hit-test a real
        // element's own centre (what a click there would resolve to), build
        // the step a recording would produce, round-trip it through disk, and
        // replay the loaded copy. The file is the artifact that travels to
        // another machine, so the file is what gets replayed.
        var watchOK = true
        let centre = CGPoint(x: sample.bounds.cg.midX, y: sample.bounds.cg.midY)
        if let hit = WorkflowInference.hitTest(centre, in: before) {
            let same = hit.id == sample.id
            print("HitTest    centre of “\(label)” → \(hit.title ?? hit.role) "
                  + (same ? "(exact)" : "(different element — acceptable if nested)"))
        } else {
            print("HitTest    FAILED — centre of a labelled element resolved to nothing")
            watchOK = false
        }
        if let recordedQuery = WorkflowInference.semanticQuery(for: sample, in: before) {
            print("Record     synthesized “\(recordedQuery)”")
            let store = LessonStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("coach-lessontest-\(UUID().uuidString)"))
            let lesson = Lesson(title: "Recorded self test", bundleID: tree.bundleID, steps: [
                Step(instruction: "Click \(label)", target: recordedQuery, completion: .manual),
            ])
            if let url = try? store.save(lesson), let loaded = store.load(url) {
                let ranked = AXResolver.rank(query: loaded.steps[0].target, in: before,
                                             windowBounds: extent(of: tree), limit: 1)
                if let best = ranked.first, best.score >= AXResolver.hitThreshold {
                    print(String(format: "Replay     loaded from disk, re-grounded at %.2f — %@",
                                 best.score, best.node.title ?? best.node.role))
                } else {
                    print("Replay     FAILED — saved query did not re-ground")
                    watchOK = false
                }
                try? FileManager.default.removeItem(at: store.directory)
            } else {
                print("Replay     FAILED — save/load round trip broke")
                watchOK = false
            }
        } else {
            print("Record     FAILED — no query for a labelled element")
            watchOK = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            print("Watcher    \(advanced ? "auto-advanced (WRONG for a .manual step)" : "held on the manual step (correct)")")
            self.lessons.advance()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                print("Manual     advance → \(self.lessons.isRunning ? "still running" : "lesson complete")")
                exit(unchanged || !changed || !watchOK ? 1 : 0)
            }
        }
    }

    // MARK: - Idle bench

    /// What does the coach cost when nobody is using it?
    ///
    /// WindowPet's discipline, inherited: an always-running accessory app has
    /// to know its own idle draw, because "small" background costs are how a
    /// laptop's battery dies of a thousand cuts. The dominant term here is
    /// the AXCache heartbeat — a full tree walk of the frontmost app every
    /// three seconds, forever — so this starts exactly the services the real
    /// app runs at idle (cache, hotkey tap, exclusion gate) and reads its own
    /// rusage over the window. No overlay, no voice, no vision: those all
    /// cost zero until summoned.
    private func runIdleBench(seconds: Int, forceActive: Bool) {
        guard AXExtractor.isTrusted else { print("Accessibility not granted."); exit(2) }
        cache.exclusionCheck = { [weak self] b, t in
            guard let self else { return nil }
            let v = self.exclusions.check(bundleID: b, windowTitle: t)
            return v.excluded ? (v.reason ?? "excluded") : nil
        }
        cache.idleBackoffEnabled = !forceActive
        cache.start()
        let tap = HotKeyTap(binding: .optionSpace)
        try? tap.start()
        hotkey = tap

        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let u = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
            return u + sys
        }

        // Let startup settle so the measurement is steady state, not launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
            let cpu0 = cpuSeconds()
            let refreshes0 = cache.refreshes
            let t0 = Mono.nowNs()
            print("Measuring \(seconds)s of idle"
                  + (forceActive ? " (backoff disabled — active-user mode)" : "")
                  + " over \(cache.cachedEntry?.snapshot.appName ?? "no app")…")

            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [self] in
                let wall = Mono.msSince(t0) / 1000
                let cpu = cpuSeconds() - cpu0
                let beats = cache.refreshes - refreshes0
                print(String(format: "CPU        %.2f%% of one core (%.3fs CPU over %.1fs wall)",
                             cpu / wall * 100, cpu, wall))
                print("Refreshes  \(beats) tree walks in the window")
                print(String(format: "Memory     %.1f MB resident", residentMB()))
                exit(0)
            }
        }
    }

    private func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1e6 : 0
    }

    // MARK: - Self test

    /// End-to-end without a human: warm the cache, resolve a real query
    /// against the frontmost app, print every coordinate the pointer will
    /// use, and draw it. Prints geometry rather than taking a screenshot —
    /// this app exists to look at whatever the user has open, so verifying it
    /// should not mean capturing their screen.
    private func runSelfTest(query: String, appName: String?) {
        guard AXExtractor.isTrusted else {
            print("Accessibility not granted — cannot self-test.")
            exit(2)
        }
        overlay.rebuildForCurrentDisplays()
        cache.exclusionCheck = { [weak self] bundleID, title in
            guard let self else { return nil }
            let v = self.exclusions.check(bundleID: bundleID, windowTitle: title)
            return v.excluded ? (v.reason ?? "excluded") : nil
        }
        cache.start()

        // Targeting a named app is a test affordance, not a product feature:
        // it lets the pipeline be verified against an app that is not
        // frontmost, which matters because some apps stop vending a focused
        // window the moment they lose focus.
        if let appName {
            guard let match = NSWorkspace.shared.runningApplications.first(where: {
                ($0.localizedName ?? "").lowercased().contains(appName.lowercased())
            }) else { print("No running app matching “\(appName)”."); exit(5) }
            cache.pin(to: match.processIdentifier)
            print("Pinned to \(match.localizedName ?? "?") (pid \(match.processIdentifier))")
        }

        print("Warming the tree…")
        var warmTimes: [Double] = []
        for _ in 0..<5 {
            let t0 = Mono.nowNs()
            _ = cache.tree()
            warmTimes.append(Mono.msSince(t0))
            usleep(120_000)
        }
        if let why = cache.lastExclusionReason {
            print("Privacy    EXCLUDED — \(why)")
            print("           No tree read, no frame captured. Nothing to point at.")
            exit(0)
        }
        guard let tree = cache.tree() else {
            // Say *why*, not just that it failed.
            let me = ProcessInfo.processInfo.processIdentifier
            print("No accessible window. Diagnosing:")
            print("  trusted: \(AXExtractor.isTrusted)   self pid: \(me)")
            print("  frontmost: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")"
                  + " pid \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)")
            for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular && !app.isTerminated {
                let name = app.localizedName ?? "?"
                // The diagnostic obeys the same gate as the product: an
                // excluded app's tree is not read, not even to count it.
                let verdict = exclusions.check(bundleID: app.bundleIdentifier, windowTitle: nil)
                if verdict.excluded {
                    print("  \(name): excluded — not read (\(verdict.reason ?? "excluded"))")
                    continue
                }
                do {
                    let t = try AXExtractor.windowTree(
                        pid: app.processIdentifier, appName: name,
                        bundleID: app.bundleIdentifier)
                    print("  \(name): \(t.nodeCount) nodes OK")
                } catch {
                    print("  \(name): \(error)")
                }
            }
            exit(3)
        }
        let serve = LatencySamples(stage: .axExtract, values: warmTimes)

        print(String(format: "App        %@ — %d nodes, %d labelled, %d actionable",
                     tree.appName, tree.nodeCount, tree.labelledCount, tree.actionableCount))
        print(String(format: "Cache      serve p50 %.3f ms, p90 %.3f ms (%d warm / %d cold)",
                     serve.p50, serve.p90, cache.servedWarm, cache.servedCold))

        let bounds = extent(of: tree)
        let t0 = Mono.nowNs()
        let ranked = AXResolver.rank(query: query, in: tree.nodes,
                                     windowBounds: bounds, limit: 3)
        let resolveMs = Mono.msSince(t0)
        print(String(format: "Resolve    %.3f ms for “%@”", resolveMs, query))

        if ranked.isEmpty {
            // Not a failure — this is precisely the case the vision fallback
            // exists for, so the self-test must carry on into it rather than
            // stopping where the accessibility path stops.
            print("Resolve    no accessibility match — this is the AX-miss path")
        }
        for (i, c) in ranked.enumerated() {
            print(String(format: "  %d. %.2f  %@  cg=(%.0f,%.0f %.0f×%.0f) screen %d",
                         i + 1, c.score, c.node.semanticLabel.prefix(52) as CVarArg,
                         c.node.bounds.cg.minX, c.node.bounds.cg.minY,
                         c.node.bounds.cg.width, c.node.bounds.cg.height,
                         c.node.bounds.screenIndex))
        }

        if let best = ranked.first {
        // Show the CG→AppKit→panel-local chain explicitly. This is the
        // conversion that puts the pointer on the wrong monitor when it is
        // wrong, so the self-test prints it rather than trusting it.
        let space = DisplaySpace.current()
        let ak = space.appKitRect(fromCG: best.node.bounds.cg)
        print(String(format: "Convert    cg(%.0f,%.0f) → appkit(%.0f,%.0f)  [primary height %.0f]",
                     best.node.bounds.cg.minX, best.node.bounds.cg.minY,
                     ak.minX, ak.minY, space.primaryHeight))
        if let screen = NSScreen.screens[safe: best.node.bounds.screenIndex] {
            print(String(format: "           → panel-local(%.0f,%.0f) on screen %d %@",
                         ak.minX - screen.frame.minX, ak.minY - screen.frame.minY,
                         best.node.bounds.screenIndex,
                         screen.frame.contains(CGPoint(x: ak.midX, y: ak.midY))
                            ? "✓ inside screen" : "✗ OUTSIDE SCREEN"))
        }
        }

        // Route the self-test through the same fusion policy the product uses,
        // so what it prints is what a real query would do rather than a
        // parallel code path that can drift.
        let axCandidate = ranked.first.map {
            Fusion.AXCandidate(
                bounds: $0.node.bounds, score: $0.score,
                label: $0.node.title ?? $0.node.roleDescription ?? $0.node.humanRole
            )
        }
        let wantsVision = Fusion.needsVision(
            axScore: axCandidate?.score, axHitThreshold: AXResolver.hitThreshold,
            labelledFraction: tree.labelledFraction
        )
        let verdict = exclusions.check(bundleID: tree.bundleID, windowTitle: tree.windowTitle)
        print("Privacy    \(verdict.excluded ? "EXCLUDED — \(verdict.reason ?? "")" : "allowed") "
              + "(\(exclusions.statusLine))")
        switch voice.availability {
        case .ready(let onDevice):
            print("Voice      ready — recognition \(onDevice ? "ON-DEVICE" : "SERVER-BACKED")")
        case .needsPermission(let what):
            print("Voice      \(what) permission not granted yet (\(Voice.permissionSummary))")
        case .unavailable(let why):
            print("Voice      unavailable — \(why)")
        }
        print("Route      \(wantsVision ? "vision fallback would run" : "accessibility only — vision not needed")")

        var visionCandidate: Fusion.VisionCandidate?
        if wantsVision && !verdict.excluded && CommandLine.arguments.contains("--vision") {
            print("Vision     loading model…")
            let outcome = runVision(query: query, tree: tree, ax: axCandidate)
            visionCandidate = outcome.candidate
            if let v = visionCandidate {
                print(String(format: "           click cg(%.0f,%.0f) screen %d",
                             v.point.cg.x, v.point.cg.y, v.point.screenIndex))
            } else {
                print("           unavailable — \(outcome.whyNot ?? grounding.statusLine)")
            }
        }

        guard let decision = Fusion.decide(ax: axCandidate, vision: visionCandidate,
                                           axHitThreshold: AXResolver.hitThreshold) else {
            print("No decision."); exit(4)
        }
        print("Fusion     \(decision.source.rawValue) → "
              + "\(decision.confidence == .exact ? "exact — solid ring" : "uncertain — dashed ring")")
        if let why = decision.explanation { print("           \(why)") }

        overlay.point(at: decision.target,
                      caption: decision.label + (decision.confidence == .exact ? "" : "?"),
                      confidence: decision.confidence == .exact ? .exact : .uncertain,
                      dismissAfter: 2.5)
        print("Pointing for 3s…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { exit(0) }
    }

    // MARK: - Chrome

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Screen Coach"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let status = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        // Vision and privacy state, so a sidecar failure (with its stderr)
        // and an exclusions file that could not be read are visible.
        let visionStatus = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        visionStatus.isEnabled = false
        menu.addItem(visionStatus)
        visionStatusItem = visionStatus
        let privacyStatus = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        privacyStatus.isEnabled = false
        menu.addItem(privacyStatus)
        privacyStatusItem = privacyStatus
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Point at Something…  ⌥Space",
                                action: #selector(summonFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh Tree Now",
                                action: #selector(refreshNow), keyEquivalent: ""))
        menu.addItem(.separator())
        let teach = NSMenuItem(title: "Teach Me…", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, lesson) in BuiltInLessons.all.enumerated() {
            let item = NSMenuItem(title: lesson.title, action: #selector(startLesson(_:)),
                                  keyEquivalent: "")
            item.tag = i
            item.target = self
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let next = NSMenuItem(title: "Next Step", action: #selector(nextStep), keyEquivalent: "")
        next.target = self
        sub.addItem(next)
        let previous = NSMenuItem(title: "Previous Step", action: #selector(previousStep),
                                  keyEquivalent: "")
        previous.target = self
        sub.addItem(previous)
        sub.addItem(.separator())
        let record = NSMenuItem(title: "Record a Workflow",
                                action: #selector(toggleRecording), keyEquivalent: "")
        record.target = self
        sub.addItem(record)
        recordItem = record
        let stop = NSMenuItem(title: "Stop Teaching", action: #selector(stopLesson),
                              keyEquivalent: "")
        stop.target = self
        sub.addItem(stop)
        teach.submenu = sub
        teachSubmenu = sub
        menu.addItem(teach)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Screen Coach",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        for i in menu.items where i.action != nil && i.action != #selector(NSApplication.terminate(_:)) {
            i.target = self
        }
        // Refresh the status line each time the menu opens rather than on a
        // timer — nobody is reading it while it is closed.
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // Typing only: a menu click has no key-up to close a microphone.
    @objc private func summonFromMenu() { summon(at: Mono.nowNs(), listen: false) }

    /// Re-read now, even when the cached tree is under five seconds old —
    /// that is the case the user reaches for this item in.
    @objc private func refreshNow() {
        cache.refreshNow()
        if commandBar.isVisible { preview(commandBar.query) }
    }

    /// What the coach says out loud. Short, and it carries the same
    /// uncertainty the ring does — a confident sentence over a dashed ring
    /// would undo the whole point of drawing the dashes.
    private func spokenAnswer(for decision: Fusion.Decision) -> String {
        switch decision.confidence {
        case .exact:
            return decision.source == .corroborated
                ? "Here. \(decision.label)."
                : "Here's \(decision.label)."
        case .uncertain:
            switch decision.source {
            case .vision:
                return "I couldn't find a clear match in the accessibility tree, "
                     + "so this is my best guess."
            case .conflicted:
                return "I think it's \(decision.label), but I'm not certain."
            default:
                return "Maybe \(decision.label). I'm not sure."
            }
        }
    }

    private func notify(_ text: String) {
        commandBar.present(status: text)
    }

    private func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Screen Coach needs Accessibility access"
        alert.informativeText = """
        The coach reads the accessibility tree of whatever app is in front so \
        it can point at exact controls. That is the whole product — without \
        this permission there is nothing to point at.

        Nothing is recorded, stored, or sent anywhere.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            AXExtractor.requestPermission()
            // Grant-while-running has no notification; poll for it.
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                guard AXExtractor.isTrusted else { return }
                t.invalidate()
                self?.startServices()
            }
        } else {
            NSApp.terminate(nil)
        }
    }
}

extension ScreenCoachApp: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(nextStep), #selector(previousStep):
            return lessons.isRunning
        default:
            return true
        }
    }
}

extension ScreenCoachApp: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menu.items.first?.title = cache.statusLine
        visionStatusItem?.title = "Vision: " + (visionUsed ? grounding.statusLine : "not started")
        privacyStatusItem?.title = "Privacy: " + exclusions.statusLine

        // Repopulate saved workflows each open — recordings made or deleted
        // since the last open should just be there, no restart.
        guard let sub = teachSubmenu else { return }
        sub.items.removeAll { $0.representedObject is URL }
        let saved = lessonStore.list()
        guard !saved.isEmpty,
              let anchor = sub.items.firstIndex(where: { $0.isSeparatorItem }) else { return }
        for (offset, entry) in saved.enumerated() {
            let item = NSMenuItem(title: entry.title,
                                  action: #selector(startSavedLesson(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = entry.url
            sub.insertItem(item, at: anchor + offset)
        }
    }
}
