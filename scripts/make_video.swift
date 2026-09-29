//
//  make_video.swift
//  Thataway
//
//  Cuts Thataway's promo film, its poster and the README loop from the raw takes that
//  scripts/make_media.sh records from the Debug promo stage. Everything is drawn here, so the cut
//  is reproducible and needs no editing app:
//
//  • Footage: the 3072×1728 masters are read with AVAssetReader (BGRA, BT.709) and framed by a
//    virtual camera. Camera keys are in *source* time, from each take's own timeline marks (its
//    JSON sidecar), so a re-recorded take re-cuts itself. Moves ease with smootherstep and zoom is
//    interpolated in log space, so push-ins feel even. Frames are Lanczos-scaled to 1920×1080.
//  • Clicks are never shown. The lesson and Watch me takes carry "cut" marks where a person clicks
//    off camera; every shot in those beats ends before a cut mark and the next starts after it.
//    Between clicks the stage's mouse does not move, so a shot shorter than 1.5 s is lengthened by
//    holding its last frame, which looks the same as the live frames around it.
//  • Cadence: the film is conformed to a constant 30 fps. Each output frame shows one source frame
//    (the 60 fps takes are sampled every other frame), never a blend.
//  • Cards and captions: drawn with CoreText in the brand's look (navy #081427, SF Pro, accent
//    #338CFF). Captions sit in a fixed column on the right, on a frosted plate like the command
//    bar's, and every shot keeps what matters left of that column (Studio shots pin the window's
//    right edge at `columnGapX`). Titles are 60 px and bodies 40 px at 1080p, at most two lines
//    of about 24 characters: about 12 px and 8 px when the frame is shown 390 px wide on a phone.
//  • Legibility on a phone: the pointer flies inside a 1.6x shot that holds the resting mouse,
//    the whole arc and the target (it settles on the mouse 0.55 s before Return, so the eye
//    finds the start), then the camera pushes in to 2.2x on the ring and holds, so the ring and
//    its caption chip are over 60 px tall at 1080p. The refusal is framed at 1.7x, wide enough for
//    the whole sentence, and the Teach Me menu at 2.2x; the Watch me recording is one 1.23x framing that holds the menu bar's
//    counter and the Studio window together.
//  • Transitions: a 0.5 s dissolve where two takes share the Studio window and the next one opens
//    on its still pre-roll in the previous shot's framing, so only the ring changes. Every other
//    beat change dips through the brand navy, so two different frames never blend.
//  • Output: raw BGRA frames are piped to one ffmpeg process that writes the film twice with
//    libx264 (High profile, yuv420p, BT.709, +faststart): the full-quality cut and a lighter web
//    copy for GitHub's inline player. `--gif` writes the README loop's frames losslessly for
//    scripts/make_video.sh to quantize.
//
//  Usage (see scripts/make_video.sh):
//
//    swiftc -O -suppress-warnings -o build/make_video scripts/make_video.swift
//    build/make_video --raw <raw dir> --icon docs/media/icon.png \
//        --out docs/media/thataway-promo.mp4 --out-web docs/media/thataway-promo-web.mp4 \
//        --poster docs/media/thataway-promo-poster.jpg --gif /tmp/hero.mkv \
//        [--fps 30] [--crf 18] [--crf-web 27] [--stills 1.0,5.5 --stills-dir /tmp/qa]
//        [--gif-stills 0,6.5] [--no-video]
//

import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import Foundation

// MARK: - Options

struct Options {
    var raw = ""
    var icon = ""
    var out = ""
    var outWeb = ""
    var poster = ""
    var gif = ""
    var fps = 30
    var gifFPS = 25
    var crf = 18
    var crfWeb = 27
    var preset = "slower"
    var ffmpeg = "/opt/homebrew/bin/ffmpeg"
    var stills: [Double] = []
    var gifStills: [Double] = []
    var stillsDir = ""
    var video = true

    static func parse() -> Options {
        var o = Options()
        var args = Array(CommandLine.arguments.dropFirst())
        func value() -> String {
            guard !args.isEmpty else { fail("missing value") }
            return args.removeFirst()
        }
        func times() -> [Double] { value().split(separator: ",").compactMap { Double($0) } }
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--raw": o.raw = value()
            case "--icon": o.icon = value()
            case "--out": o.out = value()
            case "--out-web": o.outWeb = value()
            case "--poster": o.poster = value()
            case "--gif": o.gif = value()
            case "--fps": o.fps = Int(value()) ?? 30
            case "--gif-fps": o.gifFPS = Int(value()) ?? 25
            case "--crf": o.crf = Int(value()) ?? 18
            case "--crf-web": o.crfWeb = Int(value()) ?? 27
            case "--preset": o.preset = value()
            case "--ffmpeg": o.ffmpeg = value()
            case "--stills": o.stills = times()
            case "--gif-stills": o.gifStills = times()
            case "--stills-dir": o.stillsDir = value()
            case "--no-video": o.video = false
            default: fail("unknown option \(a)")
            }
        }
        if !FileManager.default.isExecutableFile(atPath: o.ffmpeg) { o.ffmpeg = "/usr/local/bin/ffmpeg" }
        guard !o.raw.isEmpty, !o.icon.isEmpty else { fail("--raw and --icon are required") }
        return o
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("make_video: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func warn(_ message: String) {
    FileHandle.standardError.write(("make_video: " + message + "\n").data(using: .utf8)!)
}

let options = Options.parse()

// MARK: - Geometry & easing

let outW = 1920, outH = 1080
let outRect = CGRect(x: 0, y: 0, width: outW, height: outH)
/// The stage masters: 1536×864 pt at 2×. Camera coordinates are master pixels, top-left origin.
let masterW = 3072.0, masterH = 1728.0

func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
/// Smootherstep: zero velocity and acceleration at both ends.
func ease(_ x: Double) -> Double { let t = clamp01(x); return t * t * t * (t * (t * 6 - 15) + 10) }
/// Ease-out cubic, for fades and lifts.
func easeOut(_ x: Double) -> Double { let t = clamp01(x); return 1 - pow(1 - t, 3) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

// MARK: - Rendering context

// Values pass straight through (no color management): the masters are BT.709 video, the cards are
// drawn in sRGB, and everything is blended in encoded space like a conventional video editor.
let ciContext: CIContext = {
    let opts: [CIContextOption: Any] = [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false,
        .highQualityDownsample: true,
    ]
    if let d = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: d, options: opts) }
    return CIContext(options: opts)
}()
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Palette & type (the brand: README, site, social preview)

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func nsColor(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

enum Ink {
    /// The social preview's navy.
    static let navy: UInt32 = 0x081427
    static let navyLift: UInt32 = 0x12264A
    static let primary = nsColor(0xEEF1F5)
    static let secondary = nsColor(0xB7C0CD)
    /// Fine print on navy: at least #9AA4B2, so it holds up when scaled down.
    static let fine = nsColor(0xA2ACBA)
    static let accent: UInt32 = 0x338CFF
    static let badge: UInt32 = 0x0066D9
}

func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

func attributed(_ s: String, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern])
}

// MARK: - Layer drawing

func withAlpha(_ image: CIImage, _ alpha: Double) -> CIImage {
    if alpha >= 0.9999 { return image }
    return image.applyingFilter("CIColorMatrix", parameters: [
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, alpha))),
    ])
}


/// Deterministic noise so every run renders identical grain.
struct Noise {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFF) / 65535.0
    }
}

/// Draws a layer (bottom-left origin, like Core Image) and returns it. `grain` adds fine
/// monochrome noise, scaled by coverage so transparent pixels stay clear.
func makeLayer(width: Int = outW, height: Int = outH, grain: Double = 0, seed: UInt64 = 1,
               _ draw: (CGContext) -> Void) -> CIImage {
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("CGContext") }
    ctx.interpolationQuality = .high
    ctx.setShouldSmoothFonts(false)
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()

    if grain > 0, let data = ctx.data {
        let p = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var noise = Noise(state: seed)
        for i in 0..<(width * height) {
            let a = Double(p[i * 4 + 3])
            if a == 0 { continue }
            let n = (noise.next() + noise.next() - 1) * grain * (a / 255)
            for c in 0..<3 {
                p[i * 4 + c] = UInt8(max(0, min(a, (Double(p[i * 4 + c]) + n).rounded())))
            }
        }
    }
    guard let cg = ctx.makeImage() else { fail("makeImage") }
    return CIImage(cgImage: cg)
}

/// The card backdrop: the brand navy with a faint lift behind the type, a vignette and fine grain.
func cardBackground() -> CIImage {
    makeLayer(grain: 4.5, seed: 7) { ctx in
        ctx.setFillColor(srgb(Ink.navy))
        ctx.fill(outRect)
        let lift = CGGradient(colorsSpace: sRGB, colors: [srgb(Ink.navyLift), srgb(Ink.navy, 0)] as CFArray,
                              locations: [0, 1])!
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) * 0.58)
        ctx.scaleBy(x: 1.7, y: 1)
        ctx.drawRadialGradient(lift, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 620, options: [])
        ctx.restoreGState()
        let vignette = CGGradient(colorsSpace: sRGB, colors: [srgb(0x000000, 0), srgb(0x000000, 0.4)] as CFArray,
                                  locations: [0.55, 1])!
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        ctx.scaleBy(x: 1.78, y: 1)
        ctx.drawRadialGradient(vignette, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 640,
                               options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }
}

let iconImage: CGImage = {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: options.icon) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read icon \(options.icon)") }
    return img
}()

/// The icon PNG carries its own shadow and margin (a 512 canvas around a ~412 px tile); `tile` is
/// the visible tile's size, so lockups are measured by what the eye sees.
func drawIcon(_ ctx: CGContext, tile: CGFloat, center: CGPoint) {
    let canvas = tile * 512 / 412
    ctx.draw(iconImage, in: CGRect(x: center.x - canvas / 2, y: center.y - canvas / 2 - tile * 0.01,
                                   width: canvas, height: canvas))
}

/// Icon + "Thataway" wordmark, centered on `centerY`, the way the social preview sets it.
func drawLockup(_ ctx: CGContext, centerY: CGFloat, tile: CGFloat, wordSize: CGFloat, gap: CGFloat) {
    let font = sans(wordSize, .semibold)
    let word = attributed("Thataway", font, Ink.primary, kern: -wordSize * 0.018)
    let total = tile + gap + word.size().width
    let x0 = (CGFloat(outW) - total) / 2
    drawIcon(ctx, tile: tile, center: CGPoint(x: x0 + tile / 2, y: centerY))
    let baseline = centerY - font.capHeight / 2
    word.draw(at: CGPoint(x: x0 + tile + gap, y: baseline + font.descender))
}

func drawCentered(_ s: NSAttributedString, baselineY: CGFloat, font: NSFont) {
    s.draw(at: CGPoint(x: (CGFloat(outW) - s.size().width) / 2, y: baselineY + font.descender))
}

// MARK: - Caption plates

/// A run in a caption line: plain text or a keycap.
enum Run { case text(String), key(String) }

/// The caption column: a fixed column on the right, and the camera keeps the action left of it
/// (Studio shots pin the window's right edge at `columnGapX`; see `pinKey`). Type is sized for a
/// phone: a 1080p frame shown 390 px wide still leaves about 12 px titles and 8 px bodies.
struct PlateStyle {
    var head = sans(60, .semibold)
    var sub = sans(40, .regular)
    var key = sans(34, .medium)
    var headLine: CGFloat = 68
    var subLine: CGFloat = 52
    var padX: CGFloat = 44
    var padTop: CGFloat = 44
    var padBottom: CGFloat = 40
    var width: CGFloat = 600
    var top: CGFloat = 388          // plate top, measured down from the frame's top edge
    var rightMargin: CGFloat = 44
    var radius: CGFloat = 24        // the command bar's 12 pt corners at 2×
}

/// Output x where the app window's right edge is pinned; the column starts 44 px to its right.
let columnGapX = 1232.0

func runWidth(_ r: Run, _ style: PlateStyle) -> CGFloat {
    switch r {
    case .text(let s): return attributed(s, style.sub, Ink.secondary).size().width
    case .key(let s): return attributed(s, style.key, Ink.primary).size().width + style.key.pointSize * 0.95
    }
}

func lineWidth(_ line: [Run], _ style: PlateStyle) -> CGFloat { line.map { runWidth($0, style) }.reduce(0, +) }

/// Draws one subline of runs, left-aligned at `x`.
func drawRuns(_ ctx: CGContext, _ runs: [Run], baseline: CGFloat, x x0: CGFloat, style: PlateStyle) {
    var x = x0
    let k = style.key.pointSize
    for r in runs {
        switch r {
        case .text(let s):
            let a = attributed(s, style.sub, Ink.secondary)
            a.draw(at: CGPoint(x: x, y: baseline + style.sub.descender))
            x += a.size().width
        case .key(let s):
            let a = attributed(s, style.key, Ink.primary)
            let w = a.size().width + k * 0.95
            let cap = CGRect(x: x + k * 0.1, y: baseline - k * 0.34, width: w - k * 0.2, height: k * 1.46)
            ctx.addPath(CGPath(roundedRect: cap, cornerWidth: k * 0.26, cornerHeight: k * 0.26, transform: nil))
            ctx.setFillColor(srgb(0xFFFFFF, 0.12))
            ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: cap.insetBy(dx: 1, dy: 1), cornerWidth: k * 0.26 - 1,
                               cornerHeight: k * 0.26 - 1, transform: nil))
            ctx.setStrokeColor(srgb(0xFFFFFF, 0.24))
            ctx.setLineWidth(2)
            ctx.strokePath()
            a.draw(at: CGPoint(x: cap.midX - a.size().width / 2,
                               y: cap.midY - style.key.capHeight / 2 + style.key.descender - 0.5))
            x += w
        }
    }
}

/// A caption: the plate's tint, rim and type as one layer, and the plate's shape as a mask for the
/// frosted backdrop (the footage behind it, blurred, as the command bar's material does).
struct Plate {
    let layer: CIImage
    let mask: CIImage
    let rect: CGRect
}

/// A caption plate at the top of the column: an accent rule, a title of one or two lines, then the
/// sublines. With `icon`, the title is led by the app icon and the rule is dropped.
func captionPlate(_ title: [String], _ lines: [[Run]], style: PlateStyle = PlateStyle(), icon: Bool = false) -> Plate {
    let heads = title.map { attributed($0, style.head, Ink.primary, kern: -0.5) }
    let iconTile: CGFloat = icon ? style.head.capHeight * 1.9 : 0
    let iconGap: CGFloat = icon ? 18 : 0
    let textW = style.width - style.padX * 2
    for (i, h) in heads.enumerated() where h.size().width + (i == 0 ? iconTile + iconGap : 0) > textW + 0.5 {
        warn("caption title “\(title[i])” is \(Int(h.size().width)) px (column \(Int(textW)))")
    }
    for line in lines where lineWidth(line, style) > textW + 0.5 {
        warn("caption line in “\(title.joined(separator: " "))” is \(Int(lineWidth(line, style))) px (column \(Int(textW)))")
    }
    let rule: CGFloat = icon ? 0 : 5
    let ruleGap: CGFloat = icon ? 0 : 24
    let headToSub: CGFloat = 62
    let height = (style.padTop + rule + ruleGap + style.head.capHeight
        + CGFloat(max(0, heads.count - 1)) * style.headLine
        + (lines.isEmpty ? 0 : headToSub + CGFloat(lines.count - 1) * style.subLine)
        + style.padBottom).rounded()
    let plate = CGRect(x: CGFloat(outW) - style.rightMargin - style.width, y: CGFloat(outH) - style.top - height,
                       width: style.width, height: height)
    let path = CGPath(roundedRect: plate, cornerWidth: style.radius, cornerHeight: style.radius, transform: nil)
    let layer = makeLayer(grain: 2.5, seed: 11) { ctx in
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 40, color: srgb(0x000000, 0.35))
        ctx.addPath(path)
        ctx.setFillColor(srgb(0x0A1528, 0.74))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let sheen = CGGradient(colorsSpace: sRGB, colors: [srgb(0xFFFFFF, 0.06), srgb(0xFFFFFF, 0)] as CFArray,
                               locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.midY), options: [])
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: 0.75, dy: 0.75), cornerWidth: style.radius - 0.75,
                           cornerHeight: style.radius - 0.75, transform: nil))
        ctx.setStrokeColor(srgb(0xFFFFFF, 0.14))
        ctx.setLineWidth(1.5)
        ctx.strokePath()

        let x0 = plate.minX + style.padX
        var y = plate.maxY - style.padTop
        if rule > 0 {
            let bar = CGRect(x: x0, y: y - rule, width: 44, height: rule)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: rule / 2, cornerHeight: rule / 2, transform: nil))
            ctx.setFillColor(srgb(Ink.accent))
            ctx.fillPath()
            y -= rule + ruleGap
        }
        var baseline = y - style.head.capHeight
        for (i, h) in heads.enumerated() {
            if i == 0 && icon {
                drawIcon(ctx, tile: iconTile, center: CGPoint(x: x0 + iconTile / 2, y: baseline + style.head.capHeight / 2))
            }
            h.draw(at: CGPoint(x: x0 + (i == 0 ? iconTile + iconGap : 0), y: baseline + style.head.descender))
            if i < heads.count - 1 { baseline -= style.headLine }
        }
        baseline -= headToSub
        for line in lines {
            drawRuns(ctx, line, baseline: baseline, x: x0, style: style)
            baseline -= style.subLine
        }
    }
    let mask = makeLayer { ctx in
        ctx.addPath(path)
        ctx.setFillColor(srgb(0xFFFFFF))
        ctx.fillPath()
    }
    return Plate(layer: layer, mask: mask, rect: plate)
}

/// Frosts the footage under a plate and lays the plate over it, at opacity `alpha`, lifted `lift` px.
func applyPlate(_ plate: Plate, over frame: CIImage, alpha: Double, lift: Double = 0) -> CIImage {
    let move = CGAffineTransform(translationX: 0, y: -lift)
    let blurred = frame.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 26])
        .cropped(to: outRect)
    let frosted = blurred.applyingFilter("CIBlendWithAlphaMask", parameters: [
        kCIInputBackgroundImageKey: frame,
        kCIInputMaskImageKey: withAlpha(plate.mask.transformed(by: move), alpha),
    ])
    return withAlpha(plate.layer.transformed(by: move), alpha).composited(over: frosted).cropped(to: outRect)
}

// MARK: - Cards

struct CardItem {
    let image: CIImage
    /// Seconds after the card starts that this item begins to fade and rise in.
    let delay: Double
    let rise: Double
    var duration: Double = 0.8
}

struct Card {
    let start: Double
    let end: Double
    let fadeIn: Double
    let fadeOut: Double
    let background: CIImage
    let items: [CardItem]
    /// When set, the items have faded out by this time (over `itemsFade`), so the card's own
    /// fade-out shows plain navy and the next shot rises from it with no type ghosting over it.
    var itemsOutBy: Double? = nil
    var itemsFade: Double = 0.4
}

let tagline = "Name a control on your Mac and Thataway points at it."

func titleCard(start: Double, end: Double) -> Card {
    let lockup = makeLayer { ctx in drawLockup(ctx, centerY: 604, tile: 150, wordSize: 150, gap: 40) }
    let tag = makeLayer { ctx in
        let f = sans(56, .medium)
        drawCentered(attributed(tagline, f, Ink.primary, kern: -0.6), baselineY: 404, font: f)
    }
    // The navy comes up over the cold open first; the lockup rises only once the desktop is gone,
    // and the type is gone again before the navy dissolves into the first shot, so the wordmark
    // never sits over window text.
    return Card(start: start, end: end, fadeIn: 0.5, fadeOut: 0.5, background: cardBackground(), items: [
        CardItem(image: lockup, delay: 0.6, rise: 18, duration: 0.7),
        CardItem(image: tag, delay: 0.85, rise: 12, duration: 0.7),
    ], itemsOutBy: end - 0.5)
}

func endCard(start: Double, end: Double) -> Card {
    // Sized for a phone: the URL is 46 px and the smallest line 36 px at 1080p.
    let lockup = makeLayer { ctx in drawLockup(ctx, centerY: 846, tile: 112, wordSize: 112, gap: 30) }
    let lines = makeLayer { ctx in
        let f = sans(54, .semibold)
        drawCentered(attributed(tagline, f, Ink.primary, kern: -0.5), baselineY: 676, font: f)
        let g = sans(38, .regular)
        drawCentered(attributed("Your own cursor stays where it is, nothing gets clicked,", g, Ink.secondary),
                     baselineY: 604, font: g)
        drawCentered(attributed("and what is on your screen stays on your Mac.", g, Ink.secondary),
                     baselineY: 552, font: g)
    }
    let action = makeLayer { ctx in
        // The repo address on an accent pill with a drawn arrow. Nothing is for sale and there is
        // no download yet, so the card points at the source.
        let lf = sans(46, .semibold)
        let label = attributed("github.com/jke48222/thataway", lf, nsColor(0xFFFFFF), kern: -0.2)
        let lw = label.size().width
        let arrowW: CGFloat = 30
        let pillW = 52 + lw + 22 + arrowW + 46
        let pillH: CGFloat = 104
        let pill = CGRect(x: ((CGFloat(outW) - pillW) / 2).rounded(), y: 364, width: pillW.rounded(), height: pillH)
        let path = CGPath(roundedRect: pill, cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 26, color: srgb(0x000000, 0.45))
        ctx.addPath(path)
        ctx.setFillColor(srgb(Ink.badge))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let dome = CGGradient(colorsSpace: sRGB, colors: [srgb(0x2B7FF0), srgb(Ink.badge)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(dome, start: CGPoint(x: 0, y: pill.maxY), end: CGPoint(x: 0, y: pill.minY), options: [])
        ctx.restoreGState()
        label.draw(at: CGPoint(x: pill.minX + 52, y: pill.midY - lf.capHeight / 2 + lf.descender))
        let ax = pill.minX + 52 + lw + 22
        let ay = pill.midY
        ctx.setStrokeColor(srgb(0xFFFFFF))
        ctx.setLineWidth(4)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: ax, y: ay)); ctx.addLine(to: CGPoint(x: ax + arrowW, y: ay))
        ctx.move(to: CGPoint(x: ax + arrowW - 12, y: ay + 12)); ctx.addLine(to: CGPoint(x: ax + arrowW, y: ay))
        ctx.addLine(to: CGPoint(x: ax + arrowW - 12, y: ay - 12))
        ctx.strokePath()

        let g = sans(38, .medium)
        drawCentered(attributed("Free to build from source today (MIT). A signed app is planned for 1.0.", g,
                                Ink.primary.withAlphaComponent(0.92), kern: 0.1), baselineY: 262, font: g)
    }
    // One line of requirements. The model credit and the vision fallback's needs are in the README
    // and on the site, where they can be read at full size.
    let fine = makeLayer { ctx in
        let f = sans(36, .regular)
        drawCentered(attributed("macOS 14 or newer on Apple silicon  \u{00B7}  Accessibility permission", f, Ink.fine,
                                kern: 0.1), baselineY: 150, font: f)
    }
    return Card(start: start, end: end, fadeIn: 0.55, fadeOut: 0, background: cardBackground(), items: [
        // The type rises only once the navy is opaque, so nothing is laid over the last shot.
        CardItem(image: lockup, delay: 0.6, rise: 20),
        CardItem(image: lines, delay: 0.85, rise: 14),
        CardItem(image: action, delay: 1.1, rise: 10),
        CardItem(image: fine, delay: 1.3, rise: 0),
    ])
}

// MARK: - Footage

/// Sequential frame access into one master movie, re-seeking only when asked to jump.
final class FrameSource {
    let url: URL
    let asset: AVURLAsset
    let track: AVAssetTrack
    let duration: Double
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: (t: Double, buffer: CVPixelBuffer)?
    private var pending: (t: Double, buffer: CVPixelBuffer)?
    private var ended = false

    init(_ url: URL) {
        self.url = url
        asset = AVURLAsset(url: url)
        guard let t = asset.tracks(withMediaType: .video).first else { fail("no video track in \(url.path)") }
        track = t
        duration = asset.duration.seconds
    }

    private func open(at s: Double) {
        reader?.cancelReading()
        guard let r = try? AVAssetReader(asset: asset) else { fail("reader for \(url.lastPathComponent)") }
        let start = max(0, s - 0.05)
        r.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: asset.duration)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        o.alwaysCopiesSampleData = false
        r.add(o)
        guard r.startReading() else { fail("startReading \(url.lastPathComponent): \(String(describing: r.error))") }
        reader = r
        output = o
        current = nil
        pending = nil
        ended = false
    }

    private func pull() -> (t: Double, buffer: CVPixelBuffer)? {
        guard !ended, let o = output else { return nil }
        while let sample = o.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(sample) {
                return (CMSampleBufferGetPresentationTimeStamp(sample).seconds, pb)
            }
        }
        ended = true
        return nil
    }

    /// The frame showing at source time `s` (the last frame whose timestamp is ≤ s).
    func frame(at s: Double) -> CVPixelBuffer {
        let s = min(max(0, s), duration)
        if reader == nil { open(at: s) }
        if let c = current, s < c.t - 1e-4 || s > c.t + 1.0 { open(at: s) }
        if current == nil { current = pull() }
        while true {
            if pending == nil { pending = pull() }
            guard let p = pending, p.t <= s + 1e-4 else { break }
            current = p
            pending = nil
        }
        guard let c = current else { fail("no frames in \(url.lastPathComponent) near \(s)") }
        return c.buffer
    }
}

/// The stage flips its top-left pixel every frame (the recorder's heartbeat). Paint it over with
/// its neighbours so it never flickers in a wide shot.
func master(_ source: FrameSource, at s: Double) -> CIImage {
    let image = CIImage(cvPixelBuffer: source.frame(at: s))
    let patch = image.cropped(to: CGRect(x: 6, y: masterH - 6, width: 6, height: 6))
        .transformed(by: CGAffineTransform(translationX: -6, y: 0))
    return patch.composited(over: image)
}

// MARK: - Takes

let rawDir = URL(fileURLWithPath: options.raw)

/// One recorded take and its timeline (the recorder's sidecar JSON), in source seconds.
struct Take {
    let name: String
    let source: FrameSource
    let sceneStart: Double
    let duration: Double
    let marks: [(event: String, t: Double, note: String)]
    /// Where the person's mouse rests in this take, in master pixels (the stage logs it in stage
    /// points; takes from before it did rested at (262, 716) pt).
    let mouse: CGPoint

    init(_ name: String) {
        self.name = name
        let url = rawDir.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = doc["marks"] as? [[String: Any]] else { fail("cannot read \(url.path)") }
        sceneStart = doc["sceneStart"] as? Double ?? 0.6
        let rest = doc["mouseRest"] as? [Double] ?? [262, 716]
        mouse = CGPoint(x: rest[0] * 2, y: rest[1] * 2)
        duration = doc["duration"] as? Double ?? 0
        marks = list.compactMap { m in
            guard let e = m["event"] as? String, let t = m["t"] as? Double else { return nil }
            return (e, t, m["note"] as? String ?? "")
        }
        source = FrameSource(rawDir.appendingPathComponent("\(name).mov"))
    }

    func has(_ event: String) -> Bool { marks.contains { $0.event == event } }

    /// The `n`th (1-based) mark named `event`.
    func t(_ event: String, _ n: Int = 1) -> Double {
        let hits = marks.filter { $0.event == event }
        guard hits.count >= n else { fail("\(name).json has no mark “\(event)” #\(n)") }
        return hits[n - 1].t
    }
}

// MARK: - Camera

/// A camera key in source time: zoom (1 = the whole master) and the crop's center, in master
/// pixels (top-left origin). Between keys the camera eases; equal neighbouring keys hold.
struct CamKey {
    let t: Double
    let zoom: Double
    let cx: Double
    let cy: Double
}

/// A key that pins master x `edge` (default: the Studio window's right edge) at output x `at`
/// (default: the caption column's gap), with the crop's top at master y `top`.
func pinKey(_ t: Double, _ zoom: Double, edge: Double = 2256, at: Double = columnGapX, top: Double) -> CamKey {
    let s = Double(outW) / (masterW / zoom)
    let w = masterW / zoom, h = masterH / zoom
    let left = edge - at / s
    if left < -0.5 || left + w > masterW + 0.5 || top < -0.5 || top + h > masterH + 0.5 {
        warn(String(format: "pinKey at %.2f (zoom %.2f, top %.0f) leaves the master; the crop will be clamped", t, zoom, top))
    }
    return CamKey(t: t, zoom: zoom, cx: left + w / 2, cy: top + h / 2)
}

/// A key whose crop hugs the master's right edge (the status menu and clock stay in frame), with
/// its top at `top`. Used where the menu bar is in shot: the zooms below put the crop's left edge
/// in a gap between menu titles, so no word is cut.
func rightKey(_ t: Double, _ zoom: Double, top: Double = 0) -> CamKey {
    CamKey(t: t, zoom: zoom, cx: masterW - masterW / zoom / 2, cy: top + masterH / zoom / 2)
}

func camera(_ keys: [CamKey], at s: Double) -> (zoom: Double, cx: Double, cy: Double) {
    guard let first = keys.first, let last = keys.last else { return (1, masterW / 2, masterH / 2) }
    if s <= first.t { return (first.zoom, first.cx, first.cy) }
    if s >= last.t { return (last.zoom, last.cx, last.cy) }
    var i = 0
    while i + 1 < keys.count && keys[i + 1].t < s { i += 1 }
    let a = keys[i], b = keys[i + 1]
    let u = ease((s - a.t) / (b.t - a.t))
    return (exp(lerp(log(a.zoom), log(b.zoom), u)), lerp(a.cx, b.cx, u), lerp(a.cy, b.cy, u))
}

/// Frames a master-sized image into 1920×1080 with the camera.
func frame(_ image: CIImage, zoom: Double, cx: Double, cy: Double) -> CIImage {
    let w = masterW / zoom, h = masterH / zoom
    let x = min(max(0, cx - w / 2), masterW - w)
    let yTop = min(max(0, cy - h / 2), masterH - h)
    let yCI = masterH - yTop - h
    let scale = Double(outW) / w
    return image
        .clampedToExtent()
        .transformed(by: CGAffineTransform(translationX: -x, y: -yCI))
        .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        .cropped(to: outRect)
}

// MARK: - Clips

/// Where a clip's pictures come from: a recorded take, or one of the stage's own stills (the
/// same view hierarchy, drawn off screen), for an insert of something no take shows.
enum Source {
    case take(Take)
    case still(name: String, image: CIImage)

    var name: String {
        switch self {
        case .take(let t): return t.name
        case .still(let n, _): return n
        }
    }

    func image(at s: Double) -> CIImage {
        switch self {
        case .take(let t): return master(t.source, at: s)
        case .still(_, let image): return image
        }
    }
}

struct Clip {
    let source: Source
    /// Source in and out. When the clip runs longer than out - in, the frame at `srcOut` holds.
    let srcIn: Double
    let srcOut: Double
    let outStart: Double
    let outEnd: Double
    /// Cross-dissolve from the clip underneath (0 for a hard cut).
    let dissolve: Double
    let keys: [CamKey]

    func srcTime(_ t: Double) -> Double { min(srcIn + (t - outStart), srcOut) }

    func picture(at t: Double) -> CIImage {
        let s = srcTime(t)
        let cam = camera(keys, at: s)
        return frame(source.image(at: s), zoom: cam.zoom, cx: cam.cx, cy: cam.cy)
    }
}

/// Lays clips end to end. `dissolve` overlaps a clip with the one before it; `hold` lengthens a
/// clip past its source out point by holding the last frame; `dip()` joins the next clip to the
/// last one through the brand navy.
final class Timeline {
    private(set) var clips: [Clip] = []
    /// Film times where the picture dips through navy (full navy at that instant).
    private(set) var dips: [Double] = []
    var end: Double

    init(start: Double) { end = start }

    @discardableResult
    func add(_ take: Take, _ srcIn: Double, _ srcOut: Double, hold: Double = 0, dissolve: Double = 0,
             keys: [CamKey]) -> Clip {
        add(.take(take), srcIn, srcOut, hold: hold, dissolve: dissolve, keys: keys)
    }

    @discardableResult
    func add(_ source: Source, _ srcIn: Double, _ srcOut: Double, hold: Double = 0, dissolve: Double = 0,
             keys: [CamKey]) -> Clip {
        precondition(srcOut > srcIn, "\(source.name): out \(srcOut) before in \(srcIn)")
        let start = end - dissolve
        let clip = Clip(source: source, srcIn: srcIn, srcOut: srcOut, outStart: start,
                        outEnd: start + (srcOut - srcIn) + hold, dissolve: dissolve, keys: keys)
        if clip.outEnd - clip.outStart < 1.5 - 1e-6 {
            warn(String(format: "%@ shot at %.2f is %.2f s (under 1.5 s)", source.name, start, clip.outEnd - clip.outStart))
        }
        clips.append(clip)
        end = clip.outEnd
        return clip
    }

    /// The next clip starts where the last one ends, both faded through navy around that instant.
    func dip() { dips.append(end) }

    /// Film time of source time `s` in `clip`.
    func film(_ clip: Clip, _ s: Double) -> Double { clip.outStart + (s - clip.srcIn) }
}

// MARK: - The edit
//
// Cold open on the desktop at rest → the navy comes up → title card (its type fades before the
// navy dissolves into the first shot) → one beat per pillar:
//   1 hero: Option Space, "the Share button" typed (the shortlist re-ranks as it is typed), in
//     one 1.56x to 1.6x shot of the bar, the resting mouse and Share that settles 0.55 s before
//     Return; the pointer arcs at real speed; the camera pushes in to 2.2x on the solid ring and
//     holds;
//   2 uncertain (matched dissolve): "the access menu" lands on Link access with a dashed amber
//     ring and "Link access?", framed the same way;
//   3 excluded (dip through navy): a window titled "Online Banking" gets the refusal and no
//     pointer; the camera pushes in to 1.7x on the bar, under the page heading, and holds;
//   4 lesson (dip through navy): steps 1 to 3, cut only at the take's click marks, then the dim
//     lifts with the person's mouse already off the switch;
//   5 Watch me (dip through navy): one 1.23x framing of the menu bar's counter and Studio, at 0
//     steps and then at 3, then the Teach Me menu with the saved lesson highlighted
// → end card. Every time below is a source time from the takes' own marks.
//
// Stage geometry, in master pixels (top-left origin): the Studio window is x 816–2256,
// y 300–1420; the person's mouse rests where each take's sidecar says ((1280, 1240) since the
// stage logs it, between the footnote and the bottom buttons; (524, 1432) in older takes); Share's ring is centred near (2100, 1342) and Link access's near (1948, 648); the
// command bar is x 976–2096 from y 519 (to about 770 with the shortlist); the browser's page
// heading is at y 465–503 and the refusal line at y 619. In the Watch me take the status menu's
// status lines end at y 215, so the Teach Me shot's crop starts at y 238.

let hero = Take("hero")
let uncertain = Take("uncertain")
let excluded = Take("excluded")
let lesson = Take("lesson")
let watchme = Take("watchme")

let studioEdge = 2256.0
/// Crop tops below the menu bar (y 0–58), for shots that leave it out.
let belowMenu = 62.0
/// Right-anchored zoom whose left edge falls between menu titles (measured on the master: View
/// ends at x 404 and Window starts at 447).
let menuZoomWide = 1.1606   // left edge x 425
/// Margin kept around a click mark, so no shot shows the frame where the stage changes.
let cutPad = 0.05
/// Studio animates its own response to some clicks (a pane crossfade, the sheet sliding in) for
/// about 0.3 s (measured on the takes). Shots after a click start once it has settled.
let settle = 0.33
let beatDissolve = 0.5
/// Each side of a dip through navy.
let dipHalf = 0.25
/// The push-in on a landed pointer.
let pushZoom = 2.2
/// Studio shots pin the window's right edge at `columnGapX`; below 1.35x that crop would run off
/// the master's right edge. Typing is framed at 1.36x with the whole window height in shot.
let typeZoom = 1.36
let typeTop = 155.0
/// The push-in runs from 0.15 s to `pushEnd` after landing. The caption waits until it is about
/// 87% done (`capAfterLanding`), when the window's right edge is left of the caption column.
let pushEnd = 1.1
let capAfterLanding = 0.85
/// The flight framing's slow push (1.56x to 1.6x) ends this long before Return, so the frame is
/// still on the resting mouse when the pointer leaves it.
let flightSettle = 0.55

let coldEnd = 2.4
let titleStart = 1.9
let titleEnd = 5.6

/// What a flight shot must hold, in master pixels: the bar with its shortlist, Share's and Link
/// access's rings with their captions, and the resting mouse (its arrow is about 40 × 60).
func actionBox(_ take: Take) -> CGRect {
    let targets = CGRect(x: 976, y: 519, width: 2278 - 976, height: 1392 - 519)
    return targets.union(CGRect(x: take.mouse.x, y: take.mouse.y, width: 40, height: 60))
}

/// The flight framing: 1.6x (a 1920 × 1080 crop, so the drawn pointer is over 24 px tall at
/// 1080p), centred on the action box. Typing and the flight share it, so the camera is on the
/// resting mouse the whole time before Return and the arc is seen whole, mouse to ring. The
/// caption column covers only window rows below the bar while the query is typed.
func flightKey(_ t: Double, _ take: Take, zoom: Double = 1.6) -> CamKey {
    let box = actionBox(take)
    let w = masterW / zoom, h = masterH / zoom
    if box.width > w || box.height > h { warn("the flight's action box does not fit a \(zoom)x crop") }
    let cx = min(max(box.midX, w / 2), masterW - w / 2)
    let cy = min(max(box.midY, h / 2), masterH - h / 2)
    return CamKey(t: t, zoom: zoom, cx: cx, cy: cy)
}

/// A key that puts master point (x, y) at output (atX, atY).
func focusKey(_ t: Double, _ zoom: Double, x: Double, y: Double, atX: Double, atY: Double = 540) -> CamKey {
    let s = Double(outW) / (masterW / zoom)
    let w = masterW / zoom, h = masterH / zoom
    let left = x - atX / s, top = y - atY / s
    if left < -0.5 || left + w > masterW + 0.5 || top < -0.5 || top + h > masterH + 0.5 {
        warn(String(format: "focusKey at %.2f (zoom %.2f) leaves the master; the crop will be clamped", t, zoom))
    }
    return CamKey(t: t, zoom: zoom, cx: left + w / 2, cy: top + h / 2)
}

/// A key whose crop's top-left corner is master (left, top).
func cornerKey(_ t: Double, _ zoom: Double, left: Double, top: Double) -> CamKey {
    CamKey(t: t, zoom: zoom, cx: left + masterW / zoom / 2, cy: top + masterH / zoom / 2)
}

let timeline = Timeline(start: titleEnd - beatDissolve)

// 1. Hero. Typing and the flight share one 1.6x shot; the landing is pushed in on.
let heroSummon = hero.t("summon"), heroTyped = hero.t("typed"), heroReturn = hero.t("return")
let heroLanded = hero.t("landed")
let heroIn = heroSummon - 0.35
let heroOut = heroLanded + 3.25
/// Share's ring, left of the caption column. The uncertain take opens in this framing.
let heroEndKey = focusKey(heroOut, pushZoom, x: 2100, y: 1335, atX: 900)
let heroClip = timeline.add(hero, heroIn, heroOut, keys: [
    flightKey(heroIn, hero, zoom: 1.56),
    flightKey(heroReturn - flightSettle, hero),
    flightKey(heroLanded + 0.15, hero),
    focusKey(heroLanded + pushEnd, pushZoom, x: 2100, y: 1335, atX: 900),
    heroEndKey,
])

// 2. Uncertain. It opens on its still pre-roll in the hero's last framing (a matched dissolve:
// only the ring fades), pulls back to the flight framing before Option Space, then moves as the
// hero does.
let uncSummon = uncertain.t("summon"), uncTyped = uncertain.t("typed"), uncReturn = uncertain.t("return")
let uncLanded = uncertain.t("landed")
let uncIn = uncSummon - 1.3
let uncOut = uncLanded + 3.3
let uncClip = timeline.add(uncertain, uncIn, uncOut, dissolve: beatDissolve, keys: [
    CamKey(t: uncIn + beatDissolve, zoom: heroEndKey.zoom, cx: heroEndKey.cx, cy: heroEndKey.cy),
    flightKey(uncSummon - 0.1, uncertain, zoom: 1.56),
    flightKey(uncReturn - flightSettle, uncertain),
    flightKey(uncLanded + 0.15, uncertain),
    focusKey(uncLanded + pushEnd, pushZoom, x: 1948, y: 648, atX: 800),
    focusKey(uncOut, pushZoom, x: 1948, y: 648, atX: 800),
])

// 3. Excluded: the browser at rest, the bar arrives, then a push-in to 1.7x that keeps the page
// heading at the top of the frame and the whole refusal line, which runs from about x 966 to
// 2445 on the master, above the caption plate. A closer push cut the sentence off. The take's
// refused state is still apart from the caret, so the last frame holds to give the caption 4.2 s.
timeline.dip()
let excRefused = excluded.t("refused")
let excIn = excRefused - 0.6
let excOut = excluded.t("dismissed") - 0.15
let excClip = timeline.add(excluded, excIn, excOut, hold: 1.3, keys: [
    CamKey(t: excIn, zoom: 1.25, cx: 1536, cy: 110 + masterH / 1.25 / 2),
    CamKey(t: excRefused + 0.3, zoom: 1.25, cx: 1536, cy: 110 + masterH / 1.25 / 2),
    cornerKey(excRefused + 2.3, 1.7, left: 680, top: 400),
])

// 4. Lesson: three steps, each shot ending before the next click, then the dim lifts. The shot
// framing changes at every cut (1.36 → 1.62 → 1.6 → 1.16, each on a different part of the window),
// so no cut is a jump cut. Step 1 shows the whole window, with the resting mouse the pointer
// leaves from; step 2 is a close-up on Advanced Options (x 872–1207, y 1342) at the lower left and
// step 3 on the Link Settings sheet (x 1120–1960), where the plate covers only the dimmed
// right-hand rows. The last shot starts once the switch is on and the person's mouse has moved
// off it (the take parks it off the window inside the cut), so the only arrow on the switch is
// the drawn pointer until the dim lifts.
timeline.dip()
let lesStep1 = lesson.t("step", 1), lesStep2 = lesson.t("step", 2), lesStep3 = lesson.t("step", 3)
let lesCut1 = lesson.t("cut", 1), lesCut2 = lesson.t("cut", 2), lesCut3 = lesson.t("cut", 3)
let lesDone = lesson.t("done")
let lesA = timeline.add(lesson, lesStep1 - 0.3, lesCut1 - 0.35, keys: [
    pinKey(lesStep1 - 0.3, typeZoom, top: typeTop),
    pinKey(lesCut1, typeZoom * 1.02, top: typeTop),
])
let lesB = timeline.add(lesson, lesCut1 + settle, lesStep2 + 2.2, keys: [
    focusKey(lesCut1, 1.62, x: 1040, y: 1342, atX: 560, atY: 760),
    focusKey(lesStep2 + 2.2, 1.66, x: 1040, y: 1342, atX: 560, atY: 760),
])
let lesC = timeline.add(lesson, lesCut2 + settle, lesStep3 + 1.9, keys: [
    focusKey(lesCut2, 1.6, x: 1540, y: 730, atX: 650, atY: 540),
    focusKey(lesStep3 + 1.9, 1.64, x: 1540, y: 730, atX: 650, atY: 540),
])
// A take from before the stage parked the mouse has it on the switch next to the drawn pointer
// until the lesson ends, so its last shot starts once the dim has lifted.
let lesDIn = lesson.has("parked") ? lesCut3 + settle : lesDone + 0.1
let lesD = timeline.add(lesson, lesDIn, lesDone + 1.4, hold: max(0, 1.5 - (lesDone + 1.4 - lesDIn)), keys: [
    rightKey(lesCut3, menuZoomWide),
])

// 5. Watch me: one 1.23x framing, top at the menu bar and anchored right, so "Recording: N steps"
// and the Studio window's controls share the frame: 0 steps, then (hard cut, same framing) 3
// steps with the sheet's switch on. The stage is still between clicks, so each shot holds its
// last frame to 2 s. Then the Teach Me menu, framed below the status menu's status lines, with
// the saved lesson highlighted, held until the end card.
timeline.dip()
let wmCut = (1...4).map { watchme.t("cut", $0) }
/// 1.2303x anchored right puts the crop's left edge in the gap before "Help" (x 575) and keeps
/// Advanced Options (bottom y 1372) in frame.
let wmZoom = 1.2303
func wmShot(_ a: Double, _ b: Double, atLeast: Double) -> Clip {
    timeline.add(watchme, a, b, hold: max(0, atLeast - (b - a)), keys: [rightKey(0, wmZoom)])
}
let wmA = wmShot(0.25, wmCut[0] - cutPad, atLeast: 2.3)
let wmC = wmShot(wmCut[2] + settle, wmCut[3] - cutPad, atLeast: 2.05)
let wmD = timeline.add(watchme, wmCut[3] + 0.12, wmCut[3] + 2.9, keys: [rightKey(0, pushZoom, top: 238)])

let endStart = timeline.end - 0.55
let totalDuration = ((endStart + 5.6) * 30).rounded() / 30

/// The cold open: the hero take's still pre-roll, the desktop at rest, with a slow push.
let coldKeys = [CamKey(t: 0, zoom: 1.0, cx: 1536, cy: 864), CamKey(t: coldEnd, zoom: 1.07, cx: 1600, cy: belowMenu + masterH / 1.07 / 2)]
func coldPicture(_ t: Double) -> CIImage {
    let cam = camera(coldKeys, at: t)
    return frame(master(hero.source, at: 0.3), zoom: cam.zoom, cx: cam.cx, cy: cam.cy)
}

// MARK: - Captions

struct Caption {
    let start: Double
    let end: Double
    let plate: Plate
}

let fadeInCap = 0.45, fadeOutCap = 0.35

func cap(_ start: Double, _ end: Double, _ title: [String], _ lines: [[Run]]) -> Caption {
    Caption(start: start, end: end, plate: captionPlate(title, lines))
}

func text(_ lines: String...) -> [[Run]] { lines.map { [.text($0)] } }

// The pillars' titles and one clause each, at most two lines, each about what is on screen. No
// caption is up while the pointer flies (the flight shot needs the whole frame) or across a dip,
// and the first waits until the title card has dissolved into the footage.
let captions: [Caption] = [
    cap(max(titleEnd + 0.15, timeline.film(heroClip, heroIn + 0.3)), timeline.film(heroClip, heroTyped + 0.1),
        ["Say or type", "a control"],
        [[.text("Press "), .key("\u{2325}"), .text(" "), .key("Space"), .text(" and type.")]]),
    cap(timeline.film(heroClip, heroLanded + capAfterLanding), heroClip.outEnd - 0.2,
        ["The tree first,", "vision second"],
        text("Found in the app's", "accessibility tree.")),
    cap(timeline.film(uncClip, uncLanded + capAfterLanding), uncClip.outEnd - dipHalf - 0.05,
        ["It says when", "it is guessing"],
        text("A guess gets a dashed", "amber ring.")),
    cap(timeline.film(excClip, excRefused + 0.5), excClip.outEnd - dipHalf - 0.05,
        ["Excluded means", "never read"],
        text("No pointer. The title is", "on the exclusion list.")),
    cap(lesA.outStart + dipHalf + 0.2, lesD.outEnd - dipHalf - 0.05,
        ["Lessons wait", "for you"],
        text("You click. It moves on", "when the tree shows it.")),
    // Held at full opacity through the Teach Me shot: the end card's navy covers it, and it ends
    // once the card is opaque.
    cap(wmA.outStart + dipHalf + 0.2, wmD.outEnd + 0.4,
        ["Show it once", "with Watch me"],
        text("You click. It saves a", "lesson of control names.")),
]

let cards: [Card] = [
    titleCard(start: titleStart, end: titleEnd),
    endCard(start: endStart, end: totalDuration + 1),
]

let fadeFromBlack = 0.45

// MARK: - Compositing

let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: outRect)
/// What a dip passes through: the cards' navy.
let navyWash = cardBackground().cropped(to: outRect)

func compose(_ t: Double) -> CIImage {
    var frame = black
    if t < coldEnd { frame = coldPicture(t).composited(over: frame) }
    for clip in timeline.clips where t >= clip.outStart && t < clip.outEnd {
        let a = clip.dissolve > 0 ? ease((t - clip.outStart) / clip.dissolve) : 1
        frame = withAlpha(clip.picture(at: t), a).composited(over: frame)
    }
    frame = frame.cropped(to: outRect)
    for d in timeline.dips where abs(t - d) < dipHalf {
        frame = withAlpha(navyWash, ease(1 - abs(t - d) / dipHalf)).composited(over: frame)
    }
    for c in captions where t >= c.start && t < c.end {
        let inU = easeOut((t - c.start) / fadeInCap)
        let a = min(inU, ease((c.end - t) / fadeOutCap))
        frame = applyPlate(c.plate, over: frame, alpha: a, lift: (1 - inU) * 14)
    }
    for card in cards where t >= card.start && t < card.end {
        let inA = card.fadeIn > 0 ? ease((t - card.start) / card.fadeIn) : 1
        let outA = card.fadeOut > 0 ? ease((card.end - t) / card.fadeOut) : 1
        var layer = card.background
        let itemsOut = card.itemsOutBy.map { ease(($0 - t) / card.itemsFade) } ?? 1
        for item in card.items where itemsOut > 0 {
            let u = easeOut((t - card.start - item.delay) / item.duration)
            if u <= 0 { continue }
            layer = withAlpha(item.image.transformed(by: CGAffineTransform(translationX: 0, y: -(1 - u) * item.rise)),
                              u * itemsOut)
                .composited(over: layer)
        }
        frame = withAlpha(layer.cropped(to: outRect), min(inA, outA)).composited(over: frame)
    }
    if t < fadeFromBlack {
        frame = withAlpha(black, 1 - ease(t / fadeFromBlack)).composited(over: frame)
    }
    return frame.cropped(to: outRect)
}

func writeImage(_ image: CIImage, to path: String, jpeg: Bool, rect: CGRect = outRect) {
    guard let cg = ciContext.createCGImage(image, from: rect, format: .RGBA8, colorSpace: sRGB) else { fail("createCGImage") }
    let type = (jpeg ? "public.jpeg" : "public.png") as CFString
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, type, 1, nil) else {
        fail("cannot write \(path)")
    }
    let props: [CFString: Any] = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
    CGImageDestinationAddImage(dest, cg, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fail("cannot finalize \(path)") }
}

// MARK: - Poster

/// The poster: the hero's landed pointer on Share (solid ring), with the name and tagline in the
/// caption column, led by the icon. 1.3x, anchored right, top at y 180: the window's left edge
/// is about 85 px in from the frame and Share's ring about 100 px above the bottom.
func posterImage() -> CIImage {
    let key = rightKey(0, 1.3, top: 180)
    let stage = frame(master(hero.source, at: heroLanded + 0.9), zoom: key.zoom, cx: key.cx, cy: key.cy)
    var style = PlateStyle()
    style.head = sans(64, .semibold)
    let plate = captionPlate(["Thataway"], text("Name a control on your", "Mac and Thataway", "points at it."),
                             style: style, icon: true)
    return applyPlate(plate, over: stage, alpha: 1)
}

// MARK: - README loop

/// The README loop: the hero query (solid ring), a dissolve, then the uncertain query (dashed amber
/// ring), cropped to the action (the bar, the resting mouse, Share and Link access: about 2x of the
/// stage) and scaled to 1280 px, so the flight is seen whole from the mouse to the ring.
/// Both takes start from the same desktop at rest; make_video.sh cross-fades the end into the
/// first frame, so the loop has no seam.
let gifSize = CGSize(width: 1280, height: 868)
let gifCrop: CGRect = { // master pixels, top-left origin
    // Both takes' action boxes with a margin, at the loop's aspect, at least 1500 px wide.
    let box = actionBox(hero).union(actionBox(uncertain)).union(CGRect(x: 976, y: 519, width: 1, height: 1420 - 519))
        .insetBy(dx: -60, dy: -50)
    let aspect = Double(gifSize.width) / Double(gifSize.height)
    let w = max(1500, box.width, box.height * aspect), h = w / aspect
    let x = min(max(box.midX - w / 2, 0), masterW - w), y = min(max(box.midY - h / 2, 0), masterH - h)
    return CGRect(x: x, y: y, width: w, height: h)
}()
let gifDissolve = 0.4

func renderGIF() {
    let aIn = heroSummon - 0.3, aOut = heroLanded + 2.4
    let bIn = uncSummon - 0.3, bOut = uncLanded + 2.4
    let lenA = aOut - aIn, lenB = bOut - bIn
    let total = lenA + lenB - gifDissolve
    let fps = Double(options.gifFPS)
    let frames = Int((total * fps).rounded())
    let scale = Double(gifSize.width) / gifCrop.width
    let bounds = CGRect(origin: .zero, size: gifSize)
    func crop(_ image: CIImage) -> CIImage {
        let yCI = masterH - gifCrop.maxY
        return image
            .transformed(by: CGAffineTransform(translationX: -gifCrop.minX, y: -yCI))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
            .cropped(to: bounds)
    }
    func picture(_ g: Double) -> CIImage {
        var image = crop(master(hero.source, at: aIn + min(g, lenA)))
        let bStart = lenA - gifDissolve
        if g >= bStart {
            let b = crop(master(uncertain.source, at: bIn + (g - bStart)))
            image = withAlpha(b, ease((g - bStart) / gifDissolve)).composited(over: image)
        }
        return image
    }

    if !options.gifStills.isEmpty {
        let dir = options.stillsDir.isEmpty ? "." : options.stillsDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for g in options.gifStills {
            writeImage(picture(g), to: "\(dir)/gif_\(String(format: "%06.2f", g)).png", jpeg: false, rect: bounds)
        }
    }
    guard !options.gif.isEmpty else { return }

    let ff = Process()
    ff.executableURL = URL(fileURLWithPath: options.ffmpeg)
    ff.arguments = [
        "-v", "error", "-y",
        "-f", "rawvideo", "-pix_fmt", "bgra", "-video_size", "\(Int(gifSize.width))x\(Int(gifSize.height))",
        "-framerate", "\(options.gifFPS)", "-i", "pipe:0",
        "-c:v", "ffv1", "-level", "3", "-pix_fmt", "bgr0", options.gif,
    ]
    let pipe = Pipe()
    ff.standardInput = pipe
    do { try ff.run() } catch { fail("cannot launch ffmpeg: \(error)") }
    let handle = pipe.fileHandleForWriting
    let rowBytes = Int(gifSize.width) * 4
    var buffer = [UInt8](repeating: 0, count: rowBytes * Int(gifSize.height))
    for i in 0..<frames {
        autoreleasepool {
            buffer.withUnsafeMutableBytes { raw in
                ciContext.render(picture(Double(i) / fps), toBitmap: raw.baseAddress!, rowBytes: rowBytes,
                                 bounds: bounds, format: .BGRA8, colorSpace: nil)
            }
            buffer.withUnsafeBytes { raw in handle.write(Data(raw)) }
        }
    }
    try? handle.close()
    ff.waitUntilExit()
    guard ff.terminationStatus == 0 else { fail("ffmpeg (gif frames) exited with \(ff.terminationStatus)") }
    print(String(format: "wrote %@ (%d frames, %.2f s at %d fps)", options.gif, frames, total, options.gifFPS))
}

// MARK: - Run

print(String(format: "cut: title %.2f to %.2f, end card %.2f, total %.2f s", titleStart, titleEnd, endStart, totalDuration))
for c in timeline.clips {
    print(String(format: "  %-14@ film %6.2f to %6.2f  src %6.2f to %6.2f%@", c.source.name, c.outStart, c.outEnd, c.srcIn, c.srcOut,
                 c.dissolve > 0 ? "  (dissolve)" : ""))
}
for d in timeline.dips { print(String(format: "  dip through navy at %6.2f", d)) }
for c in captions { print(String(format: "  caption %6.2f to %6.2f  (%.2f s)", c.start, c.end, c.end - c.start)) }

if !options.stills.isEmpty {
    let dir = options.stillsDir.isEmpty ? "." : options.stillsDir
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for t in options.stills {
        writeImage(compose(t), to: "\(dir)/still_\(String(format: "%06.2f", t)).png", jpeg: false)
    }
    print("wrote \(options.stills.count) stills to \(dir)")
}

if !options.poster.isEmpty {
    writeImage(posterImage(), to: options.poster, jpeg: true)
    print("wrote \(options.poster)")
}

if !options.gif.isEmpty || !options.gifStills.isEmpty {
    renderGIF()
}

if options.video && !options.out.isEmpty {
    let fps = options.fps
    let frameCount = Int((totalDuration * Double(fps)).rounded())
    let convert = "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int+lanczos,format=yuv420p,"
        + "setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709"
    func encode(_ crf: Int, _ path: String) -> [String] {
        ["-c:v", "libx264", "-profile:v", "high", "-preset", options.preset, "-crf", "\(crf)",
         "-tune", "film", "-g", "\(fps * 2)", "-bf", "3", "-pix_fmt", "yuv420p", "-color_range", "tv",
         "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
         "-movflags", "+faststart", "-tag:v", "avc1", "-an", path]
    }
    var args = ["-v", "error", "-y",
                "-f", "rawvideo", "-pix_fmt", "bgra", "-video_size", "\(outW)x\(outH)", "-framerate", "\(fps)",
                "-color_range", "pc", "-i", "pipe:0"]
    if options.outWeb.isEmpty {
        args += ["-vf", convert] + encode(options.crf, options.out)
    } else {
        args += ["-filter_complex", "[0:v]\(convert),split=2[full][web]",
                 "-map", "[full]"] + encode(options.crf, options.out)
            + ["-map", "[web]"] + encode(options.crfWeb, options.outWeb)
    }
    let ff = Process()
    ff.executableURL = URL(fileURLWithPath: options.ffmpeg)
    ff.arguments = args
    let pipe = Pipe()
    ff.standardInput = pipe
    do { try ff.run() } catch { fail("cannot launch ffmpeg: \(error)") }
    let handle = pipe.fileHandleForWriting
    let rowBytes = outW * 4
    var buffer = [UInt8](repeating: 0, count: rowBytes * outH)
    let started = Date()
    for i in 0..<frameCount {
        autoreleasepool {
            let image = compose(Double(i) / Double(fps))
            buffer.withUnsafeMutableBytes { raw in
                ciContext.render(image, toBitmap: raw.baseAddress!, rowBytes: rowBytes, bounds: outRect,
                                 format: .BGRA8, colorSpace: nil)
            }
            buffer.withUnsafeBytes { raw in handle.write(Data(raw)) }
        }
        if i % (fps * 5) == 0 {
            print(String(format: "  frame %d/%d  (%.1fs elapsed)", i, frameCount, Date().timeIntervalSince(started)))
        }
    }
    try? handle.close()
    ff.waitUntilExit()
    guard ff.terminationStatus == 0 else { fail("ffmpeg exited with \(ff.terminationStatus)") }
    print("wrote \(options.out)\(options.outWeb.isEmpty ? "" : " and \(options.outWeb)") (\(frameCount) frames at \(fps) fps)")
}
