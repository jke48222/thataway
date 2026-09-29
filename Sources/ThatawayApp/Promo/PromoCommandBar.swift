// A replica of `CommandBar` for the promo stage. Debug builds only.
//
// The real bar is an `NSPanel` at screen-saver level whose background is a
// `.hudWindow` visual effect. Neither can be filmed from a window behind the
// desktop or drawn off screen, so this view copies the panel's content: the
// same field, status line and shortlist, configured with the same fonts,
// insets, widths and row format as `CommandBar.swift`. The material is
// replaced by a blur of whatever the stage has under the bar, tinted dark.
#if DEBUG

import AppKit
import CoreImage
import QuartzCore

final class PromoCommandBar: NSView {

    /// `CommandBar.width` and its private `sideInset`.
    static let width: CGFloat = CommandBar.width
    private static let sideInset: CGFloat = 18
    private static let placeholder = "Name a control, like “the Preferences button”"

    private let content = NSView()
    private let backdrop = CALayer()
    private let tint = CALayer()
    private let field = NSTextField(string: "")
    private let hint = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let root = NSStackView()
    private var rows: [NSTextField] = []
    private let caret = CALayer()

    override var isFlipped: Bool { false }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: 58))
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        // The panel's window shadow.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 22
        layer?.shadowOffset = CGSize(width: 0, height: -10)
        layer?.masksToBounds = false

        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        backdrop.contentsGravity = .resize
        backdrop.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        tint.backgroundColor = NSColor(srgbRed: 0.11, green: 0.115, blue: 0.13, alpha: 0.80).cgColor
        tint.actions = ["bounds": NSNull(), "position": NSNull()]
        content.layer?.addSublayer(backdrop)
        content.layer?.addSublayer(tint)
        addSubview(content)

        // Field, hint and suggestion stack: as CommandBar.init configures them.
        field.placeholderString = Self.placeholder
        field.font = .systemFont(ofSize: 19, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.isEditable = false
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = false

        hint.usesSingleLineMode = false
        hint.maximumNumberOfLines = CommandBar.hintMaxLines
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
        stack.isHidden = true

        for v in [field, hint, stack] { root.addArrangedSubview(v) }
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.edgeInsets = NSEdgeInsets(top: 14, left: Self.sideInset, bottom: 12, right: Self.sideInset)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        let inner = -2 * Self.sideInset
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.width),
            field.widthAnchor.constraint(equalTo: root.widthAnchor, constant: inner),
            hint.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: inner),
            stack.widthAnchor.constraint(equalTo: root.widthAnchor, constant: inner),
        ])

        // The window never becomes key, so the field cannot draw its own
        // insertion point; the stage draws one where AppKit would.
        caret.backgroundColor = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1).cgColor
        caret.cornerRadius = 1
        caret.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
        caret.isHidden = true
        content.layer?.addSublayer(caret)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content, as CommandBar's public API sets it

    func setStatus(_ text: String) {
        hint.stringValue = text
    }

    func setQuery(_ text: String) {
        field.stringValue = text
    }

    func showSuggestions(_ suggestions: [(score: Double, label: String)]) {
        for v in rows { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        rows = suggestions.prefix(3).enumerated().map { i, row in
            let l = NSTextField(labelWithString: String(format: "%.2f  %@", row.score, row.label))
            l.usesSingleLineMode = true
            l.maximumNumberOfLines = 1
            l.lineBreakMode = .byTruncatingTail
            l.cell?.truncatesLastVisibleLine = true
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            l.font = .monospacedSystemFont(ofSize: 12, weight: i == 0 ? .medium : .regular)
            l.textColor = i == 0 ? .labelColor : .secondaryLabelColor
            l.translatesAutoresizingMaskIntoConstraints = false
            return l
        }
        for l in rows {
            stack.addArrangedSubview(l)
            l.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -4).isActive = true
        }
        stack.isHidden = rows.isEmpty
    }

    /// The height `CommandBar.fitToContent` would give the panel.
    var fittingHeight: CGFloat {
        content.frame.size = CGSize(width: Self.width, height: 400)
        content.layoutSubtreeIfNeeded()
        return ceil(root.fittingSize.height)
    }

    // MARK: - Placement

    /// Lay the bar out with its top edge at `top` (AppKit, stage space),
    /// growing downwards, the way `fitToContent` keeps the top edge still.
    func layout(top: CGFloat, centerX: CGFloat) {
        let h = fittingHeight
        frame = CGRect(x: centerX - Self.width / 2, y: top - h, width: Self.width, height: h)
        content.frame = bounds
        content.layoutSubtreeIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The backdrop is taller than the bar and pinned to its top, so the
        // bar can grow over it without a new snapshot.
        let backdropHeight = backdrop.bounds.height
        backdrop.frame = CGRect(x: 0, y: h - backdropHeight, width: Self.width, height: backdropHeight)
        tint.frame = CGRect(origin: .zero, size: CGSize(width: Self.width, height: h))
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        updateCaret()
        CATransaction.commit()
    }

    /// Show a caret after the typed text, or hide it.
    var showsCaret = false { didSet { updateCaret() } }

    private func updateCaret() {
        guard showsCaret else { caret.isHidden = true; return }
        let text = field.stringValue as NSString
        let width = text.size(withAttributes: [.font: field.font as Any]).width
        let frameInContent = field.convert(field.bounds, to: content)
        // NSTextField's text starts 2 pt in from its frame.
        let x = frameInContent.minX + 2 + ceil(width) + (text.length == 0 ? 0 : 1)
        caret.frame = CGRect(x: x, y: frameInContent.midY - 11, width: 2, height: 22)
        caret.isHidden = false
    }

    func setCaretVisible(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caret.opacity = on ? 1 : 0
        CATransaction.commit()
    }

    /// Use `image` (a snapshot of the stage under the bar, `height` points
    /// tall from the bar's top edge) as the frosted background.
    func setBackdrop(_ image: CGImage?, height: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.contents = image.flatMap(Self.frost)
        backdrop.bounds = CGRect(x: 0, y: 0, width: Self.width, height: height)
        CATransaction.commit()
    }

    private static let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])

    /// Blur and lift saturation, roughly what the HUD material does.
    private static func frost(_ image: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let scale = CGFloat(image.width) / width
        let blurred = ci.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 26 * scale])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.6,
                                                             kCIInputBrightnessKey: -0.02])
            .cropped(to: ci.extent)
        return ciContext.createCGImage(blurred, from: ci.extent)
    }
}

#endif
