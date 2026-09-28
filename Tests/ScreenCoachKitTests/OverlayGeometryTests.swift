import AppKit
import QuartzCore
import XCTest
@testable import ScreenCoachKit

/// The pointer's layers, driven headless: no panel, no window, no display.
final class OverlayGeometryTests: XCTestCase {

    private func makePointer(reduceMotion: Bool, scale: CGFloat = 2) -> PointerLayer {
        let p = PointerLayer(scale: scale)
        p.reduceMotion = reduceMotion
        p.resize(to: CGSize(width: 1440, height: 900))
        return p
    }

    private func echo(in p: PointerLayer) -> CALayer? {
        p.root.sublayers?.first { $0.animation(forKey: "echo") != nil }
    }

    /// The echo scales about its own centre. A screen-sized echo layer scaled
    /// about the screen's centre, so a menu-bar target's echo flew off screen.
    func testTheArrivalEchoIsTheRingsOwnRectSoItScalesInPlace() throws {
        let p = makePointer(reduceMotion: false)
        let box = CGRect(x: 40, y: 820, width: 40, height: 30)   // top-left corner
        p.point(from: CGPoint(x: 700, y: 400), to: CGPoint(x: box.midX, y: box.midY),
                box: box, caption: "Reload", confidence: .exact)

        let e = try XCTUnwrap(echo(in: p), "no arrival echo was added")
        let ring = box.insetBy(dx: -7, dy: -7)
        XCTAssertEqual(e.frame, ring)
        XCTAssertEqual(e.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        let path = try XCTUnwrap((e as? CAShapeLayer)?.path)
        XCTAssertEqual(path.boundingBoxOfPath.origin, .zero, "path must be in the echo's own space")
        XCTAssertEqual(path.boundingBoxOfPath.size, ring.size)
    }

    func testTheFullMotionPathFliesThePointerIn() {
        let p = makePointer(reduceMotion: false)
        p.point(from: .zero, to: CGPoint(x: 500, y: 500),
                box: CGRect(x: 480, y: 490, width: 40, height: 20),
                caption: "Save", confidence: .exact)
        let cursor = p.root.sublayers?.last
        XCTAssertNotNil(cursor?.animation(forKey: "fly"))
    }

    /// Reduce Motion: no sweep across the screen and no scale echo. The
    /// pointer is placed at the target and the ring fades in with it.
    func testReduceMotionPlacesThePointerWithoutFlightOrScale() {
        let p = makePointer(reduceMotion: true)
        let target = CGPoint(x: 500, y: 500)
        p.point(from: .zero, to: target,
                box: CGRect(x: 480, y: 490, width: 40, height: 20),
                caption: "Save", confidence: .uncertain)
        let layers = p.root.sublayers ?? []
        let cursor = layers.last
        XCTAssertNil(cursor?.animation(forKey: "fly"))
        XCTAssertEqual(cursor?.position, target)
        XCTAssertNil(echo(in: p), "Reduce Motion must not add the scaling echo")
        for l in layers {
            for key in l.animationKeys() ?? [] {
                let a = l.animation(forKey: key) as? CABasicAnimation
                XCTAssertEqual(a?.keyPath, "opacity",
                               "only opacity may animate under Reduce Motion, found \(key)")
                XCTAssertEqual(a?.beginTime ?? 0, 0, "the fade must not wait for a flight")
            }
        }
    }

    /// Text layers take the scale of the screen they are drawn on, not
    /// whichever screen happens to be main.
    func testTextLayersUseTheScaleTheyAreGiven() {
        let p = makePointer(reduceMotion: true, scale: 1)
        let text = (p.root.sublayers ?? []).compactMap { $0 as? CATextLayer }
        XCTAssertEqual(text.count, 2)
        XCTAssertTrue(text.allSatisfy { $0.contentsScale == 1 })
        p.setScale(2)
        XCTAssertTrue(text.allSatisfy { $0.contentsScale == 2 })
    }

    // MARK: - Contrast (WCAG 2.x)

    private func luminance(_ c: NSColor) -> Double {
        let s = c.usingColorSpace(.sRGB)!
        func lin(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent)
            + 0.0722 * lin(s.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// 1.4.11: graphical objects need 3:1 against what they sit on. The ring
    /// sits inside the scrim cutout, over the app's own (often white) chrome.
    func testRingColoursMeetNonTextContrastOnWhite() {
        XCTAssertGreaterThanOrEqual(contrast(PointerLayer.warn, .white), 3.0)
        XCTAssertGreaterThanOrEqual(contrast(PointerLayer.accent, .white), 3.0)
    }

    /// 1.4.3: the step number is 15 screen points bold, below the 18.66 px
    /// bold threshold for "large text", so it needs 4.5:1.
    func testStepBadgeTextMeetsTextContrast() {
        XCTAssertGreaterThanOrEqual(contrast(.white, PointerLayer.badgeFill), 4.5)
    }
}
