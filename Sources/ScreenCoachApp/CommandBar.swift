import AppKit
import ScreenCoachCore

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
        level = .floating
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

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        field.placeholderString = "Name a control — “the Preferences button”"
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

        Self.configureSingleLine(hint)
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

    public func present(status: String) {
        hint.stringValue = status
        showSuggestions([])
        field.stringValue = ""
        positionOnActiveScreen()
        orderFrontRegardless()
        makeKey()
        field.becomeFirstResponder()
        Self.announce(status)
    }

    public func dismiss() {
        guard isVisible else { return }
        isDismissing = true
        orderOut(nil)
        isDismissing = false
        lastAnnouncedSuggestion = nil
    }

    private func positionOnActiveScreen() {
        // The screen with the mouse, not `NSScreen.main`: the user's
        // attention is where their cursor is, and main only tracks focus.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens[0]
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
    public func showSuggestions(_ rows: [String]) {
        for v in suggestionRows { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        suggestionRows = rows.prefix(3).enumerated().map { i, text in
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

        // VoiceOver hears the candidate Return would pick, once per change,
        // rather than every keystroke.
        let top = rows.first
        if top != lastAnnouncedSuggestion {
            lastAnnouncedSuggestion = top
            if let top, isVisible { Self.announce(top) }
        }
    }

    public func setStatus(_ text: String) {
        guard text != hint.stringValue else { return }
        hint.stringValue = text
        if isVisible { Self.announce(text) }
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
    public static func announce(_ text: String) {
        guard !text.isEmpty, NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
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
