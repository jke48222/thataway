import XCTest
import ThatawayCore
@testable import ThatawayKit

/// Which display the command bar opens on, from AppKit mouse coordinates.
final class ScreenIndexTests: XCTestCase {

    // A 1440x900 primary with a 1920x1080 display above it, AppKit space.
    private let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let above = CGRect(x: 0, y: 900, width: 1920, height: 1080)

    func testTheTopRowOfASecondaryDisplayIsThatDisplay() {
        // AppKit reports the top pixel row as y == maxY, which a half-open
        // CGRect.contains would reject.
        let top = CGPoint(x: 100, y: above.maxY)
        XCTAssertFalse(above.contains(top))
        XCTAssertEqual(DisplaySpace.appKitScreenIndex(containing: top, in: [primary, above]), 1)
    }

    func testAPointInsideADisplayIsThatDisplay() {
        XCTAssertEqual(DisplaySpace.appKitScreenIndex(containing: CGPoint(x: 700, y: 400),
                                                      in: [primary, above]), 0)
        XCTAssertEqual(DisplaySpace.appKitScreenIndex(containing: CGPoint(x: 1800, y: 1500),
                                                      in: [primary, above]), 1)
    }

    func testAPointInAGapGoesToTheNearestDisplay() {
        let left = CGRect(x: 0, y: 0, width: 100, height: 100)
        let right = CGRect(x: 200, y: 0, width: 100, height: 100)
        XCTAssertEqual(DisplaySpace.appKitScreenIndex(containing: CGPoint(x: 170, y: 50),
                                                      in: [left, right]), 1)
        XCTAssertEqual(DisplaySpace.appKitScreenIndex(containing: CGPoint(x: 120, y: 50),
                                                      in: [left, right]), 0)
    }

    func testNoDisplaysGivesNil() {
        XCTAssertNil(DisplaySpace.appKitScreenIndex(containing: .zero, in: []))
    }
}
