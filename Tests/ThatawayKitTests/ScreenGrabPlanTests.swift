import CoreGraphics
import XCTest
@testable import ThatawayKit
import ThatawayCore

final class ScreenGrabPlanTests: XCTestCase {

    func testExcludedAppsTitleMatchesAndTheCoachItselfAreCutFromTheFrame() {
        let plan = ScreenGrab.exclusionPlan(
            apps: [.init(pid: 10, bundleID: "com.google.Chrome"),
                   .init(pid: 11, bundleID: "com.apple.MobileSMS"),
                   .init(pid: 12, bundleID: "com.1password.1password")],
            windows: [.init(id: 1, pid: 10, title: "Waveform editor"),
                      .init(id: 2, pid: 10, title: "Chase Online Banking - Account Summary"),
                      .init(id: 3, pid: 11, title: "Mum"),
                      .init(id: 4, pid: 99, title: nil)],
            exclusions: .defaults, ownPID: 99)
        XCTAssertEqual(plan.excludedPIDs, [11, 12, 99])
        XCTAssertEqual(plan.excludedWindowIDs, [2])
    }

    func testNothingButTheCoachIsCutWhenNothingMatches() {
        let plan = ScreenGrab.exclusionPlan(
            apps: [.init(pid: 10, bundleID: "com.apple.logic10")],
            windows: [.init(id: 1, pid: 10, title: "Untitled - Tracks")],
            exclusions: .defaults, ownPID: 42)
        XCTAssertEqual(plan.excludedPIDs, [42])
        XCTAssertTrue(plan.excludedWindowIDs.isEmpty)
    }

    /// Two identical monitors stacked vertically share width, height and minX.
    func testStackedIdenticalDisplaysAreToldApartByMinY() {
        let upper = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let lower = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertFalse(ScreenGrab.framesMatch(upper, lower))
        XCTAssertTrue(ScreenGrab.framesMatch(lower, lower.offsetBy(dx: 0.5, dy: 0.5)))
    }
}
