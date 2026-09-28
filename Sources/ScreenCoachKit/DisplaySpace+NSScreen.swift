import AppKit
import ScreenCoachCore

public extension DisplaySpace {

    /// Which of `frames` (AppKit global coordinates, as `NSScreen.frame`
    /// gives them) holds `mouse` (as `NSEvent.mouseLocation` gives it).
    ///
    /// AppKit's mouse location covers a pixel's upper edge, so the top row
    /// of a display reports `y == frame.maxY`, which `CGRect.contains`
    /// (half-open) rejects; that is what `NSMouseInRect` is for. When no
    /// frame holds the point at all (a coordinate in a gap between
    /// displays), the nearest display is the one the user is looking at,
    /// not whichever the never-active accessory app calls main. Nil only
    /// when there are no frames.
    static func appKitScreenIndex(containing mouse: CGPoint, in frames: [CGRect]) -> Int? {
        if let i = frames.firstIndex(where: { NSMouseInRect(mouse, $0, false) }) { return i }
        func distance(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - mouse.x, 0, mouse.x - r.maxX)
            let dy = max(r.minY - mouse.y, 0, mouse.y - r.maxY)
            return dx * dx + dy * dy
        }
        return frames.indices.min { distance(frames[$0]) < distance(frames[$1]) }
    }

    /// Build the display layout from AppKit, flipping every screen into CG
    /// space once, here, so nothing downstream has to remember which way is
    /// up. `NSScreen.screens[0]` is the primary display — the anchor both
    /// coordinate spaces share — and is deliberately not `NSScreen.main`,
    /// which merely follows focus.
    static func current() -> DisplaySpace {
        let screens = NSScreen.screens
        guard let primary = screens.first else {
            return DisplaySpace(displays: [])
        }
        let h = primary.frame.height
        let infos = screens.enumerated().map { index, screen -> DisplayInfo in
            let ak = screen.frame
            return DisplayInfo(
                index: index,
                cgFrame: CGRect(x: ak.origin.x, y: h - ak.origin.y - ak.height,
                                width: ak.width, height: ak.height),
                scale: screen.backingScaleFactor
            )
        }
        return DisplaySpace(displays: infos)
    }

    var describeLayout: String {
        displays.map { d in
            String(format: "  screen %d%@ cg=(%.0f,%.0f %.0f×%.0f) @%.0fx",
                   d.index, d.isPrimary ? " [primary]" : "",
                   d.cgFrame.minX, d.cgFrame.minY,
                   d.cgFrame.width, d.cgFrame.height, d.scale)
        }.joined(separator: "\n")
    }
}
