import Cocoa

final class RailButton: NSButton {
    enum Style {
        case normal
        case emphasized
        case utility
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

        let baseFill: CGFloat
        let baseBorder: CGFloat
        let tint: NSColor
        switch railStyle {
        case .normal:
            baseFill = 0.06
            baseBorder = 0.07
            tint = .white
        case .emphasized:
            baseFill = 0.14
            baseBorder = 0.11
            tint = .white
        case .utility:
            baseFill = 0.08
            baseBorder = 0.09
            tint = NSColor(calibratedRed: 0.78, green: 0.88, blue: 1.0, alpha: 1.0)
        case .warning:
            baseFill = 0.10
            baseBorder = 0.11
            tint = NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.34, alpha: 1.0)
        }

        let toggledBoost: CGFloat = isToggled ? 0.18 : 0
        let hoverBoost: CGFloat = isHovering && isEnabled ? 0.08 : 0
        layer?.backgroundColor = NSColor.white.withAlphaComponent(baseFill + toggledBoost + hoverBoost).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(baseBorder + toggledBoost).cgColor
        contentTintColor = tint.withAlphaComponent(isEnabled ? (isToggled ? 1.0 : 0.82) : 0.46)
    }
}
