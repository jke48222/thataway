// `ThatawayApp --promo-stills <dir>`: the stills, the icon and the social
// preview, rendered off screen from the promo stage. Debug builds only.
//
//   <dir>/screens/point-exact.png, point-uncertain.png, privacy-excluded.png,
//                 lesson-step.png, watch-me.png        3072 × 1728 (the stage at 2×), opaque
//   <dir>/icon.png                                    512 × 512, the app icon
//   <dir>/favicon-32.png, favicon-16.png              the hinted small sizes, for the site
//   <dir>/social-preview.png                          1280 × 640, opaque
//
// Each still is drawn with `cacheDisplay` from a stage window that sits below
// the desktop: no screen capture, no permission, the same pixels every run.
#if DEBUG

import AppKit
import SwiftUI
import ThatawayCore
import ThatawayKit

enum PromoStill: String, CaseIterable {
    case pointExact = "point-exact"
    case pointUncertain = "point-uncertain"
    case privacyExcluded = "privacy-excluded"
    case lessonStep = "lesson-step"
    case watchMe = "watch-me"
}

enum PromoStills {

    static func render(to dir: URL) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 180) {
            FileHandle.standardError.write(Data("promo: stills timed out\n".utf8))
            exit(2)
        }
        Task { @MainActor in
            let failures = await renderAll(to: dir)
            exit(failures == 0 ? 0 : 1)
        }
    }

    @MainActor
    private static func renderAll(to dir: URL) async -> Int {
        let screens = dir.appendingPathComponent("screens", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true)
        } catch {
            PromoStage.fail("could not create \(screens.path): \(error.localizedDescription)")
        }
        var failures = 0
        var exactShot: CGImage?
        for still in PromoStill.allCases {
            guard let image = await renderStill(still) else {
                report("could not render \(still.rawValue)")
                failures += 1
                continue
            }
            if still == .pointExact { exactShot = image }
            if !writePNG(image, to: screens.appendingPathComponent("\(still.rawValue).png"), opaque: true) {
                failures += 1
            }
        }
        // The 512 master, plus the hinted 16 and 32 px sizes for the site's
        // favicon: a browser shrinking the master would bring back the trail
        // and the soft ring that the small tiers leave out.
        for (pixels, name) in [(512, "icon.png"), (32, "favicon-32.png"), (16, "favicon-16.png")] {
            if let icon = PromoIcon.image(pixels: pixels) {
                if !writePNG(icon, to: dir.appendingPathComponent(name), opaque: false) { failures += 1 }
            } else {
                report("could not draw \(name)")
                failures += 1
            }
        }
        if let shot = exactShot, let social = PromoSocialPreview.image(productShot: shot) {
            if !writePNG(social, to: dir.appendingPathComponent("social-preview.png"), opaque: true) { failures += 1 }
        } else {
            report("could not render the social preview")
            failures += 1
        }
        return failures
    }

    // MARK: Stills

    @MainActor
    private static func renderStill(_ still: PromoStill) async -> CGImage? {
        let stage = PromoStageView()
        let window = PromoStage.makeStageWindow(stage)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        configure(still, stage)
        // Let SwiftUI lay out and the text layers draw.
        try? await Task.sleep(nanoseconds: 700_000_000)
        return capture(stage)
    }

    @MainActor
    static func configure(_ still: PromoStill, _ stage: PromoStageView) {
        let model = stage.model
        stage.setMouse(PromoGeometry.mouseRest)
        switch still {
        case .pointExact, .pointUncertain:
            model.studio = StudioState()
            let query = still == .pointExact ? PromoScript.exactQuery : PromoScript.uncertainQuery
            guard let a = PromoPipeline.answer(query, tree: PromoTreeBuilder.studio(model.studio)) else {
                PromoStage.fail("“\(query)” has no answer")
            }
            stage.placePointer(at: a.target, caption: a.caption, exact: a.exact)

        case .privacyExcluded:
            model.showStudio = false
            model.showBrowser = true
            model.frontApp = PromoScript.browserName
            stage.layoutSubtreeIfNeeded()
            stage.hosting.layoutSubtreeIfNeeded()
            guard let refusal = PromoPipeline.refusal(appName: PromoScript.browserName,
                                                      bundleID: PromoScript.browserBundleID,
                                                      windowTitle: PromoScript.browserTitle) else {
                PromoStage.fail("the default exclusions no longer match “\(PromoScript.browserTitle)”")
            }
            stage.presentBar(status: refusal)
            stage.bar.showsCaret = true

        case .lessonStep:
            // Step 1 done (the person clicked Sharing); step 2 lit. The mouse
            // has moved off the window, so the only arrow near Studio is the
            // drawn pointer.
            let click = PromoScript.recordingClicks[0]
            model.studio = click.after
            stage.setMouse(PromoGeometry.mouseParked)
            var progress = LessonProgress(lesson: PromoScript.recordedLesson)
            progress.advance()
            guard let step = progress.current else { return }
            let tree = PromoTreeBuilder.studio(model.studio)
            guard let best = AXResolver.rank(query: step.target, in: tree.nodes,
                                             windowBounds: tree.windowBounds, limit: 1).first else {
                PromoStage.fail("step 2 resolves to nothing")
            }
            stage.teach(best.node.bounds.cg, caption: progress.caption(appName: StudioLayout.appName),
                        step: progress.stepNumber, exact: best.score >= AXResolver.hitThreshold,
                        animated: false)

        case .watchMe:
            // Recording saved: the file, and the Teach Me menu listing it.
            // Studio sits clear of the saved file, which is on the left, with
            // the Link Settings sheet closed again (Done), and the menu leaves
            // out its status lines so it reads Teach Me… > the saved lesson.
            var finished = PromoScript.recordingClicks[2].after
            finished.sheetOpen = false
            model.studio = finished
            model.studioOffset = CGSize(width: 300, height: 100)
            model.showEditor = true
            model.frontApp = StudioLayout.appName
            model.savedLessons = [PromoScript.recordingTitle]
            model.highlightedSavedLesson = PromoScript.recordingTitle
            model.showMenuDiagnostics = false
            model.teachMenuOpen = true
            stage.setMouse(PromoStatusMenu.savedRowCenter(0, diagnostics: false))
        }
    }

    /// The stage at 2×, straight from the view hierarchy.
    @MainActor
    static func capture(_ view: NSView) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    // MARK: Files

    static func report(_ message: String) {
        FileHandle.standardError.write(Data("promo: \(message)\n".utf8))
    }

    static func writePNG(_ image: CGImage, to url: URL, opaque: Bool) -> Bool {
        let image = opaque ? (flattened(image) ?? image) : image
        let rep = NSBitmapImageRep(cgImage: image)
        let converted = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
        guard let data = converted.representation(using: .png, properties: [:]) else {
            report("could not encode \(url.lastPathComponent)")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            print(url.path)
            return true
        } catch {
            report("could not write \(url.path): \(error.localizedDescription)")
            return false
        }
    }

    /// Drawn onto black in an RGB context with no alpha channel.
    static func flattened(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(r)
        ctx.draw(image, in: r)
        return ctx.makeImage()
    }
}

// MARK: - Icon

/// The app icon, approved: a focus reticle settling onto a small control on
/// a graphite-navy squircle, the product's own moment of landing on the thing
/// you named. The ring and its four inward ticks are the one luminous blue;
/// a short strobe trail of the ring's trailing edge shows it arriving from the
/// lower left. Small sizes are hinted: at 32 and 64 px the ring, ticks and
/// control sit on that size's pixel grid, and at 16 px the trail is dropped so
/// the glyph is a centred ring round a lit core. The body's lower half and its
/// rim are lifted so the tile's outline holds on dark Docks and menus. Original
/// art, drawn in code so it can be regenerated.
enum PromoIcon {
    static func image(pixels: Int) -> CGImage? {
        let s = CGFloat(pixels)
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        // Design on a 1024 grid, top-left origin.
        ctx.scaleBy(x: s / 1024, y: s / 1024)
        ctx.translateBy(x: 0, y: 1024)
        ctx.scaleBy(x: 1, y: -1)
        draw(in: ctx, pixels: pixels)
        return ctx.makeImage()
    }

    private static func cg(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor { PromoPalette.cg(hex, a) }

    private static func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: stops.map { cg($0.0, $0.1) } as CFArray, locations: stops.map(\.2))!
    }

    /// macOS icon grid: an 824 pt body centred on the 1024 canvas.
    static let body = CGRect(x: 100, y: 100, width: 824, height: 824)

    /// Apple's icon outline is close to a superellipse; exponent 5 matches
    /// its continuous corners well at every size.
    static func squircle(_ r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let n: CGFloat = 5
        let steps = 720
        for i in 0..<steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let c = cos(t), s = sin(t)
            let x = r.midX + r.width / 2 * copysign(pow(abs(c), 2 / n), c)
            let y = r.midY + r.height / 2 * copysign(pow(abs(s), 2 / n), s)
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.closeSubpath()
        return p
    }

    // MARK: Palette

    /// The one luminous colour: a clear, system-leaning blue.
    private static let accent: UInt32 = 0x2FA8FF
    /// The same blue near white, for the lit core.
    private static let accentHot: UInt32 = 0xBFE6FF
    /// The same blue, deeper, for glow.
    private static let accentDeep: UInt32 = 0x0A6CFF

    // MARK: Per-size design

    /// The design at one pixel size, in 1024-grid units.
    struct Tier {
        var ringR: CGFloat          // reticle radius, to the stroke's centre
        var ringW: CGFloat          // reticle stroke
        var tickLen: CGFloat        // inward ticks; 0 = none
        var tickW: CGFloat
        var echoes: Int             // strobe echoes of the trailing edge; 0 = no trail
        var echoStep: CGFloat       // distance between echoes
        var echoSpan: CGFloat       // half-angle of each echo arc
        var grid: Bool              // faint viewfinder grid on the field
        var control: CGSize         // the small control under the reticle
        var controlCorner: CGFloat
        var centre: CGPoint
        var glow: CGFloat           // glow blur on the accent
    }

    /// Small sizes are hinted: the centre, ring, ticks and control sit on the
    /// pixel grid of that size (16 px: 64 units a pixel; 32 px: 32; 64 px: 16).
    static func tier(pixels: Int) -> Tier {
        switch pixels {
        case ...20:
            // No trail at 16 px: the echoes merge into a smear there. The ring
            // is centred on the body and its outer edge sits on whole pixels
            // (4 px out, 1.25 px wide), round a 2 px lit core with a clear gap.
            return Tier(ringR: 216, ringW: 80, tickLen: 0, tickW: 0, echoes: 0, echoStep: 0, echoSpan: 0,
                        grid: false, control: CGSize(width: 128, height: 128), controlCorner: 40,
                        centre: CGPoint(x: 512, y: 512), glow: 0)
        case ...40:
            // The centre sits at (18.5, 14.5) px so the 1 px ticks and the
            // 5 by 3 px control land on whole pixels; a 7.5 px outer radius
            // then puts both of the ring's edges on whole pixels too, and the
            // longer ticks keep their inner ends where they were.
            return Tier(ringR: 208, ringW: 64, tickLen: 38, tickW: 32, echoes: 2, echoStep: 86, echoSpan: 1.05,
                        grid: false, control: CGSize(width: 160, height: 96), controlCorner: 32,
                        centre: CGPoint(x: 592, y: 464), glow: 30)
        case ...80:
            return Tier(ringR: 184, ringW: 48, tickLen: 32, tickW: 32, echoes: 3, echoStep: 66, echoSpan: 1.1,
                        grid: false, control: CGSize(width: 160, height: 96), controlCorner: 32,
                        centre: CGPoint(x: 576, y: 448), glow: 40)
        default:
            return Tier(ringR: 176, ringW: 32, tickLen: 38, tickW: 22, echoes: 3, echoStep: 64, echoSpan: 1.15,
                        grid: true, control: CGSize(width: 176, height: 108), controlCorner: 32,
                        centre: CGPoint(x: 578, y: 450), glow: 48)
        }
    }

    // MARK: Drawing

    static func draw(in ctx: CGContext, pixels: Int) {
        let tier = Self.tier(pixels: pixels)
        let k = CGFloat(pixels) / 1024  // device pixels per design unit; shadows are in device space
        let b = body
        let shape = squircle(b)
        let c = tier.centre

        // Drop shadow under the body, cast downward (device space is y-up).
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 28 * k, color: cg(0x000000, 0.42))
        ctx.addPath(shape)
        ctx.setFillColor(cg(0x0B1526))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()

        // Field: graphite navy, lit a touch from the top. The bottom is
        // lifted so the tile's silhouette holds on dark Docks and menus.
        ctx.drawLinearGradient(gradient([(0x223047, 1, 0), (0x16233B, 1, 0.45), (0x132038, 1, 1)]),
                               start: CGPoint(x: 0, y: b.minY), end: CGPoint(x: 0, y: b.maxY), options: [])

        // The accent lights the field around the landing point.
        ctx.drawRadialGradient(gradient([(accentDeep, 0.30, 0), (accentDeep, 0.10, 0.45), (accentDeep, 0, 1)]),
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: 470, options: [])

        // Faint viewfinder grid, only where there are pixels to carry it.
        if tier.grid {
            ctx.saveGState()
            ctx.setStrokeColor(cg(0xFFFFFF, 0.035))
            ctx.setLineWidth(2)
            var x = b.minX + 103
            while x < b.maxX {
                ctx.move(to: CGPoint(x: x, y: b.minY))
                ctx.addLine(to: CGPoint(x: x, y: b.maxY))
                x += 103
            }
            var y = b.minY + 103
            while y < b.maxY {
                ctx.move(to: CGPoint(x: b.minX, y: y))
                ctx.addLine(to: CGPoint(x: b.maxX, y: y))
                y += 103
            }
            ctx.strokePath()
            ctx.restoreGState()
        }

        drawControl(in: ctx, tier: tier, pixels: pixels)
        drawTrail(in: ctx, tier: tier, k: k)
        drawReticle(in: ctx, tier: tier, k: k)
        ctx.restoreGState()

        // Edge light: a thin inner rim, brightest along the top and never
        // dark at the bottom, so the outline holds on a dark background. At
        // small sizes it widens to about half a pixel inside the body.
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.addPath(shape)
        ctx.setLineWidth(pixels >= 128 ? 6 : 1024 / CGFloat(pixels) * 1.2)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.22, 0), (0xFFFFFF, 0.10, 0.35), (0xC9DAFF, 0.20, 1)]),
                               start: CGPoint(x: 0, y: b.minY), end: CGPoint(x: 0, y: b.maxY), options: [])
        ctx.restoreGState()
    }

    /// Where the reticle came from, in top-left coordinates: the lower left.
    private static let arrival = CGPoint(x: -0.7071, y: 0.7071)

    /// The control the reticle lands on.
    private static func drawControl(in ctx: CGContext, tier: Tier, pixels: Int) {
        let c = tier.centre
        let control = CGRect(x: c.x - tier.control.width / 2, y: c.y - tier.control.height / 2,
                             width: tier.control.width, height: tier.control.height)
        let path = CGPath(roundedRect: control, cornerWidth: tier.controlCorner, cornerHeight: tier.controlCorner,
                          transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if pixels <= 20 {
            // At 16 px the control is a lit core: the one thing the eye lands on.
            ctx.setFillColor(cg(accentHot))
            ctx.fill(control)
        } else if pixels <= 40 {
            // At 32 px a lit control gives the eye one bright point to land on.
            ctx.drawLinearGradient(gradient([(0xD6EEFF, 1, 0), (0x8CCBFF, 1, 1)]),
                                   start: CGPoint(x: 0, y: control.minY), end: CGPoint(x: 0, y: control.maxY),
                                   options: [])
        } else {
            ctx.drawLinearGradient(gradient([(0x5A6E94, 1, 0), (0x33425F, 1, 1)]),
                                   start: CGPoint(x: 0, y: control.minY), end: CGPoint(x: 0, y: control.maxY),
                                   options: [])
            // Lit from the landing: a cool wash across the whole face.
            ctx.drawRadialGradient(gradient([(accent, 0.50, 0), (accent, 0.22, 0.7), (accent, 0.12, 1)]),
                                   startCenter: c, startRadius: 0, endCenter: c,
                                   endRadius: tier.control.width * 0.75, options: [.drawsAfterEndLocation])
        }
        ctx.restoreGState()
        if pixels > 20 {
            // Hairline edge so the control reads as a raised object.
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(cg(0xFFFFFF, pixels >= 128 ? 0.22 : 0.30))
            ctx.setLineWidth(pixels >= 128 ? 4 : 10)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// The trail: the reticle's own trailing edge, repeated behind it and
    /// fading, as a strobe would catch it coming in from the lower left.
    private static func drawTrail(in ctx: CGContext, tier: Tier, k: CGFloat) {
        guard tier.echoes > 0 else { return }
        let c = tier.centre
        let back = atan2(arrival.y, arrival.x)
        for i in 1...tier.echoes {
            let f = CGFloat(i) / CGFloat(tier.echoes)
            let step = tier.echoStep * CGFloat(i)
            let centre = CGPoint(x: c.x + arrival.x * step, y: c.y + arrival.y * step)
            let span = tier.echoSpan * (1 - 0.18 * (f - 1 / CGFloat(tier.echoes)))
            let arc = CGMutablePath()
            arc.addArc(center: centre, radius: tier.ringR, startAngle: back - span, endAngle: back + span,
                       clockwise: false)
            let alpha = 0.78 - 0.62 * f
            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.setLineWidth(tier.ringW * (1 - 0.55 * f))
            ctx.setStrokeColor(cg(accent, alpha))
            if tier.glow > 0 {
                ctx.setShadow(offset: .zero, blur: tier.glow * 0.6 * k, color: cg(accentDeep, alpha))
            }
            ctx.addPath(arc)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// The reticle: a ring with four inward ticks that point at the control,
    /// like a focus mark.
    private static func drawReticle(in ctx: CGContext, tier: Tier, k: CGFloat) {
        let c = tier.centre
        let ring = CGMutablePath()
        ring.addEllipse(in: CGRect(x: c.x - tier.ringR, y: c.y - tier.ringR,
                                   width: tier.ringR * 2, height: tier.ringR * 2))
        let ticks = CGMutablePath()
        if tier.tickLen > 0 {
            // Each tick starts a quarter of the stroke inside the ring's inner
            // edge, so it joins the ring without a seam.
            let r0 = tier.ringR - tier.ringW / 2 + tier.ringW * 0.25
            let r1 = r0 - tier.ringW * 0.25 - tier.tickLen
            for i in 0..<4 {
                let a = CGFloat(i) * .pi / 2
                ticks.move(to: CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0))
                ticks.addLine(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
            }
        }
        let mark = CGMutablePath()
        mark.addPath(ring.copy(strokingWithWidth: tier.ringW, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
        mark.addPath(ticks.copy(strokingWithWidth: tier.tickW, lineCap: .round, lineJoin: .round, miterLimit: 10))

        if tier.glow > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: tier.glow * 1.1 * k, color: cg(accentDeep, 1))
            ctx.addPath(mark)
            ctx.setFillColor(cg(accent))
            ctx.fillPath()
            ctx.restoreGState()
        }
        // Solid mark: bright blue, hottest on the side the trail arrives from.
        ctx.saveGState()
        ctx.addPath(mark)
        ctx.clip()
        ctx.setFillColor(cg(accent))
        ctx.fill(body)
        if tier.echoes > 0 {
            let hot = CGPoint(x: c.x + arrival.x * tier.ringR, y: c.y + arrival.y * tier.ringR)
            ctx.drawRadialGradient(gradient([(accentHot, 1, 0), (accentHot, 0.55, 0.4), (accentHot, 0, 1)]),
                                   startCenter: hot, startRadius: 0, endCenter: hot, endRadius: tier.ringR * 1.6,
                                   options: [])
        } else {
            // No trail to arrive from: lit evenly from the top, like the body.
            let reach = tier.ringR + tier.ringW / 2
            ctx.drawLinearGradient(gradient([(accentHot, 0.6, 0), (accentHot, 0, 1)]),
                                   start: CGPoint(x: 0, y: c.y - reach), end: CGPoint(x: 0, y: c.y + reach),
                                   options: [])
        }
        ctx.restoreGState()
    }
}

// MARK: - Social preview

/// 1280 × 640, laid out like a poster: icon and name on the left, the
/// tagline under them, a real product shot on the right, all text inside the
/// centre 1200 × 560.
enum PromoSocialPreview {
    static let size = CGSize(width: 1280, height: 640)

    @MainActor
    static func image(productShot: CGImage) -> CGImage? {
        // The shot: the Studio window and the landed pointer, cropped from
        // the 2× still (stage points × 2).
        let crop = CGRect(x: 392 * 2, y: 134 * 2, width: 760 * 2, height: 590 * 2)
        guard let shot = productShot.cropping(to: crop), let icon = PromoIcon.image(pixels: 512) else { return nil }
        let view = SocialCard(shot: shot, icon: icon)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(size)
        return renderer.cgImage
    }

    struct SocialCard: View {
        let shot: CGImage
        let icon: CGImage

        var body: some View {
            ZStack(alignment: .topLeading) {
                PromoPalette.rgb(PromoPalette.night)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 22) {
                        Image(decorative: icon, scale: 1).resizable().frame(width: 112, height: 112)
                        Text("Thataway")
                            .font(.system(size: 60, weight: .semibold))
                            .tracking(-0.8)
                            .foregroundStyle(Color.white)
                    }
                    Text("Name a control on your Mac and Thataway points at it.")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.86))
                        .lineSpacing(5)
                        .frame(width: 500, alignment: .leading)
                        .padding(.top, 34)
                    Text("Free MIT source · macOS 14 or newer on Apple silicon")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(PromoPalette.rgb(0x8FBFFF))
                        .padding(.top, 26)
                }
                .offset(x: 72, y: 172)

                Image(decorative: shot, scale: 2)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 600, height: 466)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
                    .offset(x: 636, y: 87)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.colorScheme, .dark)
        }
    }
}

#endif
