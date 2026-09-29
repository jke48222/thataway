// The promo stage's fictional desktop, as data. Debug builds only.
//
// Everything the stage draws (the "Studio" settings window, its sheet, the
// "Browser" window) is laid out from the frames in this file, and the same
// frames become the accessibility tree the real `AXResolver`, `Fusion`,
// `LessonEngine` and `WorkflowInference` run on. So the shortlist scores, the
// solid or dashed ring, the lesson's advance and the recorded Watch me steps
// in the media are what the shipping code computes for this window. Only the
// window itself is made up: no real app, account, name or icon appears.
#if DEBUG

import CoreGraphics
import Foundation
import ThatawayCore

// MARK: - Stage geometry

/// Stage space: points, top-left origin, 1536 × 864 (rendered at 2×). It is
/// also the "CG" space of the fictional tree, on screen index 0.
enum PromoGeometry {
    static let stage = CGSize(width: 1536, height: 864)
    static let menuBarHeight: CGFloat = 30

    /// Where the person's own mouse rests. Every flight starts from wherever
    /// the synthetic mouse is; it never moves on camera. It sits in Studio's
    /// empty strip between the footnote and the bottom buttons, near enough to
    /// Share and Link access that the resting mouse, the whole arc and the
    /// ring fit one 1.6x shot of the film.
    static let mouseRest = CGPoint(x: 640, y: 620)

    /// Where the mouse is left after a click it no longer needs to be on:
    /// the desktop's lower left, clear of every window. The lesson's last shot
    /// and the lesson still park it here, so the person's black arrow never
    /// sits on the control the blue drawn pointer is marking.
    static let mouseParked = CGPoint(x: 100, y: 800)

    /// The Studio settings window.
    static let studioFrame = CGRect(x: 408, y: 150, width: 720, height: 560)
    /// The Browser window of the privacy scene.
    static let browserFrame = CGRect(x: 318, y: 118, width: 900, height: 600)
    /// The saved lesson opened in a plain editor window (Watch me still).
    static let editorFrame = CGRect(x: 56, y: 150, width: 600, height: 650)

    /// Where the real `CommandBar` puts itself: centred, its bottom edge at
    /// 62% of the screen height (AppKit space) when it first appears, then
    /// growing downwards as suggestions arrive. Top-left stage space.
    static func commandBarTop(initialHeight: CGFloat) -> CGFloat {
        stage.height - stage.height * 0.62 - initialHeight
    }

    /// Top-left stage rect to AppKit (bottom-left) stage rect.
    static func appKit(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: stage.height - r.maxY, width: r.width, height: r.height)
    }

    static func appKit(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: stage.height - p.y)
    }
}

// MARK: - Studio (the fictional app)

enum StudioPane: String {
    case general, sharing
}

/// Studio's settings window. Frames are window-local, top-left origin.
enum StudioLayout {
    static let appName = "Studio"
    static let titleBarHeight: CGFloat = 84

    // Toolbar: four icon-over-label buttons, centred.
    static let toolbarItems: [(key: String, title: String, symbol: String)] = [
        ("general", "General", "gearshape"),
        ("sharing", "Sharing", "person.2"),
        ("export", "Export", "square.and.arrow.up"),
        ("advanced", "Advanced", "slider.horizontal.3"),
    ]
    static func toolbarFrame(_ index: Int) -> CGRect {
        let w: CGFloat = 76, gap: CGFloat = 6
        let total = CGFloat(toolbarItems.count) * w + CGFloat(toolbarItems.count - 1) * gap
        let x0 = (PromoGeometry.studioFrame.width - total) / 2
        return CGRect(x: x0 + CGFloat(index) * (w + gap), y: 30, width: w, height: 50)
    }

    // Grouped form boxes.
    static let contentInset: CGFloat = 28
    static let rowHeight: CGFloat = 44
    static var boxWidth: CGFloat { PromoGeometry.studioFrame.width - 2 * contentInset }

    // Sharing pane.
    static let projectHeader = CGPoint(x: 40, y: 104)
    static let projectBox = CGRect(x: 28, y: 124, width: 664, height: 176)
    static let peopleHeader = CGPoint(x: 40, y: 322)
    static let peopleBox = CGRect(x: 28, y: 342, width: 664, height: 88)

    static let projectName = CGRect(x: 410, y: 131, width: 266, height: 30)
    static let linkAccess = CGRect(x: 456, y: 177, width: 220, height: 26)
    static let allowComments = CGRect(x: 636, y: 223, width: 40, height: 22)
    static let editHistory = CGRect(x: 636, y: 267, width: 40, height: 22)
    static let invite = CGRect(x: 410, y: 349, width: 266, height: 30)
    static let notifyOpen = CGRect(x: 636, y: 397, width: 40, height: 22)

    static let advancedOptions = CGRect(x: 28, y: 506, width: 168, height: 30)
    static let copyLink = CGRect(x: 468, y: 506, width: 108, height: 30)
    static let share = CGRect(x: 588, y: 506, width: 104, height: 30)

    // General pane.
    static let generalHeader = CGPoint(x: 40, y: 104)
    static let generalBox = CGRect(x: 28, y: 124, width: 664, height: 220)
    static let appearance = CGRect(x: 496, y: 133, width: 180, height: 26)
    static let openAtLogin = CGRect(x: 636, y: 179, width: 40, height: 22)
    static let defaultZoom = CGRect(x: 496, y: 221, width: 180, height: 26)
    static let spelling = CGRect(x: 636, y: 267, width: 40, height: 22)
    static let autosave = CGRect(x: 636, y: 311, width: 40, height: 22)
    static let resetWarnings = CGRect(x: 28, y: 506, width: 150, height: 30)

    // The Advanced Options sheet, hung under the toolbar.
    static let sheet = CGRect(x: 150, y: 84, width: 420, height: 262)
    static let sheetPasscode = CGRect(x: 494, y: 150, width: 40, height: 22)   // window-local
    static let sheetExpires = CGRect(x: 384, y: 192, width: 150, height: 26)
    static let sheetDownloads = CGRect(x: 494, y: 238, width: 40, height: 22)
    static let sheetCancel = CGRect(x: 364, y: 298, width: 84, height: 28)
    static let sheetDone = CGRect(x: 458, y: 298, width: 84, height: 28)

    /// Window-local rect to stage rect.
    static func stage(_ r: CGRect) -> CGRect {
        r.offsetBy(dx: PromoGeometry.studioFrame.minX, dy: PromoGeometry.studioFrame.minY)
    }
}

/// The state of the fictional desktop that the tree and the views both read.
struct StudioState: Equatable {
    var pane: StudioPane = .sharing
    var sheetOpen = false
    var passcodeOn = false
    var allowComments = true
    var editHistory = false
    var notifyOpen = true
}

// MARK: - The fictional accessibility tree

/// Builds the tree the real resolver sees for the current state.
struct PromoTreeBuilder {
    private(set) var nodes: [AXNode] = []
    private var nextID = 0

    @discardableResult
    private mutating func add(_ role: String, parent: Int?, depth: Int, title: String? = nil,
                              subrole: String? = nil, help: String? = nil, value: String? = nil,
                              selected: Bool = false, enabled: Bool = true,
                              frame: CGRect) -> Int {
        let id = nextID
        nextID += 1
        nodes.append(AXNode(id: id, parentID: parent, depth: depth, role: role, subrole: subrole,
                            title: title, helpText: help, valueText: value,
                            enabled: enabled, selected: selected,
                            bounds: ScreenRect(cg: frame, screenIndex: 0)))
        return id
    }

    static func studio(_ s: StudioState) -> AXTreeSnapshot {
        var b = PromoTreeBuilder()
        let L = StudioLayout.self
        let win = b.add("AXWindow", parent: nil, depth: 0,
                        title: s.pane == .sharing ? "Sharing" : "General",
                        frame: PromoGeometry.studioFrame)
        let bar = b.add("AXToolbar", parent: win, depth: 1,
                        frame: L.stage(CGRect(x: 0, y: 28, width: 720, height: 56)))
        for (i, item) in L.toolbarItems.enumerated() {
            b.add("AXButton", parent: bar, depth: 2, title: item.title,
                  selected: item.key == s.pane.rawValue, frame: L.stage(L.toolbarFrame(i)))
        }
        // While the sheet is up, the window's own controls are behind it and
        // stay in the tree, as they do in a real sheet's parent window.
        switch s.pane {
        case .sharing:
            let project = b.add("AXGroup", parent: win, depth: 1, title: "Project",
                                frame: L.stage(L.projectBox))
            b.add("AXTextField", parent: project, depth: 2, title: "Project name",
                  value: "Spring Catalog", frame: L.stage(L.projectName))
            b.add("AXPopUpButton", parent: project, depth: 2, title: "Link access",
                  help: "Who can open the link you share", value: "Anyone with the link",
                  frame: L.stage(L.linkAccess))
            b.add("AXCheckBox", parent: project, depth: 2, title: "Allow comments", subrole: "AXSwitch",
                  value: s.allowComments ? "1" : "0", frame: L.stage(L.allowComments))
            b.add("AXCheckBox", parent: project, depth: 2, title: "Show edit history", subrole: "AXSwitch",
                  value: s.editHistory ? "1" : "0", frame: L.stage(L.editHistory))
            let people = b.add("AXGroup", parent: win, depth: 1, title: "People",
                               frame: L.stage(L.peopleBox))
            b.add("AXTextField", parent: people, depth: 2, title: "Invite people",
                  help: "Add by name", frame: L.stage(L.invite))
            b.add("AXCheckBox", parent: people, depth: 2, title: "Notify me when the link is opened",
                  subrole: "AXSwitch", value: s.notifyOpen ? "1" : "0", frame: L.stage(L.notifyOpen))
            b.add("AXButton", parent: win, depth: 1, title: "Advanced Options…",
                  frame: L.stage(L.advancedOptions))
            b.add("AXButton", parent: win, depth: 1, title: "Copy Link",
                  help: "Copy a link you can share", frame: L.stage(L.copyLink))
            b.add("AXButton", parent: win, depth: 1, title: "Share",
                  help: "Share Spring Catalog with people you invite", frame: L.stage(L.share))
        case .general:
            let box = b.add("AXGroup", parent: win, depth: 1, title: "Studio",
                            frame: L.stage(L.generalBox))
            b.add("AXPopUpButton", parent: box, depth: 2, title: "Appearance", value: "Automatic",
                  frame: L.stage(L.appearance))
            b.add("AXCheckBox", parent: box, depth: 2, title: "Open at login", subrole: "AXSwitch",
                  value: "0", frame: L.stage(L.openAtLogin))
            b.add("AXPopUpButton", parent: box, depth: 2, title: "Default zoom", value: "100%",
                  frame: L.stage(L.defaultZoom))
            b.add("AXCheckBox", parent: box, depth: 2, title: "Check spelling while typing",
                  subrole: "AXSwitch", value: "1", frame: L.stage(L.spelling))
            b.add("AXCheckBox", parent: box, depth: 2, title: "Save versions automatically",
                  subrole: "AXSwitch", value: "1", frame: L.stage(L.autosave))
            b.add("AXButton", parent: win, depth: 1, title: "Reset Warnings…",
                  frame: L.stage(L.resetWarnings))
        }
        if s.sheetOpen {
            let sheet = b.add("AXSheet", parent: win, depth: 1, title: "Link Settings",
                              frame: L.stage(L.sheet))
            b.add("AXCheckBox", parent: sheet, depth: 2, title: "Require a passcode", subrole: "AXSwitch",
                  value: s.passcodeOn ? "1" : "0", frame: L.stage(L.sheetPasscode))
            b.add("AXPopUpButton", parent: sheet, depth: 2, title: "Link expires", value: "Never",
                  frame: L.stage(L.sheetExpires))
            b.add("AXCheckBox", parent: sheet, depth: 2, title: "Allow downloads", subrole: "AXSwitch",
                  value: "1", frame: L.stage(L.sheetDownloads))
            b.add("AXButton", parent: sheet, depth: 2, title: "Cancel", frame: L.stage(L.sheetCancel))
            b.add("AXButton", parent: sheet, depth: 2, title: "Done", frame: L.stage(L.sheetDone))
        }
        return AXTreeSnapshot(
            nodes: b.nodes, appName: StudioLayout.appName, bundleID: "com.example.studio", pid: 0,
            windowTitle: s.pane == .sharing ? "Sharing" : "General",
            windowBounds: ScreenRect(cg: PromoGeometry.studioFrame, screenIndex: 0),
            extractionMs: 0, truncated: false, truncationReason: nil,
            forcedManualAccessibility: false, maxDepthReached: 2)
    }
}

// MARK: - What the real pipeline says about the fictional window

/// The app's own decisions, computed with the shipping code on the fictional
/// tree. Mirrors `ThatawayApp.preview(_:)`, `resolveAndPoint` and
/// `present(_:)`, minus the capture and speech.
enum PromoPipeline {
    /// The live shortlist, formatted by `CommandBar.showSuggestions` rules.
    static func shortlist(_ query: String, tree: AXTreeSnapshot) -> [(score: Double, label: String)] {
        guard query.count >= 2 else { return [] }
        let ranked = AXResolver.rank(query: query, in: tree.nodes,
                                     windowBounds: tree.windowBounds, limit: 3)
        return ranked.map { (score: $0.score, label: String($0.node.semanticLabel.prefix(64))) }
    }

    struct Answer {
        let target: CGRect          // stage space, top-left
        let caption: String
        let exact: Bool
        let score: Double
    }

    /// Return pressed on `query`. Nil means "Nothing in Studio matches".
    /// The stage never has the vision model, and it only shows answers the
    /// app would give without it: a hit, or a weak match in a well-labelled
    /// tree, which `Fusion.needsVision` also answers from the tree alone.
    static func answer(_ query: String, tree: AXTreeSnapshot) -> Answer? {
        let ranked = AXResolver.rank(query: query, in: tree.nodes,
                                     windowBounds: tree.windowBounds, limit: 3)
        guard let top = ranked.first else { return nil }
        let ax = Fusion.AXCandidate(bounds: top.node.bounds, score: top.score,
                                    label: top.node.title ?? top.node.roleDescription ?? top.node.humanRole)
        precondition(!Fusion.needsVision(axScore: top.score, axHitThreshold: AXResolver.hitThreshold,
                                         labelledFraction: tree.labelledFraction),
                     "promo query “\(query)” would run vision; pick one the tree answers")
        guard let decision = Fusion.decide(ax: ax, vision: nil, axHitThreshold: AXResolver.hitThreshold)
        else { return nil }
        var caption = decision.label
        if decision.confidence == .uncertain { caption += "?" }
        return Answer(target: decision.target.cg, caption: caption,
                      exact: decision.confidence == .exact, score: top.score)
    }

    /// The bar's first status line for a turn, as `summon` formats it.
    static func summonStatus(tree: AXTreeSnapshot, treeAgeMs: Double) -> String {
        String(format: "%@ · %d controls · tree %.0f ms old",
               tree.appName, tree.labelledCount, treeAgeMs)
    }

    /// `explainMissingTree()` for an excluded window: the gate refuses before
    /// any tree is read, so this is all the bar can say.
    static func refusal(appName: String, bundleID: String, windowTitle: String) -> String? {
        let verdict = ExclusionList.defaults.check(bundleID: bundleID, windowTitle: windowTitle)
        guard verdict.excluded, let why = verdict.reason else { return nil }
        return ExclusionList.refusal(appName: appName, reason: why)
    }

    /// A Watch me recording of clicks on `keys`, built the way
    /// `WorkflowRecorder` builds it: hit-test, `semanticQuery`, `bestLabel`,
    /// then `inferCompletion` from the tree before and after each click.
    static func record(clicks: [(point: CGPoint, after: StudioState)], from start: StudioState,
                       title: String) -> Lesson {
        var steps: [Step] = []
        var state = start
        for click in clicks {
            let before = PromoTreeBuilder.studio(state).nodes
            guard let node = WorkflowInference.hitTest(click.point, in: before),
                  let query = WorkflowInference.semanticQuery(for: node, in: before) else {
                preconditionFailure("promo click at \(click.point) hits nothing labelled")
            }
            let label = WorkflowInference.bestLabel(node) ?? query
            let after = PromoTreeBuilder.studio(click.after).nodes
            let completion = WorkflowInference.inferCompletion(clickedQuery: query,
                                                                before: before, after: after)
            steps.append(Step(instruction: "Click \(label)", target: query, completion: completion))
            state = click.after
        }
        return Lesson(title: title, bundleID: "com.example.studio", steps: steps)
    }

    /// The saved file, encoded the way `LessonStore.save` writes it.
    static func lessonJSON(_ lesson: Lesson) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(lesson) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// `LessonStore.save`'s file name for a lesson title.
    static func lessonFileName(_ title: String) -> String {
        title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-") + ".json"
    }
}

// MARK: - The script

/// The fixed content of every scene, in one place.
enum PromoScript {
    static let exactQuery = "the Share button"
    /// People call a pop-up a menu. "menu" implies a menu role the pop-up
    /// does not have, so the tree's best answer lands below the hit threshold.
    static let uncertainQuery = "the access menu"

    /// A fictional browser and a window title that one default rule matches.
    static let browserName = "Browser"
    static let browserBundleID = "com.example.browser"
    static let browserTitle = "Online Banking"

    /// Tree age shown in the bar's status line.
    static let treeAgeMs = 850.0

    /// The Watch me recording: three clicks through Studio.
    static let recordingTitle: String = {
        // `WorkflowRecorder.finish()` titles a recording "<app>: recorded <date>".
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "MMM d, HH:mm"
        let date = ISO8601DateFormatter().date(from: "2026-09-29T13:41:00Z") ?? Date(timeIntervalSince1970: 0)
        return "\(StudioLayout.appName): recorded \(f.string(from: date))"
    }()

    static var recordingStart: StudioState {
        var s = StudioState()
        s.pane = .general
        return s
    }

    /// Each click: where it landed and the state it produced.
    static var recordingClicks: [(point: CGPoint, after: StudioState)] {
        var a = recordingStart
        a.pane = .sharing
        var b = a
        b.sheetOpen = true
        var c = b
        c.passcodeOn = true
        let L = StudioLayout.self
        // Click points sit off-centre, where a hand would land without the
        // mouse covering the control's label in the shot after the cut.
        func at(_ r: CGRect, _ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
            let c = center(L.stage(r))
            return CGPoint(x: c.x + dx, y: c.y + dy)
        }
        return [
            (at(L.toolbarFrame(1), 20, -12), a),
            (at(L.advancedOptions, 52, 3), b),
            (at(L.sheetPasscode, 8, 1), c),
        ]
    }

    static let recordedLesson: Lesson = PromoPipeline.record(
        clicks: recordingClicks, from: recordingStart, title: recordingTitle)

    static func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
}

#endif
