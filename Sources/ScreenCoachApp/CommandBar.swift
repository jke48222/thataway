import AppKit
import ScreenCoachCore
import ScreenCoachKit

/// The "what are you looking for" input.
///
/// Unlike the overlay, this panel *does* take keys — you are typing into it —
/// so it is a normal panel that can become key. What it must not do is
/// activate the app underneath it or change which app is frontmost, because
/// the whole query is about the app the user was just in. `becomesKeyOnlyIfNeeded`
/// plus an accessory-policy app is what buys that.
public final class CommandBar: NSPanel, NSTextFieldDelegate {

    /// The bar's one width. Everything inside is capped to it, so no status
    /// or transcript can widen the window off-centre.
    static let width: CGFloat = 560
    private static let sideInset: CGFloat = 18

    // `NSTextField(string:)` is the single-line, horizontally scrolling
    // configuration; `NSTextField()` wraps, and a wrapped second line falls
    // outside a one-line field where neither text nor caret can be seen.
    private let field = NSTextField(string: "")
    private let hint = NSTextField(labelWithString: "")
    private var suggestionRows: [NSTextField] = []
    private let stack = NSStackView()
    private let root = NSStackView()
    /// Set while the bar hides itself on purpose, so losing key status on
    /// the way out is not mistaken for the user clicking away.
    private var isDismissing = false
    private var lastAnnouncedSuggestion: String?
    /// The pending announcement of the top suggestion. Debounced so that a
    /// VoiceOver user's typing echo is not cut off on every keystroke that
    /// changes the leader.
    private var suggestionAnnouncement: DispatchWorkItem?

    /// The microphone is open. Nothing is announced while it is: VoiceOver
    /// speaking over the speakers is heard by the recogniser and ends up in
    /// the transcript. The final answer is announced after the hold ends.
    public var isListening = false {
        didSet { if isListening { cancelSuggestionAnnouncement() } }
    }

    /// Fires as the user types, so candidates can be previewed live.
    public var onQueryChanged: ((String) -> Void)?
    /// Fires on Return.
    public var onSubmit: ((String) -> Void)?
    /// Fires on Escape, and when the user clicks away from the bar.
    public var onCancel: (() -> Void)?

    public init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 58),
                   styleMask: [.borderless, .nonactivatingPanel, .titled, .fullSizeContentView],
                   backing: .buffered, defer: false)
        // Above the overlay (`.screenSaver`), not under it: summoning the
        // coach mid-lesson must not put the field under the lesson's dimming
        // scrim. The overlay is click-through, so nothing is lost above it.
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Kept out of screen capture, like OverlayPanel. ScreenGrab already
        // cuts the coach's process from the vision frame; this also covers a
        // bar ordered in after the shareable content was listed, so the
        // query the user typed is never part of what the model sees.
        sharingType = .none

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        field.placeholderString = "Name a control, like “the Preferences button”"
        field.font = .systemFont(ofSize: 19, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel("Control to point at")
        field.translatesAutoresizingMaskIntoConstraints = false

        // The status line wraps to three lines rather than truncating: its
        // text is the permission instructions and the reason for a miss,
        // and those are exactly the parts a one-line tail truncation cut.
        // fitToContent grows the bar to fit.
        hint.usesSingleLineMode = false
        hint.maximumNumberOfLines = Self.hintMaxLines
        hint.lineBreakMode = .byWordWrapping
        hint.cell?.wraps = true
        hint.cell?.truncatesLastVisibleLine = true
        hint.preferredMaxLayoutWidth = Self.width - 2 * Self.sideInset
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.setContentCompressionResistancePriority(.required, for: .vertical)
        hint.font = .systemFont(ofSize: 11, weight: .regular)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isHidden = true   // no suggestions yet

        for v in [field, hint, stack] { root.addArrangedSubview(v) }
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.edgeInsets = NSEdgeInsets(top: 14, left: Self.sideInset,
                                       bottom: 12, right: Self.sideInset)
        root.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(root)
        contentView = container
        let inner = -2 * Self.sideInset
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            // Pinned at the bottom too, so the bottom inset is real and the
            // window's height is whatever the content needs — not a guess.
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.width),
            field.widthAnchor.constraint(equalTo: root.widthAnchor, constant: inner),
            hint.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: inner),
            stack.widthAnchor.constraint(equalTo: root.widthAnchor, constant: inner),
        ])
        fitToContent()
    }

    static let hintMaxLines = 3

    public override var canBecomeKey: Bool { true }

    /// Clicking back into the app underneath dismisses the bar, the way
    /// Spotlight does. Otherwise it floats over every Space with Escape going
    /// to the other app, and nothing can close it. The overlay can never
    /// become key, so pointing never trips this.
    public override func resignKey() {
        super.resignKey()
        guard isVisible, !isDismissing else { return }
        onCancel?()
    }

    // MARK: - Presentation

    /// Show the bar and take the keyboard.
    ///
    /// Only for a direct result of something the user just did (the hotkey,
    /// the menu, Return). The bar is a non-activating panel: made key from
    /// an asynchronous completion, it takes the keystrokes of whatever app
    /// the user has gone back to.
    ///
    /// - `query`: text to put back in the field, selected, so a miss can be
    ///   rephrased instead of retyped. Empty for a fresh turn.
    /// - `announce`: false while the microphone is open, or when the caller
    ///   says the outcome some other way (speech), so VoiceOver does not
    ///   talk over it.
    public func present(status: String, query: String = "", announce: Bool = true) {
        setHint(status)
        showSuggestions([])
        field.stringValue = query
        positionOnActiveScreen()
        orderFrontRegardless()
        makeKey()
        field.becomeFirstResponder()
        if !query.isEmpty, let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: (query as NSString).length)
        }
        if announce && !isListening { Self.announce(status) }
    }

    public func dismiss() {
        cancelSuggestionAnnouncement()
        lastAnnouncedSuggestion = nil
        guard isVisible else { return }
        isDismissing = true
        orderOut(nil)
        isDismissing = false
    }

    private func positionOnActiveScreen() {
        // The screen with the mouse, not `NSScreen.main`: the user's
        // attention is where their cursor is, and main only tracks focus.
        let frames = NSScreen.screens.map(\.frame)
        let index = DisplaySpace.appKitScreenIndex(containing: NSEvent.mouseLocation,
                                                    in: frames)
        guard let screen = index.flatMap({ NSScreen.screens[safe: $0] })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let size = frame.size
        setFrameOrigin(CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.minY + screen.frame.height * 0.62
        ))
    }

    /// Size the window to what the stack actually needs, keeping the top
    /// edge (where the field is) still, so suggestions grow downward.
    private func fitToContent() {
        contentView?.layoutSubtreeIfNeeded()
        let height = ceil(root.fittingSize.height)
        let content = NSRect(x: 0, y: 0, width: Self.width, height: height)
        let size = frameRect(forContentRect: content).size
        guard size != frame.size else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - size.height,
                        width: size.width, height: size.height), display: isVisible)
    }

    private static func configureSingleLine(_ label: NSTextField) {
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        // Truncate rather than push the window wider.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// Live candidate preview. Seeing the resolver's shortlist while typing is
    /// how you learn what phrasing it understands, which matters more here
    /// than in a normal search box because the vocabulary is the app's, not
    /// ours.
    ///
    /// The top row is what Return will pick, so it reads at full contrast;
    /// the rest are secondary, which still clears 4.5:1 on the HUD material.
    ///
    /// The score is drawn but never spoken: VoiceOver hears the label alone.
    public func showSuggestions(_ rows: [(score: Double, label: String)]) {
        for v in suggestionRows { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        suggestionRows = rows.prefix(3).enumerated().map { i, row in
            let text = String(format: "%.2f  %@", row.score, row.label)
            let l = NSTextField(labelWithString: text)
            Self.configureSingleLine(l)
            let top = i == 0
            l.font = .monospacedSystemFont(ofSize: 12, weight: top ? .medium : .regular)
            l.textColor = top ? .labelColor : .secondaryLabelColor
            l.translatesAutoresizingMaskIntoConstraints = false
            return l
        }
        for l in suggestionRows {
            stack.addArrangedSubview(l)
            l.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -4).isActive = true
        }
        // Hidden when empty, so the root stack drops its spacing too and the
        // bottom inset under the status line is the intended 12 pt.
        stack.isHidden = suggestionRows.isEmpty
        fitToContent()

        // VoiceOver hears the candidate Return would pick, once per change
        // and only once typing pauses, at a priority that does not cut off
        // the echo of the character just typed. Never while the microphone
        // is open: it would be transcribed.
        let top = rows.first?.label
        guard top != lastAnnouncedSuggestion else { return }
        lastAnnouncedSuggestion = top
        cancelSuggestionAnnouncement()
        guard let top, isVisible, !isListening else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible, !self.isListening,
                  self.lastAnnouncedSuggestion == top else { return }
            Self.announce(top, priority: .medium)
        }
        suggestionAnnouncement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.suggestionAnnounceDelay,
                                      execute: work)
    }

    static let suggestionAnnounceDelay: TimeInterval = 0.4

    private func cancelSuggestionAnnouncement() {
        suggestionAnnouncement?.cancel()
        suggestionAnnouncement = nil
    }

    public func setStatus(_ text: String) {
        guard text != hint.stringValue else { return }
        setHint(text)
        fitToContent()
        if isVisible && !isListening { Self.announce(text) }
    }

    private func setHint(_ text: String) {
        hint.stringValue = text
        // Wrapped to three lines, a very long status can still be cut; the
        // tooltip always has all of it.
        hint.toolTip = text
    }

    /// Push a transcript in from voice. Same field as typing, so everything
    /// downstream sees one input path.
    public func setQuery(_ text: String) {
        field.stringValue = text
        // Keep the end of a long transcript — the part being spoken — in view.
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            editor.scrollRangeToVisible(editor.selectedRange)
        }
    }

    public var query: String {
        field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Accessibility

    /// Speak a status change through VoiceOver. The bar's content changes
    /// silently otherwise, and the overlay is click-through and outside the
    /// accessibility hierarchy, so for a VoiceOver user a typed query's
    /// outcome would be purely visual.
    public static func announce(_ text: String,
                                priority: NSAccessibilityPriorityLevel = .high) {
        guard !text.isEmpty, NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: priority.rawValue,
            ]
        )
    }

    // MARK: - Input

    public func controlTextDidChange(_ obj: Notification) {
        onQueryChanged?(field.stringValue)
    }

    public func control(_ control: NSControl, textView: NSTextView,
                        doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let q = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty { onSubmit?(q) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}
