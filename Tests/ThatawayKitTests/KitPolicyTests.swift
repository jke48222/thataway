import AppKit
import XCTest
@testable import ThatawayKit
import ThatawayCore

/// Pure policies in Kit: which app a lesson step is judged on, how often AX
/// events may cost a walk, where the overlay's badge and caption go, and the
/// capture exclusion plan. No display, no accessibility call.
final class KitPolicyTests: XCTestCase {

    // MARK: - Lessons are judged on their own app only

    func testALessonStepIsJudgedOnlyOnTheLessonsApp() {
        XCTAssertTrue(LessonRunner.shouldEvaluate(lessonPID: 100, currentPID: 100))
        XCTAssertFalse(LessonRunner.shouldEvaluate(lessonPID: 100, currentPID: 200),
                       "another app's tree must never complete or re-baseline a step")
        XCTAssertTrue(LessonRunner.shouldEvaluate(lessonPID: nil, currentPID: 200),
                      "with no lesson app yet, the first app seen becomes it")
    }

    /// The failure the audit reproduced: TextEdit's search field is empty,
    /// Safari's holds "apple.com". The engine alone calls that a change, so
    /// the runner must never hand it trees from two apps.
    func testTwoAppsTreesWouldSatisfyAValueStepWhichIsWhyTheyAreNeverCompared() {
        func field(_ value: String) -> AXNode {
            AXNode(id: 0, parentID: nil, depth: 1, role: "AXTextField", title: "Search",
                   valueText: value,
                   bounds: ScreenRect(cg: CGRect(x: 10, y: 10, width: 200, height: 22),
                                      screenIndex: 0))
        }
        let textEdit = [field("")]
        let safari = [field("apple.com")]
        XCTAssertTrue(LessonEngine.isSatisfied(.valueChanges("the search field"),
                                               target: "the search field",
                                               before: textEdit, after: safari))
        XCTAssertFalse(LessonRunner.shouldEvaluate(lessonPID: 1, currentPID: 2))
    }

    // MARK: - AX events cannot drive walks at the rate an app posts them

    func testAStreamOfEventsWalksAtMostOncePerInterval() {
        // Last walk 150 ms ago, events every 150 ms: wait out the interval.
        let d = AXCache.eventWalkDelayMs(immediate: false, eventDriven: true,
                                         msSinceBurstStart: 700, msSinceLastWalk: 150,
                                         debounceMs: 120, maxWaitMs: 600,
                                         minIntervalMs: 1_000)
        XCTAssertEqual(d, 850, accuracy: 0.001)
        // Simulate: an event every 150 ms for 10 s, rescheduling each time,
        // exactly as `refresh` does.
        var walks: [Double] = []
        var lastWalk = -10_000.0
        var pendingAt: Double?
        var burstStart = 0.0
        var t = 0.0
        while t <= 10_000 {
            if let at = pendingAt, at <= t { walks.append(at); lastWalk = at; pendingAt = nil }
            if Int(t) % 150 == 0 {
                if pendingAt == nil { burstStart = t }
                let delay = AXCache.eventWalkDelayMs(
                    immediate: false, eventDriven: true, msSinceBurstStart: t - burstStart,
                    msSinceLastWalk: t - lastWalk, debounceMs: 120, maxWaitMs: 600,
                    minIntervalMs: 1_000)
                pendingAt = t + delay
            }
            t += 1
        }
        XCTAssertLessThanOrEqual(walks.count, 11, "\(walks.count) walks in 10 s")
        XCTAssertGreaterThanOrEqual(walks.count, 8, "a steady stream must still refresh")
        for (a, b) in zip(walks, walks.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 1_000 - 0.001)
        }
    }

    func testFocusChangesAndNonEventRefreshesAreNotThrottled() {
        XCTAssertEqual(AXCache.eventWalkDelayMs(immediate: true, eventDriven: false,
                                                msSinceBurstStart: 0, msSinceLastWalk: 5,
                                                debounceMs: 120, maxWaitMs: 600,
                                                minIntervalMs: 1_000), 0)
        XCTAssertEqual(AXCache.eventWalkDelayMs(immediate: false, eventDriven: true,
                                                msSinceBurstStart: 0, msSinceLastWalk: 5_000,
                                                debounceMs: 120, maxWaitMs: 600,
                                                minIntervalMs: 1_000), 120,
                       "a lone event after a quiet spell is only debounced")
    }

    func testContentNotificationsAreSubscribedOnlyWhileWatched() {
        let content: Set<String> = [kAXValueChangedNotification, kAXCreatedNotification,
                                    kAXUIElementDestroyedNotification]
        let idle = Set(AXCache.notifications(watchingContent: false))
        let watched = Set(AXCache.notifications(watchingContent: true))
        XCTAssertTrue(idle.isDisjoint(with: content))
        XCTAssertTrue(content.isSubset(of: watched))
        XCTAssertTrue(idle.contains(kAXTitleChangedNotification),
                      "title changes re-check the privacy gate and are always watched")
    }

    func testWatchingContentIsCountedAndPaired() {
        let cache = AXCache()
        XCTAssertFalse(cache.isWatchingContent)
        cache.beginWatchingContent()
        cache.beginWatchingContent()
        cache.endWatchingContent()
        XCTAssertTrue(cache.isWatchingContent)
        cache.endWatchingContent()
        cache.endWatchingContent()   // unbalanced: must not go negative
        XCTAssertFalse(cache.isWatchingContent)
        cache.beginWatchingContent()
        XCTAssertTrue(cache.isWatchingContent)
    }

    func testTheWindowTitleIsReadThroughAXOnlyWhenTheWindowServerWillNotSay() {
        XCTAssertFalse(AXCache.preWalkTitleSources(canReadWindowServerTitles: true).axTitle)
        XCTAssertTrue(AXCache.preWalkTitleSources(canReadWindowServerTitles: false).axTitle)
        XCTAssertTrue(AXCache.preWalkTitleSources(canReadWindowServerTitles: true).windowServer)
    }

    /// Refused at the bundle check, so nothing here reads any app.
    func testAnExclusionReasonIsDroppedWhenTheRulesChange() throws {
        let cache = AXCache()
        cache.exclusionCheck = { _, _ in "test: refused" }
        cache.refreshNow()
        // Only reported against the app it was about, which is still in front.
        guard cache.lastExclusionReason != nil else {
            throw XCTSkip("no app in front to refuse (headless session)")
        }
        XCTAssertEqual(cache.lastExclusionReason, "test: refused")
        XCTAssertTrue(cache.statusLine.hasPrefix("excluded: "))
        cache.invalidate()
        XCTAssertNil(cache.lastExclusionReason, "a stale reason outlived a rule change")
    }

    // MARK: - Microphone ceiling

    func testTheMicrophoneBackstopNeverCutsAHoldThePushToTalkLimitAllows() {
        let hold = PushToTalk().maxHoldNs
        XCTAssertGreaterThan(Voice.listenCeiling(forMaxHoldNs: hold), Double(hold) / 1e9)
    }

    // MARK: - Overlay placement

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testTheStepBadgeForAMenuBarTargetDropsBelowItAndStaysOnScreen() {
        // The Edit menu: a menu-bar item at local y 876...900.
        let cutout = CGRect(x: 120, y: 876, width: 40, height: 24)
        let badge = PointerLayer.badgeRect(for: cutout, in: screen, diameter: 30)
        XCTAssertTrue(screen.contains(badge), "\(badge)")
        XCTAssertLessThanOrEqual(badge.maxY, cutout.minY, "must not cover the menu title")
        XCTAssertFalse(badge.intersects(cutout))
    }

    func testTheStepBadgeForALeftEdgeTargetMovesToItsRight() {
        let cutout = CGRect(x: 8, y: 400, width: 180, height: 22)
        let badge = PointerLayer.badgeRect(for: cutout, in: screen, diameter: 30)
        XCTAssertTrue(screen.contains(badge), "\(badge)")
        XCTAssertGreaterThanOrEqual(badge.minX, cutout.maxX)
    }

    func testTheStepBadgeKeepsItsUsualPlaceWhenThereIsRoom() {
        let cutout = CGRect(x: 500, y: 400, width: 80, height: 24)
        let badge = PointerLayer.badgeRect(for: cutout, in: screen, diameter: 30)
        XCTAssertEqual(badge, CGRect(x: 500 - 36, y: 424 - 15, width: 30, height: 30))
    }

    func testALongLessonInstructionWrapsInsteadOfBeingCut() {
        let text = "1/3  Open the Google Chrome menu, right next to the Apple menu"
        let layout = PointerLayer.captionLayout(text, near: CGRect(x: 600, y: 400, width: 80,
                                                                   height: 30), in: screen)
        XCTAssertEqual(layout.text, text)
        XCTAssertGreaterThan(layout.background.height, 24, "a 404 pt caption needs two lines")
        XCTAssertLessThanOrEqual(layout.background.width, PointerLayer.captionMaxWidth)
        XCTAssertEqual(layout.textFrame.minX - layout.background.minX,
                       PointerLayer.captionInset, accuracy: 0.001)
    }

    func testAnOverlongCaptionShortensTheLabelAndKeepsTheMarkAndTheNote() {
        let label = String(repeating: "Show the sidebar with every bookmark folder ", count: 6)
        let text = label + "?  ·  not captured: window title matches “Bank”"
        let layout = PointerLayer.captionLayout(text, near: CGRect(x: 600, y: 400, width: 80,
                                                                   height: 30), in: screen)
        XCTAssertNotEqual(layout.text, text)
        XCTAssertTrue(layout.text.hasSuffix("?  ·  not captured: window title matches “Bank”"),
                      layout.text)
        XCTAssertTrue(layout.text.contains("…"))
    }

    func testNewlinesInACaptionAreFlattened() {
        XCTAssertEqual(PointerLayer.flatten("Save\n  as PDF\r\n"), "Save as PDF")
    }

    func testTheCaptionStaysOnScreenForATargetAsTallAsTheDisplay() {
        let ring = CGRect(x: 0, y: 30, width: 1440, height: 850).insetBy(dx: -7, dy: -7)
        let layout = PointerLayer.captionLayout("the page", near: ring, in: screen)
        XCTAssertTrue(screen.contains(layout.background), "\(layout.background)")
    }

    func testTheCaptionFlipsBelowAMenuBarTarget() {
        let ring = CGRect(x: 120, y: 876, width: 40, height: 24).insetBy(dx: -7, dy: -7)
        let layout = PointerLayer.captionLayout("Edit", near: ring, in: screen)
        XCTAssertTrue(screen.contains(layout.background))
        XCTAssertLessThanOrEqual(layout.background.maxY, ring.minY)
    }

    // MARK: - Capture exclusions

    func testNotificationBannersAreCutFromTheFrameEvenWithNoRules() {
        let plan = ScreenGrab.exclusionPlan(
            apps: [.init(pid: 10, bundleID: "com.google.Chrome"),
                   .init(pid: 20, bundleID: "com.apple.notificationcenterui"),
                   .init(pid: 21, bundleID: "com.apple.UserNotificationCenter")],
            windows: [.init(id: 1, pid: 20, title: nil)],
            exclusions: ExclusionList(rules: []), ownPID: 99)
        XCTAssertEqual(plan.excludedPIDs, [20, 21, 99])
    }

    // MARK: - Warm capture's first frame

    func testAStreamThatStopsBeforeItsFirstFrameEndsTheWait() async {
        struct Stopped: Error {}
        let gate = FirstFrameGate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { gate.fail(Stopped()) }
        do {
            try await gate.wait(timeout: 5)
            XCTFail("the wait should have thrown")
        } catch {
            XCTAssertTrue(error is Stopped, "\(error)")
        }
    }

    func testTheFirstFrameWaitTimesOut() async {
        let gate = FirstFrameGate()
        let started = Date()
        do {
            try await gate.wait(timeout: 0.1)
            XCTFail("the wait should have timed out")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        }
    }

    func testAFrameThatArrivedFirstEndsTheWaitAtOnce() async throws {
        let gate = FirstFrameGate()
        gate.open()
        try await gate.wait(timeout: 5)
        gate.fail(CancellationError())   // too late: no second resume
    }
}
