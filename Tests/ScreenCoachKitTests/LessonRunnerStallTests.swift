import XCTest
@testable import ScreenCoachKit
import ScreenCoachCore

/// A lesson must never leave the learner under a dimmed screen with no way
/// forward. The cache here refuses every app at the bundle check, so the
/// runner is exercised without a single accessibility call on a real app.
final class LessonRunnerStallTests: XCTestCase {

    private var cache: AXCache!
    private var runner: LessonRunner!

    override func setUp() {
        cache = AXCache()
        cache.exclusionCheck = { _, _ in "test: nothing may be read" }
        runner = LessonRunner(cache: cache)
    }

    override func tearDown() {
        runner.stop()
        runner = nil
        cache = nil
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !condition() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testAManualStepReportsAStallAndNextStepFinishesTheLesson() {
        var stalls: [LessonRunner.StallReason] = []
        var finished = false
        runner.onStall = { _, _, reason in stalls.append(reason) }
        runner.onStep = { progress, step in
            if step == nil, progress.isFinished { finished = true }
        }

        runner.start(BuiltInLessons.preferences)
        XCTAssertEqual(stalls, [], "steps 1 and 2 complete on their own")
        runner.advance()
        runner.advance()
        XCTAssertEqual(stalls, [.manualStep], "the manual step must ask for Next Step")
        XCTAssertTrue(runner.isStalled)

        runner.advance()   // the app's Next Step action
        XCTAssertTrue(finished, "Next Step on the last step must finish the lesson")
        XCTAssertFalse(runner.isRunning)
    }

    func testAStepThatIsNeverSeenToFinishReportsATimeoutOnce() {
        var stalls: [LessonRunner.StallReason] = []
        runner.onStall = { _, _, reason in stalls.append(reason) }
        runner.stepTimeout = 0.05

        runner.start(Lesson(title: "t", steps: [
            Step(instruction: "Click Save", target: "Save", completion: .targetChanges),
            Step(instruction: "Click Done", target: "Done", completion: .targetChanges),
        ]))
        XCTAssertTrue(spin { !stalls.isEmpty }, "a timed-out step stalled silently")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(stalls, [.timedOut], "the stall is reported once per step, not per tick")
        XCTAssertTrue(runner.isStalled)

        runner.advance()
        XCTAssertFalse(runner.isStalled, "a new step starts un-stalled")
        XCTAssertEqual(runner.progress?.stepNumber, 2)
    }
}
