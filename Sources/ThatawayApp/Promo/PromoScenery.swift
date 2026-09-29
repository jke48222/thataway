// The promo stage's scenery: an original procedural wallpaper, a menu bar,
// and the fictional windows the pointer is filmed against. Debug builds only.
//
// Nothing here is Thataway's own UI except the status item glyph and the
// status menu, which are replicas of `ThatawayApp.buildStatusItem()` because a
// real `NSStatusItem` and `NSMenu` cannot be drawn into an off-screen window.
// The pointer is the real `PointerLayer` and lives in `PromoStage.swift`.
#if DEBUG

import AppKit
import SwiftUI
import ThatawayCore
import ThatawayKit

// MARK: - Palette

enum PromoPalette {
    static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
    static func cg(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    // Brand, from Overlay.swift: accent (0.20, 0.55, 1.0), uncertain amber
    // (0.80, 0.45, 0.0), badge fill (0.0, 0.40, 0.85).
    static let accent: UInt32 = 0x338CFF
    static let amber: UInt32 = 0xCC7300
    static let badge: UInt32 = 0x0066D9
    static let night: UInt32 = 0x081427

    // A light macOS window, for the fictional apps.
    static let windowBG = rgb(0xF4F4F6)
    static let box = rgb(0xFFFFFF)
    static let ink = rgb(0x1D1D1F)
    static let inkMuted = rgb(0x6E6E73)
    static let line = rgb(0x000000, 0.08)
    static let systemBlue = rgb(0x0A7AFF)
    static let switchOff = rgb(0xE2E2E6)
}

// MARK: - Wallpaper

/// Deep blue night with a brand-blue glow, a low amber bloom and a few faint
/// arcs that echo the pointer's flight. Procedural, so it is original and
/// identical on every run.
enum PromoWallpaper {
    private static var cache: [String: CGImage] = [:]

    static func image(pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        let key = "\(pixelWidth)x\(pixelHeight)"
        if let hit = cache[key] { return hit }
        let made = make(width: pixelWidth, height: pixelHeight)
        cache[key] = made
        return made
    }

    private static func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: stops.map { PromoPalette.cg($0.0, $0.1) } as CFArray,
                   locations: stops.map(\.2))
    }

    private static func make(width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                    | CGBitmapInfo.byteOrder16Little.rawValue)
        else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        // Top-left origin, like the stage.
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)

        if let sky = gradient([(0x060F20, 1, 0), (0x0A1A38, 1, 0.38), (0x0E2650, 1, 0.72), (0x12306A, 1, 1)]) {
            ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: w * 0.25, y: h), options: [.drawsAfterEndLocation])
        }
        // Brand-blue glow, upper right, behind where the windows sit.
        if let glow = gradient([(0x338CFF, 0.34, 0), (0x1F5FD6, 0.14, 0.45), (0x0E2650, 0, 1)]) {
            let c = CGPoint(x: w * 0.72, y: h * 0.30)
            ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: w * 0.55, options: [])
        }
        // A low amber bloom, bottom left, where the mouse rests.
        if let warm = gradient([(0xCC7300, 0.26, 0), (0x8A4A12, 0.10, 0.5), (0x0E2650, 0, 1)]) {
            let c = CGPoint(x: w * 0.06, y: h * 1.04)
            ctx.drawRadialGradient(warm, startCenter: c, startRadius: 0, endCenter: c, endRadius: w * 0.42, options: [])
        }
        // Faint trajectories: quadratic arcs, like the pointer's own path.
        ctx.setLineCap(.round)
        let arcs: [(CGPoint, CGPoint, CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: -0.05, y: 0.92), CGPoint(x: 0.30, y: 0.18), CGPoint(x: 1.08, y: 0.10), 0.055, 1.6),
            (CGPoint(x: -0.05, y: 1.02), CGPoint(x: 0.42, y: 0.34), CGPoint(x: 1.08, y: 0.30), 0.045, 1.2),
            (CGPoint(x: 0.10, y: 1.08), CGPoint(x: 0.58, y: 0.52), CGPoint(x: 1.08, y: 0.52), 0.035, 1.0),
            (CGPoint(x: 0.34, y: 1.10), CGPoint(x: 0.74, y: 0.70), CGPoint(x: 1.08, y: 0.74), 0.028, 0.8),
        ]
        for (a, c, b, alpha, lw) in arcs {
            ctx.setStrokeColor(PromoPalette.cg(0xBFD8FF, alpha))
            ctx.setLineWidth(lw * w / 1536)
            ctx.move(to: CGPoint(x: a.x * w, y: a.y * h))
            ctx.addQuadCurve(to: CGPoint(x: b.x * w, y: b.y * h), control: CGPoint(x: c.x * w, y: c.y * h))
            ctx.strokePath()
        }
        // Vignette.
        if let vig = gradient([(0x000000, 0, 0.55), (0x000000, 0.35, 1)]) {
            let c = CGPoint(x: w * 0.5, y: h * 0.48)
            ctx.drawRadialGradient(vig, startCenter: c, startRadius: 0, endCenter: c, endRadius: w * 0.78,
                                   options: [.drawsAfterEndLocation])
        }
        return ctx.makeImage()
    }
}

// MARK: - Stage model

/// Everything on the stage that is not the pointer or the command bar.
@Observable final class PromoStageModel {
    var studio = StudioState()
    var showStudio = true
    var showBrowser = false
    var showEditor = false
    /// Moves the Studio window for a still that points at nothing in it.
    var studioOffset = CGSize.zero
    /// The frontmost app, named in the menu bar.
    var frontApp = StudioLayout.appName
    /// Text beside the status item (`setActivity`), nil for the icon alone.
    var statusActivity: String?
    /// The status menu, open on "Teach Me…" with this row highlighted.
    var teachMenuOpen = false
    /// A lesson saved by Watch me, listed in Teach Me… on each menu open.
    var savedLessons: [String] = []
    var highlightedSavedLesson: String?
    /// The status menu's three status lines (tree, vision, privacy). The app
    /// always shows them; the Watch me still leaves them out so the menu
    /// reads Teach Me… > the saved lesson at a glance.
    var showMenuDiagnostics = true
}

// MARK: - Desktop

struct PromoDesktopView: View {
    let model: PromoStageModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.showEditor {
                PromoEditorWindow(fileName: PromoPipeline.lessonFileName(PromoScript.recordingTitle),
                                  text: PromoPipeline.lessonJSON(PromoScript.recordedLesson),
                                  isKey: model.frontApp == "Editor")
                    .place(PromoGeometry.editorFrame)
            }
            if model.showStudio {
                StudioWindow(state: model.studio, isKey: model.frontApp == StudioLayout.appName)
                    .place(PromoGeometry.studioFrame.offsetBy(dx: model.studioOffset.width,
                                                              dy: model.studioOffset.height))
            }
            if model.showBrowser {
                BrowserWindow(isKey: model.frontApp == PromoScript.browserName)
                    .place(PromoGeometry.browserFrame)
            }
            PromoMenuBar(appName: model.frontApp, activity: model.statusActivity,
                         statusHighlighted: model.teachMenuOpen)
                .frame(width: PromoGeometry.stage.width, height: PromoGeometry.menuBarHeight)
            if model.teachMenuOpen {
                PromoStatusMenu(saved: model.savedLessons, highlighted: model.highlightedSavedLesson,
                                diagnostics: model.showMenuDiagnostics,
                                treeLine: String(format: "%@: %d nodes, %.0f ms old, %d refreshes, %d warm / %d cold",
                                                 StudioLayout.appName,
                                                 PromoTreeBuilder.studio(model.studio).nodeCount,
                                                 PromoScript.treeAgeMs, 6, 5, 1))
            }
        }
        .frame(width: PromoGeometry.stage.width, height: PromoGeometry.stage.height, alignment: .topLeading)
        .environment(\.colorScheme, .light)
    }
}

extension View {
    /// Frame and position a view by a top-left rect in its container.
    func place(_ r: CGRect) -> some View {
        frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
    }
}

// MARK: - Menu bar

struct PromoMenuBar: View {
    static let clock = "Tue 9:41 AM"

    let appName: String
    let activity: String?
    let statusHighlighted: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 20) {
                Text(appName).font(.system(size: 13.5, weight: .bold))
                ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) {
                    Text($0).font(.system(size: 13.5))
                }
            }
            .padding(.leading, 22)
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                // Thataway's status item: the glyph `buildStatusItem` sets,
                // plus any text `setActivity` puts beside it.
                HStack(spacing: 5) {
                    Image(systemName: "cursorarrow.rays").font(.system(size: 14, weight: .medium))
                    if let activity {
                        Text(activity).font(.system(size: 13.5)).monospacedDigit()
                    }
                }
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(statusHighlighted ? 0.24 : 0)))
                Image(systemName: "wifi").font(.system(size: 13.5, weight: .semibold))
                Image(systemName: "battery.75percent").font(.system(size: 15))
                Text(Self.clock).font(.system(size: 13.5, weight: .medium)).monospacedDigit()
            }
            .padding(.trailing, 18)
        }
        .frame(height: PromoGeometry.menuBarHeight)
        .foregroundStyle(Color.white.opacity(0.94))
        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
        .background(Color.black.opacity(0.22))
    }
}

// MARK: - Controls (a light macOS look, drawn by hand)

struct MacSwitch: View {
    let on: Bool
    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? PromoPalette.systemBlue : PromoPalette.switchOff)
            Circle().fill(Color.white)
                .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                .padding(2)
        }
        .frame(width: 40, height: 22)
    }
}

struct MacPopUp: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 13)).foregroundStyle(PromoPalette.ink).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(PromoPalette.inkMuted)
        }
        .padding(.horizontal, 10)
        .background(bezel)
    }
}

private var bezel: some View {
    RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Color.white)
        .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5))
}

struct MacButton: View {
    let title: String
    var primary = false
    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary ? Color.white : PromoPalette.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if primary {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PromoPalette.systemBlue)
                        .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                } else {
                    bezel
                }
            }
    }
}

struct MacField: View {
    let text: String
    var placeholder = false
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(placeholder ? PromoPalette.inkMuted.opacity(0.8) : PromoPalette.ink)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5)))
    }
}

struct TrafficLights: View {
    let isKey: Bool
    var body: some View {
        HStack(spacing: 8) {
            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { hex in
                Circle().fill(isKey ? PromoPalette.rgb(hex) : PromoPalette.rgb(0xD5D5D8))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5))
                    .frame(width: 12, height: 12)
            }
        }
    }
}

/// Window chrome shared by the fictional windows.
struct PromoWindowFrame<Content: View>: View {
    let isKey: Bool
    @ViewBuilder let content: Content
    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5))
            .shadow(color: .black.opacity(isKey ? 0.45 : 0.30), radius: isKey ? 34 : 22, y: isKey ? 18 : 10)
    }
}

// MARK: - Studio

struct StudioWindow: View {
    let state: StudioState
    let isKey: Bool
    private typealias L = StudioLayout

    var body: some View {
        PromoWindowFrame(isKey: isKey) {
            ZStack(alignment: .topLeading) {
                PromoPalette.windowBG
                titleBar
                switch state.pane {
                case .sharing: sharingPane
                case .general: generalPane
                }
                if state.sheetOpen {
                    Color.black.opacity(0.10)
                        .frame(width: PromoGeometry.studioFrame.width,
                               height: PromoGeometry.studioFrame.height - L.titleBarHeight)
                        .offset(y: L.titleBarHeight)
                    sheet.transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(width: PromoGeometry.studioFrame.width, height: PromoGeometry.studioFrame.height,
                   alignment: .topLeading)
        }
    }

    private var titleBar: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white.opacity(0.72))
                .frame(width: PromoGeometry.studioFrame.width, height: L.titleBarHeight)
            Rectangle().fill(PromoPalette.line)
                .frame(width: PromoGeometry.studioFrame.width, height: 1)
                .offset(y: L.titleBarHeight - 1)
            TrafficLights(isKey: isKey).offset(x: 18, y: 10)
            // The title sits beside the traffic lights, as a unified title bar
            // sets it, not centred over the toolbar: a lesson's step caption
            // for a toolbar button is drawn just above the button, where a
            // centred title would show through under it.
            Text(state.pane == .sharing ? "Sharing" : "General")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PromoPalette.ink.opacity(isKey ? 1 : 0.5))
                .fixedSize()
                .frame(height: 30)
                .offset(x: 92)
            ForEach(Array(L.toolbarItems.enumerated()), id: \.offset) { i, item in
                let selected = item.key == state.pane.rawValue
                VStack(spacing: 3) {
                    Image(systemName: item.symbol).font(.system(size: 17, weight: .regular))
                        .frame(height: 22)
                    Text(item.title).font(.system(size: 11))
                }
                .foregroundStyle(selected ? PromoPalette.systemBlue : PromoPalette.ink.opacity(0.78))
                .frame(width: L.toolbarFrame(i).width, height: L.toolbarFrame(i).height)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(selected ? 0.07 : 0)))
                .place(L.toolbarFrame(i))
            }
        }
    }

    private func header(_ text: String, at p: CGPoint) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(PromoPalette.inkMuted)
            .fixedSize()
            .offset(x: p.x, y: p.y)
    }

    private func box(_ r: CGRect, rows: [String], subtitles: [String?] = []) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PromoPalette.box)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(PromoPalette.line, lineWidth: 0.5))
            ForEach(Array(rows.enumerated()), id: \.offset) { i, title in
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).foregroundStyle(PromoPalette.ink)
                    if let sub = subtitles[safe: i] ?? nil {
                        Text(sub).font(.system(size: 11)).foregroundStyle(PromoPalette.inkMuted)
                    }
                }
                .frame(height: L.rowHeight)
                .offset(x: 16, y: CGFloat(i) * L.rowHeight)
                if i > 0 {
                    Rectangle().fill(PromoPalette.line).frame(width: r.width - 32, height: 1)
                        .offset(x: 16, y: CGFloat(i) * L.rowHeight)
                }
            }
        }
        .place(r)
    }

    private var sharingPane: some View {
        ZStack(alignment: .topLeading) {
            header("Project", at: L.projectHeader)
            box(L.projectBox, rows: ["Project name", "Link access", "Allow comments", "Show edit history"])
            header("People", at: L.peopleHeader)
            box(L.peopleBox, rows: ["Invite people", "Notify me when the link is opened"])
            MacField(text: "Spring Catalog").place(L.projectName)
            MacPopUp(text: "Anyone with the link").place(L.linkAccess)
            MacSwitch(on: state.allowComments).place(L.allowComments)
            MacSwitch(on: state.editHistory).place(L.editHistory)
            MacField(text: "Add by name", placeholder: true).place(L.invite)
            MacSwitch(on: state.notifyOpen).place(L.notifyOpen)
            Text("People you invite can open the project in Studio and leave comments.")
                .font(.system(size: 11)).foregroundStyle(PromoPalette.inkMuted)
                .fixedSize().offset(x: 40, y: 440)
            MacButton(title: "Advanced Options…").place(L.advancedOptions)
            MacButton(title: "Copy Link").place(L.copyLink)
            MacButton(title: "Share").place(L.share)
        }
    }

    private var generalPane: some View {
        ZStack(alignment: .topLeading) {
            header("Studio", at: L.generalHeader)
            box(L.generalBox, rows: ["Appearance", "Open at login", "Default zoom",
                                     "Check spelling while typing", "Save versions automatically"])
            MacPopUp(text: "Automatic").place(L.appearance)
            MacSwitch(on: false).place(L.openAtLogin)
            MacPopUp(text: "100%").place(L.defaultZoom)
            MacSwitch(on: true).place(L.spelling)
            MacSwitch(on: true).place(L.autosave)
            Text("Studio keeps a version each time you pause, for up to 30 days.")
                .font(.system(size: 11)).foregroundStyle(PromoPalette.inkMuted)
                .fixedSize().offset(x: 40, y: 354)
            MacButton(title: "Reset Warnings…").place(L.resetWarnings)
        }
    }

    private var sheet: some View {
        let s = L.sheet
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PromoPalette.windowBG)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
                .place(s)
            Text("Link Settings").font(.system(size: 15, weight: .semibold)).foregroundStyle(PromoPalette.ink)
                .fixedSize().offset(x: s.minX + 24, y: s.minY + 20)
            Text("For the Spring Catalog link").font(.system(size: 11)).foregroundStyle(PromoPalette.inkMuted)
                .fixedSize().offset(x: s.minX + 24, y: s.minY + 42)
            ForEach(Array(["Require a passcode", "Link expires", "Allow downloads"].enumerated()), id: \.offset) { i, t in
                Text(t).font(.system(size: 13)).foregroundStyle(PromoPalette.ink)
                    .frame(height: 44)
                    .fixedSize()
                    .offset(x: s.minX + 24, y: s.minY + 55 + CGFloat(i) * 44)
            }
            MacSwitch(on: state.passcodeOn).place(L.sheetPasscode)
            MacPopUp(text: "Never").place(L.sheetExpires)
            MacSwitch(on: true).place(L.sheetDownloads)
            MacButton(title: "Cancel").place(L.sheetCancel)
            MacButton(title: "Done", primary: true).place(L.sheetDone)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Browser (the privacy scene)

/// A generic browser window whose one tab is titled "Online Banking". The
/// page is deliberately abstract: the point of the scene is that Thataway
/// never read it.
struct BrowserWindow: View {
    let isKey: Bool
    private let size = PromoGeometry.browserFrame.size

    var body: some View {
        PromoWindowFrame(isKey: isKey) {
            VStack(spacing: 0) {
                chrome
                page.frame(maxHeight: .infinity, alignment: .top).clipped()
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color.white)
        }
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                TrafficLights(isKey: isKey)
                HStack(spacing: 7) {
                    Image(systemName: "building.columns").font(.system(size: 11))
                    Text(PromoScript.browserTitle).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).opacity(0.5)
                }
                .foregroundStyle(PromoPalette.ink)
                .padding(.horizontal, 12)
                .frame(width: 230, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white))
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(PromoPalette.inkMuted)
                Spacer()
            }
            .padding(.leading, 18)
            .frame(height: 46)
            HStack(spacing: 16) {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .medium))
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .medium)).opacity(0.35)
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").font(.system(size: 11))
                    Capsule().fill(Color.black.opacity(0.10)).frame(width: 180, height: 8)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(Color.black.opacity(0.05)))
                Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(PromoPalette.inkMuted)
            .padding(.horizontal, 18)
            .frame(height: 42)
            Rectangle().fill(PromoPalette.line).frame(height: 1)
        }
        .background(PromoPalette.rgb(0xE9E9EC))
    }

    private func bar(_ w: CGFloat, _ h: CGFloat = 10, _ o: Double = 0.09) -> some View {
        Capsule().fill(Color.black.opacity(o)).frame(width: w, height: h)
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PromoPalette.rgb(0x1E4E8C))
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "building.columns.fill").font(.system(size: 14)).foregroundStyle(.white))
                Text(PromoScript.browserTitle).font(.system(size: 20, weight: .semibold)).foregroundStyle(PromoPalette.ink)
                Spacer()
                bar(90); bar(70); bar(80)
                Circle().fill(Color.black.opacity(0.08)).frame(width: 28, height: 28)
            }
            .padding(.horizontal, 32)
            .frame(height: 70)
            Rectangle().fill(PromoPalette.line).frame(height: 1)
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach([120, 96, 110, 84, 100] as [CGFloat], id: \.self) { bar($0) }
                }
                .padding(.top, 8)
                .frame(width: 150, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) {
                    bar(220, 16, 0.14)
                    HStack(spacing: 16) {
                        ForEach(0..<3, id: \.self) { i in
                            VStack(alignment: .leading, spacing: 12) {
                                bar(90, 9); bar(140, 20, 0.12); bar(70, 8, 0.06)
                            }
                            .padding(18)
                            .frame(width: 176, height: 118, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(PromoPalette.rgb(i == 0 ? 0xEEF4FF : 0xF5F5F7)))
                        }
                    }
                    bar(160, 14, 0.12).padding(.top, 8)
                    ForEach(0..<4, id: \.self) { i in
                        HStack {
                            Circle().fill(Color.black.opacity(0.07)).frame(width: 24, height: 24)
                            bar([150, 120, 170, 140, 110][i])
                            Spacer()
                            bar(60)
                        }
                        .frame(height: 30)
                    }
                }
            }
            .padding(32)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Editor (the saved Watch me lesson)

struct PromoEditorWindow: View {
    let fileName: String
    let text: String
    let isKey: Bool
    var body: some View {
        PromoWindowFrame(isKey: isKey) {
            VStack(spacing: 0) {
                ZStack {
                    Text(fileName).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PromoPalette.ink.opacity(isKey ? 1 : 0.55))
                    HStack { TrafficLights(isKey: isKey); Spacer() }.padding(.leading, 18)
                }
                .frame(height: 40)
                .background(PromoPalette.rgb(0xEDEDF0))
                Rectangle().fill(PromoPalette.line).frame(height: 1)
                Text(text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .fixedSize()
                    .foregroundStyle(PromoPalette.ink)
                    .lineSpacing(2.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .background(Color.white)
            }
            .frame(width: PromoGeometry.editorFrame.width, height: PromoGeometry.editorFrame.height)
        }
    }
}

// MARK: - Status menu (replica of buildStatusItem's menu)

struct PromoStatusMenu: View {
    let saved: [String]
    let highlighted: String?
    /// Whether the three disabled status lines lead the menu.
    var diagnostics = true
    /// `AXCache.statusLine` for the tree behind the menu.
    let treeLine: String

    static let menuWidth: CGFloat = 420
    static let subWidth: CGFloat = 272
    /// A status menu that would run off the right edge is moved left to fit.
    static var menuX: CGFloat { PromoGeometry.stage.width - menuWidth - 6 }
    static let menuY: CGFloat = PromoGeometry.menuBarHeight + 3
    static var subX: CGFloat { menuX - subWidth + 2 }

    private enum Row: Hashable {
        case item(String, enabled: Bool, highlighted: Bool, submenu: Bool)
        case separator
    }

    private var mainRows: [Row] {
        let privacy = ExclusionList.defaults.rules
        let bundles = privacy.filter { $0.kind == .bundleID }.count
        let titles = privacy.filter { $0.kind == .titleContains }.count
        let status: [Row] = diagnostics ? [
            .item(treeLine, enabled: false, highlighted: false, submenu: false),
            .item("Vision: not started", enabled: false, highlighted: false, submenu: false),
            .item("Privacy: \(bundles) apps, \(titles) title patterns excluded", enabled: false, highlighted: false, submenu: false),
            .separator,
        ] : []
        return status + [
            .item("Point at Something…  ⌥Space", enabled: true, highlighted: false, submenu: false),
            .item("Refresh Tree Now", enabled: true, highlighted: false, submenu: false),
            .separator,
            .item("Teach Me…", enabled: true, highlighted: true, submenu: true),
            .separator,
            .item("Quit Thataway", enabled: true, highlighted: false, submenu: false),
        ]
    }

    private var subRows: [Row] {
        var rows: [Row] = BuiltInLessons.all.map { .item($0.title, enabled: true, highlighted: false, submenu: false) }
        rows += saved.map { .item($0, enabled: true, highlighted: $0 == highlighted, submenu: false) }
        rows += [.separator,
                 .item("Next Step", enabled: false, highlighted: false, submenu: false),
                 .item("Previous Step", enabled: false, highlighted: false, submenu: false),
                 .separator,
                 .item("Record a Workflow", enabled: true, highlighted: false, submenu: false),
                 .item("Stop Teaching", enabled: true, highlighted: false, submenu: false)]
        return rows
    }

    static let rowH: CGFloat = 24
    static let sepH: CGFloat = 11
    static let pad: CGFloat = 6

    private func height(_ rows: [Row]) -> CGFloat {
        rows.reduce(2 * Self.pad) { $0 + ($1 == .separator ? Self.sepH : Self.rowH) }
    }

    /// The submenu's top edge: its first row lines up with "Teach Me…",
    /// which follows five items and two separators (two items and one
    /// separator without the status lines).
    static func subTop(diagnostics: Bool = true) -> CGFloat {
        menuY + (diagnostics ? 5 * rowH + 2 * sepH : 2 * rowH + sepH)
    }

    /// Centre of saved lesson `index` in the submenu (after the built-ins).
    static func savedRowCenter(_ index: Int, diagnostics: Bool = true) -> CGPoint {
        CGPoint(x: subX + subWidth - 34,
                y: subTop(diagnostics: diagnostics) + pad
                    + CGFloat(BuiltInLessons.all.count + index) * rowH + rowH / 2)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            menu(mainRows, width: Self.menuWidth)
                .offset(x: Self.menuX, y: Self.menuY)
            // No room to the right of a status menu at the screen edge, so
            // the submenu opens to the left, as AppKit does.
            menu(subRows, width: Self.subWidth)
                .offset(x: Self.subX, y: Self.subTop(diagnostics: diagnostics))
        }
    }

    private func menu(_ rows: [Row], width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .separator:
                    Rectangle().fill(Color.black.opacity(0.10)).frame(height: 1)
                        .padding(.horizontal, 12).frame(height: Self.sepH)
                case let .item(title, enabled, highlighted, submenu):
                    HStack {
                        Text(title).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 8)
                        if submenu { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                        if title == "Quit Thataway" { Text("⌘Q").font(.system(size: 13)).opacity(0.5) }
                    }
                    .foregroundStyle(highlighted ? Color.white : PromoPalette.ink.opacity(enabled ? 1 : 0.38))
                    .padding(.horizontal, 10)
                    .frame(height: Self.rowH)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(highlighted ? PromoPalette.systemBlue : Color.clear))
                    .padding(.horizontal, 5)
                }
            }
        }
        .padding(.vertical, Self.pad)
        .frame(width: width, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.97))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.32), radius: 18, y: 8))
        .environment(\.colorScheme, .light)
    }
}

#endif
