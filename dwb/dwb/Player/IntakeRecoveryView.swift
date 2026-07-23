import Cocoa

final class IntakeRecoveryView: NSView {
    var actionHandler: ((MediaIntakeRecoveryAction) -> Void)?
    var dismissHandler: (() -> Void)?
    var layoutDidChange: (() -> Void)?

    private let backgroundView = NSVisualEffectView()
    private let statusImageView = NSImageView()
    private let progressIndicator = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let detailsLabel = NSTextField(wrappingLabelWithString: "")
    private let dismissButton = NSButton()
    private var actionButtons: [NSButton] = []
    private var actions: [MediaIntakeRecoveryAction] = []
    private var presentation: MediaIntakeRecoveryPresentation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    func present(_ presentation: MediaIntakeRecoveryPresentation) {
        self.presentation = presentation
        titleLabel.stringValue = presentation.title
        messageLabel.stringValue = presentation.message
        detailsLabel.stringValue = presentation.details
        detailsLabel.isHidden = true
        applyPresentationStyle(presentation)
        rebuildActionButtons(for: presentation.actions)
        dismissButton.isHidden = !presentation.allowsDismissal
        dismissButton.setAccessibilityElement(presentation.allowsDismissal)
        setAccessibilityLabel(presentation.title)
        setAccessibilityValue(presentation.message)
        setAccessibilityElement(true)
        isHidden = false
        needsLayout = true
        layoutDidChange?()
        window?.recalculateKeyViewLoop()
    }

    func dismiss() {
        isHidden = true
        setAccessibilityElement(false)
        actionButtons.forEach { $0.setAccessibilityElement(false) }
        dismissButton.setAccessibilityElement(false)
        window?.recalculateKeyViewLoop()
    }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        guard let presentation else { return 154 }
        let compact = width < 380
        let actionBlockHeight: CGFloat
        if presentation.actions.isEmpty {
            actionBlockHeight = 0
        } else if compact {
            actionBlockHeight = CGFloat(presentation.actions.count) * 28
                + CGFloat(max(0, presentation.actions.count - 1)) * 6
        } else {
            actionBlockHeight = 28
        }
        let detailsHeight: CGFloat = detailsLabel.isHidden ? 0 : 42
        return max(118, 104 + actionBlockHeight + detailsHeight)
    }

    override func layout() {
        super.layout()
        backgroundView.frame = bounds
        let inset: CGFloat = 14
        let closeSize: CGFloat = 24
        dismissButton.frame = NSRect(x: bounds.width - inset - closeSize,
                                     y: bounds.height - inset - closeSize,
                                     width: closeSize,
                                     height: closeSize)
        let statusSize: CGFloat = 24
        statusImageView.frame = NSRect(x: inset,
                                       y: bounds.height - inset - statusSize,
                                       width: statusSize,
                                       height: statusSize)
        progressIndicator.frame = statusImageView.frame.insetBy(dx: 3, dy: 3)
        let textLeading = inset + statusSize + 10
        titleLabel.frame = NSRect(x: textLeading,
                                  y: bounds.height - inset - 20,
                                  width: max(0, dismissButton.frame.minX - textLeading - 8),
                                  height: 20)
        messageLabel.frame = NSRect(x: textLeading,
                                    y: bounds.height - inset - 58,
                                    width: max(0, bounds.width - textLeading - inset),
                                    height: 34)

        let buttonHeight: CGFloat = 28
        let compact = bounds.width < 380
        let buttonBlockHeight: CGFloat
        if compact {
            buttonBlockHeight = actionButtons.isEmpty
                ? 0
                : CGFloat(actionButtons.count) * buttonHeight + CGFloat(max(0, actionButtons.count - 1)) * 6
            for (index, button) in actionButtons.enumerated() {
                let y = inset + CGFloat(actionButtons.count - index - 1) * (buttonHeight + 6)
                button.frame = NSRect(x: textLeading,
                                      y: y,
                                      width: max(0, bounds.width - textLeading - inset),
                                      height: buttonHeight)
            }
        } else {
            buttonBlockHeight = actionButtons.isEmpty ? 0 : buttonHeight
            var x = textLeading
            for button in actionButtons {
                let width = max(78, ceil(button.intrinsicContentSize.width) + 20)
                button.frame = NSRect(x: x, y: inset, width: width, height: buttonHeight)
                x += width + 8
            }
        }

        detailsLabel.frame = detailsLabel.isHidden
            ? .zero
            : NSRect(x: textLeading,
                     y: inset + buttonBlockHeight + 8,
                     width: max(0, bounds.width - textLeading - inset),
                     height: 34)
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = PlayerBrandColors.darkOchre.withAlphaComponent(0.55).cgColor
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("player.intakeRecovery")
        isHidden = true
        setAccessibilityElement(false)

        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .withinWindow
        backgroundView.state = .active
        addSubview(backgroundView)

        statusImageView.imageScaling = .scaleProportionallyDown
        statusImageView.setAccessibilityElement(false)
        addSubview(statusImageView)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.setAccessibilityElement(false)
        progressIndicator.isHidden = true
        addSubview(progressIndicator)

        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)

        messageLabel.font = .systemFont(ofSize: 11.5)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 2
        messageLabel.setAccessibilityElement(false)
        addSubview(messageLabel)

        detailsLabel.font = .systemFont(ofSize: 10.5)
        detailsLabel.textColor = .tertiaryLabelColor
        detailsLabel.maximumNumberOfLines = 2
        detailsLabel.setAccessibilityElement(false)
        addSubview(detailsLabel)

        dismissButton.isBordered = false
        dismissButton.bezelStyle = .regularSquare
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        dismissButton.toolTip = "Dismiss intake message"
        dismissButton.setAccessibilityLabel("Dismiss")
        dismissButton.setAccessibilityHelp("Dismiss this media intake message")
        dismissButton.setAccessibilityIdentifier("player.intakeRecovery.dismiss")
        dismissButton.target = self
        dismissButton.action = #selector(dismissTapped)
        addSubview(dismissButton)
    }

    private func rebuildActionButtons(for actions: [MediaIntakeRecoveryAction]) {
        actionButtons.forEach { $0.removeFromSuperview() }
        self.actions = actions
        actionButtons = actions.enumerated().map { index, action in
            let button = NSButton(title: action.title, target: self, action: #selector(actionTapped(_:)))
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.tag = index
            button.toolTip = action.title
            button.setAccessibilityLabel(action.title)
            button.setAccessibilityHelp(accessibilityHelp(for: action))
            button.setAccessibilityIdentifier("player.intakeRecovery.\(action.rawValue)")
            button.setAccessibilityElement(true)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.borderWidth = 1
            if index == 0 {
                button.isBordered = false
                button.layer?.backgroundColor = PlayerBrandColors.periwinkle.withAlphaComponent(0.72).cgColor
                button.layer?.borderColor = PlayerBrandColors.periwinkleLight.withAlphaComponent(0.50).cgColor
                button.contentTintColor = .white
                button.font = .systemFont(ofSize: 11, weight: .semibold)
            } else if action == .showDetails {
                button.isBordered = false
                button.layer?.backgroundColor = NSColor.clear.cgColor
                button.layer?.borderColor = NSColor.clear.cgColor
                button.contentTintColor = .secondaryLabelColor
            } else {
                button.isBordered = false
                button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
                button.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
                button.contentTintColor = .labelColor
            }
            addSubview(button)
            return button
        }
        dismissButton.setAccessibilityElement(presentation?.allowsDismissal == true)
    }

    private func applyPresentationStyle(_ presentation: MediaIntakeRecoveryPresentation) {
        let symbolName: String
        let foreground: NSColor
        let border: NSColor
        switch presentation.style {
        case .progress:
            symbolName = "magnifyingglass"
            foreground = PlayerBrandColors.periwinkleLight
            border = PlayerBrandColors.periwinkle
        case .warning:
            symbolName = "exclamationmark.triangle.fill"
            foreground = PlayerBrandColors.darkOchreLight
            border = PlayerBrandColors.darkOchre
        case .error:
            symbolName = "xmark.octagon.fill"
            foreground = PlayerBrandColors.crimsonLight
            border = PlayerBrandColors.crimson
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        statusImageView.image = image?.withSymbolConfiguration(configuration) ?? image
        statusImageView.contentTintColor = foreground
        layer?.borderColor = border.withAlphaComponent(0.58).cgColor
        progressIndicator.isHidden = presentation.style != .progress
        statusImageView.isHidden = presentation.style == .progress
        if presentation.style == .progress {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    private func accessibilityHelp(for action: MediaIntakeRecoveryAction) -> String {
        switch action {
        case .addMedia: return "Choose local files or folders to add"
        case .openAcceptSettings: return "Open the Accept media type settings"
        case .retryRescan: return "Retry scanning the source folder"
        case .revealSource: return "Reveal the source folder in Finder"
        case .locateSource: return "Choose the source folder again"
        case .showDetails: return "Show diagnostic details for this failure"
        }
    }

    @objc private func dismissTapped() {
        dismissHandler?()
    }

    @objc private func actionTapped(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        let action = actions[sender.tag]
        if action == .showDetails {
            detailsLabel.isHidden.toggle()
            sender.title = detailsLabel.isHidden ? "Show Details" : "Hide Details"
            sender.setAccessibilityLabel(sender.title)
            setAccessibilityValue(detailsLabel.isHidden
                ? presentation?.message
                : [presentation?.message, presentation?.details].compactMap { $0 }.joined(separator: " "))
            needsLayout = true
            layoutDidChange?()
            return
        }
        actionHandler?(action)
    }
}
