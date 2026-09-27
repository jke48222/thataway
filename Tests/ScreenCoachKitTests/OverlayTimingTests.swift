import QuartzCore
import XCTest
@testable import ScreenCoachKit

final class OverlayTimingTests: XCTestCase {

    /// A fade that starts in the future must hold its from-value until then,
    /// or the ring shows during the flight and then blinks.
    func testTheDelayedFadeHoldsZeroBeforeItStarts() {
        let fade = PointerLayer.delayedFadeIn(beginTime: CACurrentMediaTime() + 0.4,
                                              duration: 0.18)
        XCTAssertEqual(fade.fillMode, .both)
        XCTAssertEqual(fade.fromValue as? Int, 0)
        XCTAssertEqual(fade.toValue as? Int, 1)
    }
}
