import CoreGraphics
import XCTest
@testable import ScreenCoachKit

final class HotKeyMachineTests: XCTestCase {

    private let space: UInt16 = 49

    private func feed(_ m: inout HotKeyTap.Machine, _ type: CGEventType, _ key: UInt16,
                      _ flags: CGEventFlags = [], repeat isRepeat: Bool = false,
                      physicallyDown: Bool = true) -> (HotKeyTap.Disposition, HotKeyTap.Machine.Output) {
        m.feed(type: type, keyCode: key, flags: flags, isAutorepeat: isRepeat,
               keyIsPhysicallyDown: { physicallyDown })
    }

    func testTheChordIsSwallowedSoNoNonBreakingSpaceReachesTheApp() {
        var m = HotKeyTap.Machine(binding: .optionSpace)
        let down = feed(&m, .keyDown, space, .maskAlternate)
        XCTAssertEqual(down.0, .consume)
        XCTAssertEqual(down.1, .down)
        let rep = feed(&m, .keyDown, space, .maskAlternate, repeat: true)
        XCTAssertEqual(rep.0, .consume, "auto-repeat would fill the query field with NBSPs")
        XCTAssertEqual(rep.1, .none)
        let up = feed(&m, .keyUp, space)
        XCTAssertEqual(up.0, .consume)
        XCTAssertEqual(up.1, .up)
    }

    func testEverythingElsePassesThrough() {
        var m = HotKeyTap.Machine(binding: .optionSpace)
        XCTAssertEqual(feed(&m, .keyDown, space).0, .pass, "a plain space must type")
        XCTAssertEqual(feed(&m, .keyUp, space).0, .pass)
        XCTAssertEqual(feed(&m, .keyDown, 0, .maskAlternate).0, .pass, "Option-A must type")
        XCTAssertEqual(feed(&m, .keyDown, space, [.maskAlternate, .maskCommand]).0, .pass)
    }

    func testReleasingOptionFirstStillEndsTheHold() {
        var m = HotKeyTap.Machine(binding: .optionSpace)
        _ = feed(&m, .keyDown, space, .maskAlternate)
        let up = feed(&m, .keyUp, space, [])
        XCTAssertEqual(up.1, .up)
        XCTAssertFalse(m.isDown)
    }

    func testALostKeyUpIsRecoveredWhenTheTapIsReEnabled() {
        var m = HotKeyTap.Machine(binding: .optionSpace)
        _ = feed(&m, .keyDown, space, .maskAlternate)
        let r = feed(&m, .tapDisabledByTimeout, 0, physicallyDown: false)
        XCTAssertEqual(r.1, .up, "the microphone must not stay live")
        XCTAssertFalse(m.isDown)
    }

    func testTapDisabledWhileStillHeldKeepsTheHold() {
        var m = HotKeyTap.Machine(binding: .optionSpace)
        _ = feed(&m, .keyDown, space, .maskAlternate)
        XCTAssertEqual(feed(&m, .tapDisabledByUserInput, 0, physicallyDown: true).1, .none)
        XCTAssertTrue(m.isDown)
    }

    func testAFreshPressAfterALostKeyUpStartsANewTurn() {
        var m = HotKeyTap.Machine(binding: .optionSpace)
        _ = feed(&m, .keyDown, space, .maskAlternate)
        let again = feed(&m, .keyDown, space, .maskAlternate, repeat: false)
        XCTAssertEqual(again.0, .consume)
        XCTAssertEqual(again.1, .upThenDown)
    }

    func testAPlainSpaceAfterALostKeyUpEndsTheHoldAndTypes() {
        var m = HotKeyTap.Machine(binding: .optionSpace)
        _ = feed(&m, .keyDown, space, .maskAlternate)
        let plain = feed(&m, .keyDown, space, [])
        XCTAssertEqual(plain.0, .pass)
        XCTAssertEqual(plain.1, .up)
        XCTAssertFalse(m.isDown)
    }
}
