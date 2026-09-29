import XCTest
@testable import ThatawayKit

final class CacheFreshnessTests: XCTestCase {

    func testAYoungTreeWithNoInputSinceIsServed() {
        XCTAssertTrue(AXCache.shouldServe(ageMs: 800, maxAgeMs: 5_000,
                                          msSinceLastScroll: 60_000, msSinceLastClick: 60_000))
    }

    func testTooOldIsNotServed() {
        XCTAssertFalse(AXCache.shouldServe(ageMs: 5_001, maxAgeMs: 5_000,
                                           msSinceLastScroll: 60_000, msSinceLastClick: 60_000))
    }

    /// Walked at t=0, scrolled at t=0.3 s, asked at t=2.5 s: the tree is
    /// 2 500 ms old and the scroll 2 200 ms ago, so it predates the scroll.
    func testATreeOlderThanTheLastScrollIsNotServed() {
        XCTAssertFalse(AXCache.shouldServe(ageMs: 2_500, maxAgeMs: 5_000,
                                           msSinceLastScroll: 2_200, msSinceLastClick: 60_000))
    }

    func testATreeOlderThanTheLastClickIsNotServed() {
        XCTAssertFalse(AXCache.shouldServe(ageMs: 1_000, maxAgeMs: 5_000,
                                           msSinceLastScroll: 60_000, msSinceLastClick: 400))
    }

    func testATreeReadAfterTheScrollIsServed() {
        XCTAssertTrue(AXCache.shouldServe(ageMs: 100, maxAgeMs: 5_000,
                                          msSinceLastScroll: 250, msSinceLastClick: 900))
    }
}
