import XCTest
@testable import ThatawayCore

/// Hold versus tap, on hardware timestamps, and the turn clock that keeps
/// late work out of newer turns.
final class PushToTalkTests: XCTestCase {
    private let ms: UInt64 = 1_000_000
    private lazy var t0: UInt64 = 10_000 * ms

    func testReleaseUnderThresholdWithNothingHeardIsATap() {
        var p = PushToTalk()
        XCTAssertEqual(p.keyDown(atNs: t0), .startListening)
        XCTAssertEqual(p.keyUp(atNs: t0 + 300 * ms - 1, heardText: false), .cancelToTyping)
    }

    func testThreeHundredMillisecondsExactlyIsAHold() {
        var p = PushToTalk()
        _ = p.keyDown(atNs: t0)
        XCTAssertEqual(p.keyUp(atNs: t0 + 300 * ms, heardText: false), .finishUtterance)
    }

    func testShortHoldThatHeardWordsStillDelivers() {
        var p = PushToTalk()
        _ = p.keyDown(atNs: t0)
        XCTAssertEqual(p.keyUp(atNs: t0 + 120 * ms, heardText: true), .finishUtterance)
    }

    /// The audit's case: a 450 ms hold while main was busy for 200 ms. The
    /// hardware stamps say 450, so it is a hold whatever main was doing.
    func testHoldIsMeasuredOnEventStampsNotMainThreadTime() {
        var p = PushToTalk()
        _ = p.keyDown(atNs: t0)
        XCTAssertEqual(p.keyUp(atNs: t0 + 450 * ms, heardText: false), .finishUtterance)
    }

    func testAutoRepeatIsIgnoredAndKeepsTheHoldStart() {
        var p = PushToTalk()
        _ = p.keyDown(atNs: t0)
        for i in 1...20 {
            XCTAssertEqual(p.keyDown(atNs: t0 + UInt64(i) * 35 * ms), .ignore)
        }
        XCTAssertEqual(p.downAtNs, t0)
        XCTAssertEqual(p.keyDown(atNs: t0 + 2_000 * ms), .ignore, "slow initial repeat")
        XCTAssertEqual(p.keyDown(atNs: t0 - 5 * ms), .ignore, "out-of-order stamp")
    }

    func testMissedKeyUpRestartsOnTheNextPress() {
        var p = PushToTalk()
        _ = p.keyDown(atNs: t0)
        XCTAssertEqual(p.keyDown(atNs: t0 + 8_000 * ms), .restartListening)
        XCTAssertEqual(p.downAtNs, t0 + 8_000 * ms)
        XCTAssertEqual(p.keyUp(atNs: t0 + 8_100 * ms, heardText: false), .cancelToTyping)
    }

    func testStrayAndDoubleKeyUpsAreIgnored() {
        var p = PushToTalk()
        XCTAssertEqual(p.keyUp(atNs: t0, heardText: true), .ignore)
        _ = p.keyDown(atNs: t0)
        _ = p.keyUp(atNs: t0 + 400 * ms, heardText: false)
        XCTAssertEqual(p.keyUp(atNs: t0 + 500 * ms, heardText: false), .ignore)
    }

    func testKeyUpStampedBeforeKeyDownCountsAsZeroLength() {
        var p = PushToTalk()
        _ = p.keyDown(atNs: t0)
        XCTAssertEqual(p.keyUp(atNs: t0 - 1, heardText: false), .cancelToTyping)
    }

    func testExpiryBoundsAHoldWhoseKeyUpNeverCame() {
        var p = PushToTalk()
        _ = p.keyDown(atNs: t0)
        XCTAssertEqual(p.expire(atNs: t0 + 29_999 * ms), .ignore)
        XCTAssertEqual(p.expire(atNs: t0 + 30_000 * ms), .finishUtterance)
        XCTAssertFalse(p.isHolding)
        XCTAssertEqual(p.keyUp(atNs: t0 + 31_000 * ms, heardText: true), .ignore)
    }

    func testExpiryAfterReleaseAndResetDoNothing() {
        var p = PushToTalk()
        _ = p.keyDown(atNs: t0)
        _ = p.keyUp(atNs: t0 + 500 * ms, heardText: false)
        XCTAssertEqual(p.expire(atNs: t0 + 60_000 * ms), .ignore)
        _ = p.keyDown(atNs: t0 + 61_000 * ms)
        p.reset()
        XCTAssertEqual(p.keyUp(atNs: t0 + 61_500 * ms, heardText: false), .ignore)
        XCTAssertEqual(p.keyDown(atNs: t0 + 62_000 * ms), .startListening)
    }

    func testTurnClockInvalidatesOlderTurns() {
        let c = TurnClock()
        let a = c.advance()
        XCTAssertTrue(c.isCurrent(a))
        let b = c.advance()
        XCTAssertFalse(c.isCurrent(a))
        XCTAssertTrue(c.isCurrent(b))
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in c.advance() }
        XCTAssertEqual(c.current, b + 1000)
    }
}
