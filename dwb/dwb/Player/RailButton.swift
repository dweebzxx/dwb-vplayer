import Cocoa

enum PrefixBrandColors {
    // Brand color system categorical mapping for dark graphite UI:
    // Primary custom prefix = Dark Teal 500 (#488FA0).
    static let primaryCustomPrefixColor = NSColor(calibratedRed: 72.0 / 255.0,
                                                  green: 143.0 / 255.0,
                                                  blue: 160.0 / 255.0,
                                                  alpha: 1.0)

    // Secondary custom prefix = Burnt Orange 300 (#D4906A). This stop is more
    // legible than Burnt Orange 500 on the app's dark graphite surfaces.
    static let secondaryCustomPrefixColor = NSColor(calibratedRed: 212.0 / 255.0,
                                                    green: 144.0 / 255.0,
                                                    blue: 106.0 / 255.0,
                                                    alpha: 1.0)
}

/// Compact keyboard-shortcut tag rendered beside a control (e.g. "Q" next to the
/// custom prefix rename buttons). Decorative only: it never intercepts clicks and is hidden
/// from accessibility — the shortcut is announced through the control's own
/// help/tooltip text instead. Dark-theme styling matches the rail/footer chrome.
final class ShortcutKeyBadge: NSTextField {
    static let badgeWidth: CGFloat  = 15
    static let badgeHeight: CGFloat = 13

    init(key: String) {
        super.init(frame: .zero)
        stringValue = key
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        alignment = .center
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        font = .monospacedSystemFont(ofSize: 8, weight: .semibold)
        textColor = NSColor.white.withAlphaComponent(0.60)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1.0
        layer?.cornerRadius = 3
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class RailButton: NSButton {
    enum Style {
        case normal
        case emphasized
        case utility
        case prefixPrimary
        case prefixSecondary
        case warning
    }

    var railStyle: Style = .normal {
        didSet { updateAppearance() }
    }

    var isToggled: Bool = false {
        didSet { updateAppearance() }
    }

    private var isHovering = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("programmatic only")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
    }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    override var title: String {
        didSet { updateAppearance() }
    }

    func configureSymbol(_ symbolName: String,
                         pointSize: CGFloat,
                         accessibilityLabel: String,
                         help: String,
                         fallbackNames: [String] = []) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        for candidate in [symbolName] + fallbackNames {
            if let image = NSImage(systemSymbolName: candidate,
                                   accessibilityDescription: accessibilityLabel) {
                self.image = image.withSymbolConfiguration(cfg) ?? image
                break
            }
        }
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityHelp(help)
        toolTip = help
    }

    private func configure() {
        isBordered = false
        bezelStyle = .regularSquare
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        layer?.borderWidth = 1
        contentTintColor = NSColor.white.withAlphaComponent(0.88)
        updateAppearance()
    }

    private func updateAppearance() {
        let enabledAlpha: CGFloat = isEnabled ? 1.0 : 0.34
        alphaValue = enabledAlpha

        // Hover-only circle outline: at rest the button shows only its icon/text on the
        // transparent rail; the circular fill + border appear only while the cursor is
        // over the button. Toggled state is communicated by the symbol/tint, not by a
        // permanent outline.
        let hoverFill:   CGFloat
        let hoverBorder: CGFloat
        let tint: NSColor
        switch railStyle {
        case .normal:
            hoverFill   = 0.14
            hoverBorder = 0.18
            tint = .white
        case .emphasized:
            hoverFill   = 0.22
            hoverBorder = 0.20
            tint = .white
        case .utility:
            hoverFill   = 0.16
            hoverBorder = 0.20
            tint = NSColor(calibratedRed: 0.78, green: 0.88, blue: 1.0, alpha: 1.0)
        case .prefixPrimary:
            hoverFill   = 0.16
            hoverBorder = 0.20
            tint = PrefixBrandColors.primaryCustomPrefixColor
        case .prefixSecondary:
            hoverFill   = 0.16
            hoverBorder = 0.20
            tint = PrefixBrandColors.secondaryCustomPrefixColor
        case .warning:
            hoverFill   = 0.18
            hoverBorder = 0.22
            tint = NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.34, alpha: 1.0)
        }

        let hoverActive = isHovering && isEnabled
        let fillAlpha:   CGFloat = hoverActive ? (hoverFill   + (isToggled ? 0.06 : 0)) : 0
        let borderAlpha: CGFloat = hoverActive ? (hoverBorder + (isToggled ? 0.06 : 0)) : 0
        layer?.backgroundColor = NSColor.white.withAlphaComponent(fillAlpha).cgColor
        layer?.borderColor     = NSColor.white.withAlphaComponent(borderAlpha).cgColor
        let effectiveTint = tint.withAlphaComponent(isEnabled ? (isToggled ? 1.0 : 0.82) : 0.46)
        contentTintColor = effectiveTint
        applyTitleTint(effectiveTint)
    }

    private func applyTitleTint(_ tint: NSColor) {
        guard image == nil else { return }
        let currentTitle = title
        guard !currentTitle.isEmpty else {
            attributedTitle = NSAttributedString(string: "")
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: tint
        ]
        attributedTitle = NSAttributedString(string: currentTitle, attributes: attributes)
    }
}
