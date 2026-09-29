// The promo stage: Thataway's real `PointerLayer`, a replica of its command
// bar and a fictional desktop, played by a script for the README, the site
// and the promo film. Debug builds only.
//
//   ThatawayApp --promo <dir> --promo-scene <name>   one scene, for scripts/media/record_promo.swift
//   ThatawayApp --promo-stills <dir>                  stills, icon and social preview (PromoStills.swift)
//
// `ThatawayApp.main()` calls `runIfRequested` before it creates the app
// delegate, so none of the app's services exist here: no hotkey tap, no tree
// cache, no status item, no overlay panel, no voice, no exclusion or lesson
// files, and no permission prompt. The stage reads nothing from other apps.
//
// The stage window is borderless and sits one level below the desktop, so it
// never appears on screen, never takes focus and ignores the mouse. The
// recorder captures that one window with ScreenCaptureKit. Files in `<dir>`
// keep the two in step: the stage writes `ready.json`, waits for `go`, plays
// the scene, writes `timeline.json` and `done`, then quits.
#if DEBUG

import AppKit
import SwiftUI
import ThatawayCore
import ThatawayKit

enum PromoStage {

    /// Called first thing in `main()`. Returns false for a normal launch;
    /// otherwise runs the stage and exits the process when it is done.
    static func runIfRequested(_ arguments: [String]) -> Bool {
        let launch = PromoLaunch.parse(arguments, debugBuild: PromoLaunch.isDebugBuild)
        switch launch {
        case .normal:
            return false
        case .invalid(let why):
            fail(why)
        case .stills(let dir):
            start { PromoStills.render(to: URL(fileURLWithPath: dir, isDirectory: true)) }
        case .scene(let name, let dir):
            guard let scene = PromoScene(rawValue: name) else {
                fail("unknown scene “\(name)”; scenes: \(PromoScene.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            start { MainActor.assumeIsolated { perform(scene, handshake: URL(fileURLWithPath: dir, isDirectory: true)) } }
        }
    }

    /// Keeps the process from being napped while it renders off screen.
    private static var activity: NSObjectProtocol?

    private static func start(_ body: @escaping () -> Void) -> Never {
        let app = NSApplication.shared
        // No Dock icon, and never activated: the stage must not take focus
        // from whatever Jalen is doing while it renders.
        app.setActivationPolicy(.accessory)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
            reason: "Rendering Thataway's promo stage")
        DispatchQueue.main.async(execute: body)
        app.run()
        exit(0)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("promo: \(message)\n".utf8))
        exit(1)
    }

    static func writeJSON(_ object: Any, to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Footage

    private static var stage: PromoStageView?
    private static var window: NSWindow?

    @MainActor
    private static func perform(_ scene: PromoScene, handshake dir: URL) {
        startWatchdog(seconds: 2400)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            fail("could not create \(dir.path): \(error.localizedDescription)")
        }
        let view = PromoStageView()
        let win = makeStageWindow(view)
        stage = view
        window = win
        let director = PromoDirector(stage: view)
        director.prepare(scene)
        view.startHeartbeat()

        Task { @MainActor in
            await director.warmUp(scene)
            try? await Task.sleep(nanoseconds: 300_000_000)
            writeJSON([
                "windowNumber": win.windowNumber,
                "scene": scene.rawValue,
                "stageWidth": PromoGeometry.stage.width,
                "stageHeight": PromoGeometry.stage.height,
                "backingScale": win.backingScaleFactor,
                "onActiveSpace": win.isOnActiveSpace,
            ], to: dir.appendingPathComponent("ready.json"))
            let go = dir.appendingPathComponent("go")
            while !FileManager.default.fileExists(atPath: go.path) {
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
            await director.play(scene)
            writeJSON([
                "scene": scene.rawValue,
                "title": scene.title,
                "summary": scene.summary,
                "sceneDuration": director.elapsed,
                // Stage points, top-left origin: where every flight starts. The editor
                // frames the flight and the README loop from it.
                "mouseRest": [PromoGeometry.mouseRest.x, PromoGeometry.mouseRest.y],
                "marks": director.marks,
            ], to: dir.appendingPathComponent("timeline.json"))
            FileManager.default.createFile(atPath: dir.appendingPathComponent("done").path, contents: Data())
            try? await Task.sleep(nanoseconds: 300_000_000)
            win.orderOut(nil)
            exit(0)
        }
    }

    /// A borderless window one level below the desktop: rendered and
    /// capturable, never seen or clicked.
    static func makeStageWindow(_ view: NSView) -> NSWindow {
        let origin = NSScreen.screens.first?.frame.origin ?? .zero
        let win = NSWindow(contentRect: CGRect(origin: origin, size: PromoGeometry.stage),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        win.ignoresMouseEvents = true
        win.isOpaque = true
        win.hasShadow = false
        win.backgroundColor = .black
        win.title = "Thataway Promo Stage"
        win.isExcludedFromWindowsMenu = true
        win.contentView = view
        win.orderFrontRegardless()
        return win
    }

    private static var watchdog: DispatchSourceTimer?

    /// Never outlive the recorder that launched the stage, or a stuck render.
    private static func startWatchdog(seconds: Double) {
        let parent = getppid()
        let deadline = Date().addingTimeInterval(seconds)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler {
            if Date() > deadline {
                FileHandle.standardError.write(Data("promo: timed out\n".utf8))
                exit(2)
            }
            if getppid() != parent { exit(3) }
        }
        timer.resume()
        watchdog = timer
    }
}

// MARK: - The stage view

/// The whole stage, bottom to top: wallpaper, the fictional desktop (SwiftUI),
/// the overlay with the real `PointerLayer`, the command bar replica (above
/// the overlay, as `CommandBar` sits above `OverlayPanel`), and the mouse.
final class PromoStageView: NSView {
    let model = PromoStageModel()
    let desktop = NSView()
    let wallpaper = CALayer()
    let hosting: NSHostingView<PromoDesktopView>
    let overlay = NSView()
    let pointer = PointerLayer(scale: 2)
    let bar = PromoCommandBar()
    let top = NSView()
    let mouse = CALayer()
    private let heartbeat = CALayer()
    private var heartbeatTimer: Timer?

    override var isFlipped: Bool { false }

    init() {
        hosting = NSHostingView(rootView: PromoDesktopView(model: model))
        super.init(frame: CGRect(origin: .zero, size: PromoGeometry.stage))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        desktop.frame = bounds
        desktop.wantsLayer = true
        wallpaper.frame = bounds
        wallpaper.contentsGravity = .resize
        wallpaper.contents = PromoWallpaper.image(pixelWidth: Int(bounds.width * 2), pixelHeight: Int(bounds.height * 2))
        desktop.layer?.addSublayer(wallpaper)
        hosting.frame = bounds
        desktop.addSubview(hosting)
        addSubview(desktop)

        overlay.frame = bounds
        overlay.wantsLayer = true
        overlay.layer?.masksToBounds = false
        pointer.reduceMotion = false
        pointer.resize(to: bounds.size)
        overlay.layer?.addSublayer(pointer.root)
        addSubview(overlay)

        bar.isHidden = true
        addSubview(bar)

        top.frame = bounds
        top.wantsLayer = true
        mouse.contents = PromoMouse.image(scale: 2)
        mouse.contentsScale = 2
        mouse.bounds = CGRect(origin: .zero, size: PromoMouse.size)
        mouse.anchorPoint = PromoMouse.hotSpot
        mouse.actions = ["position": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
        top.layer?.addSublayer(mouse)
        heartbeat.frame = CGRect(x: 0, y: bounds.height - 1, width: 1, height: 1)
        heartbeat.backgroundColor = PromoPalette.cg(0x0B1426)
        heartbeat.actions = ["backgroundColor": NSNull()]
        top.layer?.addSublayer(heartbeat)
        addSubview(top)
        setMouse(PromoGeometry.mouseRest)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Mouse

    private(set) var mousePoint = PromoGeometry.mouseRest

    /// Place the person's mouse (stage space). It is only ever moved between
    /// shots, never on camera.
    func setMouse(_ p: CGPoint) {
        mousePoint = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mouse.position = PromoGeometry.appKit(p)
        CATransaction.commit()
    }

    // MARK: Heartbeat

    /// Flip one corner pixel between two nearly identical colours so
    /// ScreenCaptureKit keeps delivering frames through still moments, and a
    /// stalled window is detectable.
    func startHeartbeat() {
        var flip = false
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            flip.toggle()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.heartbeat.backgroundColor = PromoPalette.cg(flip ? 0x0B1426 : 0x0C1527)
            CATransaction.commit()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    // MARK: Command bar

    /// Show the bar, as `CommandBar.present` places it, over a frosted
    /// snapshot of whatever is under it (taken now unless `prepareBar` took
    /// it before the take started).
    func presentBar(status: String, query: String = "") {
        // Prepare first: `prepareBar` resets the status line to the typing
        // hint, which would hide a refusal on a stage that was not warmed up
        // (the stills).
        if !backdropReady { prepareBar() }
        bar.setStatus(status)
        bar.setQuery(query)
        bar.showSuggestions([])
        bar.layout(top: barTop, centerX: bounds.midX)
        bar.isHidden = false
    }

    private var backdropReady = false

    /// Place the bar and frost its backdrop ahead of time. The snapshot and
    /// blur take long enough on the main thread to drop frames mid-take, so
    /// scenes call this while the recorder is still warming up.
    func prepareBar(status: String = "type a target, or hold ⌥Space to speak") {
        bar.setStatus(status)
        bar.showSuggestions([])
        // `present` positions the panel with its bottom at 62% of the screen
        // height; later growth keeps the top edge still.
        let h0 = bar.fittingHeight
        barTop = PromoGeometry.stage.height * 0.62 + h0
        let snapHeight: CGFloat = 260
        let rectAK = CGRect(x: bounds.midX - PromoCommandBar.width / 2, y: barTop - snapHeight,
                            width: PromoCommandBar.width, height: snapHeight)
        layoutSubtreeIfNeeded()
        bar.setBackdrop(snapshot(of: desktop, rect: rectAK), height: snapHeight)
        backdropReady = true
    }

    private var barTop: CGFloat = 0

    func updateBar(query: String? = nil, status: String? = nil,
                   suggestions: [(score: Double, label: String)]? = nil) {
        if let status { bar.setStatus(status) }
        if let query { bar.setQuery(query) }
        if let suggestions { bar.showSuggestions(suggestions) }
        bar.layout(top: barTop, centerX: bounds.midX)
    }

    func dismissBar() {
        bar.showsCaret = false
        bar.isHidden = true
    }

    /// The stage under `rect` (AppKit, stage space) at 2×.
    func snapshot(of view: NSView, rect: CGRect) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * 2),
                                         pixelsHigh: Int(rect.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = rect.size
        view.cacheDisplay(in: rect, to: rep)
        return rep.cgImage
    }

    // MARK: Pointer

    /// `OverlayController.point`: fly from the mouse to `target` (stage
    /// space), with no scrim.
    func point(at target: CGRect, caption: String, exact: Bool) {
        let ak = PromoGeometry.appKit(target)
        pointer.setScrim(cutout: nil, stepNumber: nil)
        pointer.point(from: PromoGeometry.appKit(mousePoint), to: CGPoint(x: ak.midX, y: ak.midY),
                      box: ak, caption: caption, confidence: exact ? .exact : .uncertain)
    }

    /// `OverlayController.teach`: dim everything but `target`, number it,
    /// and fly (or, for a still, place) the pointer.
    func teach(_ target: CGRect, caption: String, step: Int, exact: Bool, animated: Bool) {
        let ak = PromoGeometry.appKit(target)
        let centre = CGPoint(x: ak.midX, y: ak.midY)
        pointer.setScrim(cutout: ak, stepNumber: step)
        if animated {
            pointer.point(from: PromoGeometry.appKit(mousePoint), to: centre, box: ak,
                          caption: caption, confidence: exact ? .exact : .uncertain)
        } else {
            pointer.place(at: centre, box: ak, caption: caption, confidence: exact ? .exact : .uncertain)
        }
    }

    /// A still: the pointer already on `target`.
    func placePointer(at target: CGRect, caption: String, exact: Bool) {
        let ak = PromoGeometry.appKit(target)
        pointer.setScrim(cutout: nil, stepNumber: nil)
        pointer.place(at: CGPoint(x: ak.midX, y: ak.midY), box: ak, caption: caption,
                      confidence: exact ? .exact : .uncertain)
    }

    func hidePointer() { pointer.hide() }
}

// MARK: - The person's mouse

/// A plain arrow, black with a white keyline, standing in for the person's
/// own mouse. Drawn here so no system cursor art is used.
enum PromoMouse {
    static let size = CGSize(width: 22, height: 30)
    /// The tip, as an anchor point (bottom-left origin).
    static let hotSpot = CGPoint(x: 3 / 22, y: 1 - 2 / 30)

    static func image(scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // Designed top-left; flip.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 3, y: 2))
        p.addLine(to: CGPoint(x: 3, y: 23.5))
        p.addLine(to: CGPoint(x: 8.2, y: 18.6))
        p.addLine(to: CGPoint(x: 11.6, y: 26.4))
        p.addLine(to: CGPoint(x: 15.2, y: 24.8))
        p.addLine(to: CGPoint(x: 11.9, y: 17.2))
        p.addLine(to: CGPoint(x: 18.8, y: 17.2))
        p.closeSubpath()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3, color: CGColor(gray: 0, alpha: 0.45))
        ctx.addPath(p)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(3.2)
        ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(p)
        ctx.setFillColor(CGColor(gray: 0.02, alpha: 1))
        ctx.fillPath()
        return ctx.makeImage()
    }
}

#endif
