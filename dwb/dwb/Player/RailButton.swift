import Cocoa

enum PlayerBrandColors {
    // Periwinkle (#4C62A8): brand accent for bookmark and active states.
    static let periwinkle = NSColor(calibratedRed: 76.0 / 255.0,
                                    green: 98.0 / 255.0,
                                    blue: 168.0 / 255.0,
                                    alpha: 1.0)

    // Periwinkle 300 (#9AAAD8): light keyline/focus stop for dark surfaces.
    static let periwinkleLight = NSColor(calibratedRed: 154.0 / 255.0,
                                         green: 170.0 / 255.0,
                                         blue: 216.0 / 255.0,
                                         alpha: 1.0)

    // Dark Ochre 700 (#A87820): reserved caution/attention status color.
    static let darkOchre = NSColor(calibratedRed: 168.0 / 255.0,
                                   green: 120.0 / 255.0,
                                   blue: 32.0 / 255.0,
                                   alpha: 1.0)

    // Dark Ochre 300 (#E0C060): legible caution foreground on dark surfaces.
    static let darkOchreLight = NSColor(calibratedRed: 224.0 / 255.0,
                                        green: 192.0 / 255.0,
                                        blue: 96.0 / 255.0,
                                        alpha: 1.0)

    // Crimson (#B03828): reserved brand status color for destructive actions.
    static let crimson = NSColor(calibratedRed: 176.0 / 255.0,
                                 green: 56.0 / 255.0,
                                 blue: 40.0 / 255.0,
                                 alpha: 1.0)

    // Crimson 300 (#E09888): legible error foreground on dark surfaces.
    static let crimsonLight = NSColor(calibratedRed: 224.0 / 255.0,
                                      green: 152.0 / 255.0,
                                      blue: 136.0 / 255.0,
                                      alpha: 1.0)
}

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
        case bookmark
        case warning
    }

    var railStyle: Style = .normal {
        didSet { updateAppearance() }
    }

    var isToggled: Bool = false {
        didSet {
            setAccessibilityValue(isToggled ? "on" : "off")
            updateAppearance()
        }
    }

    var interactionStateDidChange: (() -> Void)?

    private var isHovering = false
    private var isPressing = false
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
        interactionStateDidChange?()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
        interactionStateDidChange?()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            super.mouseDown(with: event)
            return
        }
        isPressing = true
        updateAppearance()
        interactionStateDidChange?()
        super.mouseDown(with: event)
        isPressing = false
        updateAppearance()
        interactionStateDidChange?()
    }

    override var isEnabled: Bool {
        didSet {
            setAccessibilityEnabled(isEnabled)
            updateAppearance()
        }
    }

    override var title: String {
        didSet { updateAppearance() }
    }

    override var acceptsFirstResponder: Bool {
        isEnabled && !isHidden && alphaValue > 0.05
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateAppearance()
        interactionStateDidChange?()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        updateAppearance()
        interactionStateDidChange?()
        return resigned
    }

    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }

    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: focusRingMaskBounds).fill()
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
        focusRingType = .none
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        layer?.borderWidth = 1
        contentTintColor = NSColor.white.withAlphaComponent(0.88)
        updateAppearance()
    }

    private func updateAppearance() {
        let enabledAlpha: CGFloat = isEnabled ? 1.0 : 0.32
        alphaValue = enabledAlpha

        let tint: NSColor
        switch railStyle {
        case .normal:
            tint = .white
        case .emphasized:
            tint = .white
        case .utility:
            tint = PlayerBrandColors.periwinkleLight
        case .prefixPrimary:
            tint = PrefixBrandColors.primaryCustomPrefixColor
        case .prefixSecondary:
            tint = PrefixBrandColors.secondaryCustomPrefixColor
        case .bookmark:
            tint = PlayerBrandColors.periwinkleLight
        case .warning:
            tint = PlayerBrandColors.darkOchreLight
        }

        let keyboardFocused = window?.firstResponder === self
        let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let activeColor: NSColor = {
            switch railStyle {
            case .prefixPrimary: return PrefixBrandColors.primaryCustomPrefixColor
            case .prefixSecondary: return PrefixBrandColors.secondaryCustomPrefixColor
            case .warning: return PlayerBrandColors.darkOchre
            default: return PlayerBrandColors.periwinkle
            }
        }()

        var fillColor = NSColor.clear
        var borderColor = NSColor.clear
        if railStyle == .emphasized && isEnabled {
            fillColor = NSColor.white.withAlphaComponent(0.15)
            borderColor = NSColor.white.withAlphaComponent(0.18)
        }
        if isToggled && isEnabled {
            fillColor = activeColor.withAlphaComponent(isHovering ? 0.28 : 0.20)
            borderColor = activeColor.withAlphaComponent(increasedContrast ? 0.90 : 0.56)
        }
        if isHovering && isEnabled {
            fillColor = isToggled
                ? activeColor.withAlphaComponent(0.28)
                : NSColor.white.withAlphaComponent(railStyle == .emphasized ? 0.24 : 0.13)
            borderColor = isToggled
                ? activeColor.withAlphaComponent(0.68)
                : NSColor.white.withAlphaComponent(increasedContrast ? 0.48 : 0.22)
        }
        if isPressing && isEnabled {
            fillColor = isToggled
                ? activeColor.withAlphaComponent(0.36)
                : NSColor.white.withAlphaComponent(0.24)
            borderColor = isToggled
                ? activeColor.withAlphaComponent(0.82)
                : NSColor.white.withAlphaComponent(0.34)
        }
        if keyboardFocused && isEnabled {
            borderColor = PlayerBrandColors.periwinkleLight.withAlphaComponent(increasedContrast ? 1.0 : 0.88)
            if fillColor.alphaComponent == 0 {
                fillColor = PlayerBrandColors.periwinkle.withAlphaComponent(0.14)
            }
        }

        layer?.backgroundColor = fillColor.cgColor
        layer?.borderColor = borderColor.cgColor
        layer?.borderWidth = keyboardFocused && increasedContrast ? 2 : 1
        let effectiveTint = tint.withAlphaComponent(isEnabled ? (isToggled ? 1.0 : 0.84) : 0.48)
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
