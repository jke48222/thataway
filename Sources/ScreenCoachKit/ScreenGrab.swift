import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenCoachCore

/// A single frame plus everything needed to map its pixels back to the screen.
///
/// The three fields travel together on purpose. Phase 0 found that capture
/// APIs disagree about framing and that an app's window can span several
/// `SCWindow`s, so a bare `CGImage` is not enough to say where anything is —
/// the origin, the scale and the display index have to accompany it or the
/// inverse mapping gets re-derived (wrongly) at the far end.
public struct Grab {
    public let image: CGImage
    /// Origin of this frame in global CG points.
    public let origin: CGPoint
    /// Pixels per point.
    public let scale: CGFloat
    public let screenIndex: Int
}

public enum ScreenGrab {

    /// Capture the display that mostly contains `rect`, with every excluded
    /// app and window cut out of the frame.
    ///
    /// Display-scoped rather than window-scoped because Phase 0 measured the
    /// two capture paths framing the same window differently, and display
    /// space is the one frame where the AX→pixel mapping is a single
    /// subtraction and a single scale, verified pixel-exact on both Logic Pro
    /// and Chrome.
    ///
    /// Display scope means other apps' windows are in the frame, so the
    /// exclusion list is applied here, to the capture itself, and not only
    /// to the app in front. Removed from the frame, before any pixel exists:
    ///   * every app whose bundle ID matches a bundle rule,
    ///   * every window whose title matches a title rule (titles are read
    ///     fresh from the window server, not from a cached tree),
    ///   * the coach's own windows. The overlay may already be showing a
    ///     ring and caption at the tree's guess, and a model that can see
    ///     that ring would "corroborate" it.
    ///
    /// Returns nil, and captures nothing, when the target app itself
    /// (`targetPID`) currently has an excluded frontmost window, or when the
    /// display cannot be identified exactly.
    ///
    /// Synchronous by design: this is called from the vision queue, where the
    /// caller is about to spend two seconds in a model anyway.
    public static func display(containing rect: ScreenRect,
                               exclusions: ExclusionList = .defaults,
                               targetPID: pid_t? = nil) -> Grab? {
        // The fresh gate for the target app, from the window server, right
        // before capture. A tab that switched to an excluded title a moment
        // ago fails here even if the cached tree still has the old title.
        if let targetPID,
           let why = frontWindowExclusion(pid: targetPID, exclusions: exclusions) {
            NSLog("ScreenCoach: not capturing: \(why)")
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = GrabBox()
        let wantedFrame = DisplaySpace.current().display(at: rect.screenIndex)?.cgFrame
        let me = ProcessInfo.processInfo.processIdentifier

        Task {
            defer { semaphore.signal() }
            guard let wantedFrame,
                  let content = try? await SCShareableContent.excludingDesktopWindows(
                      false, onScreenWindowsOnly: true) else { return }

            // Match the SCDisplay to our display index by its whole frame.
            // Width, height and minX alone cannot tell two identical monitors
            // stacked vertically apart, and falling back to the first display
            // would silently capture the wrong monitor.
            guard let display = content.displays.first(where: {
                framesMatch($0.frame, wantedFrame)
            }) else { return }

            let plan = exclusionPlan(
                apps: content.applications.map {
                    AppInfo(pid: $0.processID, bundleID: $0.bundleIdentifier)
                },
                windows: content.windows.map {
                    WindowInfo(id: $0.windowID, pid: $0.owningApplication?.processID,
                               title: $0.title)
                },
                exclusions: exclusions, ownPID: me
            )
            if let targetPID, plan.excludedPIDs.contains(targetPID) {
                return
            }
            let filter: SCContentFilter
            if plan.excludedWindowIDs.isEmpty {
                // `excludingApplications` removes every window of those apps,
                // including one that opens after the content was listed.
                filter = SCContentFilter(
                    display: display,
                    excludingApplications: content.applications.filter {
                        plan.excludedPIDs.contains($0.processID)
                    },
                    exceptingWindows: [])
            } else {
                // A filter cannot combine "exclude these apps" with "and also
                // these windows", so list every window to drop: all windows
                // of the excluded apps plus the title matches.
                filter = SCContentFilter(
                    display: display,
                    excludingWindows: content.windows.filter { w in
                        plan.excludedWindowIDs.contains(w.windowID)
                            || w.owningApplication.map {
                                plan.excludedPIDs.contains($0.processID)
                            } ?? false
                    })
            }
            let config = WarmCapture.configuration(for: filter)
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config) else { return }

            box.set(Grab(image: image,
                         origin: CGPoint(x: display.frame.minX, y: display.frame.minY),
                         scale: CGFloat(image.width) / CGFloat(display.width),
                         screenIndex: rect.screenIndex))
        }

        _ = semaphore.wait(timeout: .now() + 5)
        return box.get()
    }

    // MARK: - The exclusion plan (pure)

    struct AppInfo: Equatable {
        let pid: pid_t
        let bundleID: String
    }

    struct WindowInfo: Equatable {
        let id: CGWindowID
        let pid: pid_t?
        let title: String?
    }

    struct Plan: Equatable {
        var excludedPIDs: Set<pid_t>
        var excludedWindowIDs: Set<CGWindowID>
    }

    /// Which apps and windows must not appear in a frame. Pure, so the policy
    /// can be tested without a display.
    static func exclusionPlan(apps: [AppInfo], windows: [WindowInfo],
                              exclusions: ExclusionList, ownPID: pid_t) -> Plan {
        var pids = Set<pid_t>([ownPID])
        for app in apps where exclusions.check(bundleID: app.bundleID,
                                               windowTitle: nil).excluded {
            pids.insert(app.pid)
        }
        var windowIDs = Set<CGWindowID>()
        for w in windows {
            if let pid = w.pid, pids.contains(pid) { continue }
            guard let title = w.title, !title.isEmpty else { continue }
            if exclusions.check(bundleID: nil, windowTitle: title).excluded {
                windowIDs.insert(w.id)
            }
        }
        return Plan(excludedPIDs: pids, excludedWindowIDs: windowIDs)
    }

    static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2
            && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// Why `pid`'s frontmost normal window may not be captured, if it may
    /// not. Reads the bundle ID from the running app and the title from the
    /// window server, fresh, so nothing here depends on a cached tree.
    public static func frontWindowExclusion(pid: pid_t, exclusions: ExclusionList) -> String? {
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let title = WindowServer.frontWindowTitle(pid: pid)
        let v = exclusions.check(bundleID: bundle, windowTitle: title)
        return v.excluded ? (v.reason ?? "excluded") : nil
    }
}

/// Carries the result out of the capture task without sharing a mutable
/// local across the concurrency boundary.
private final class GrabBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Grab?
    func set(_ g: Grab) { lock.lock(); value = g; lock.unlock() }
    func get() -> Grab? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Window-server lookups that need no accessibility call.
public enum WindowServer {

    /// Title of `pid`'s frontmost normal (layer 0) on-screen window.
    ///
    /// Window names of other processes are only returned to a caller that
    /// holds Screen Recording permission; without it this returns nil, and
    /// callers must not read a nil here as "no title".
    public static func frontWindowTitle(pid: pid_t) -> String? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        // The list is ordered front to back.
        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  (w[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
            if let name = w[kCGWindowName as String] as? String, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    /// Whether any on-screen window owned by `pid` that takes clicks contains
    /// `point` (global CG coordinates). Includes menus and status-item
    /// windows, which is how a click on the coach's own menu is recognised.
    ///
    /// Windows at or above the screen-saver level are skipped: that is where
    /// the overlay lives, and it is click-through, so a click "inside" it
    /// really lands on the app underneath.
    public static func window(ownedBy pid: pid_t, contains point: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        let overlayLevel = Int(CGWindowLevelForKey(.screenSaverWindow))
        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  (w[kCGWindowLayer as String] as? Int ?? 0) < overlayLevel,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { continue }
            if rect.contains(point) { return true }
        }
        return false
    }

    /// True when the process may read other apps' window titles.
    public static var canReadWindowTitles: Bool { CGPreflightScreenCaptureAccess() }
}
