import Cocoa

extension Notification.Name {
    static let autoHideSettingChanged       = Notification.Name("dwb.autoHideSettingChanged")
    /// Posted when any optional-control visibility setting changes.
    /// All open TransportControlsView instances observe this and call applyVisibilitySettings().
    static let transportVisibilityChanged   = Notification.Name("dwb.transportVisibilityChanged")
    /// Posted when the shared skip-duration preference changes.
    static let skipDurationChanged          = Notification.Name("dwb.skipDurationChanged")
}

/// Singleton settings panel. Open via dwb > Settings… (Cmd+,).
/// Exposes: windowed transport auto-hide + optional transport control visibility.
final class SettingsWindowController: NSWindowController {

    enum OptionalTransportControl: CaseIterable, Hashable {
        case stop
        case volume
        case shuffle
        case repeatOne
        case quickQueue

        var defaultsKey: String {
            switch self {
            case .stop:
                return "showStopButton"
            case .volume:
                return "showVolumeButton"
            case .shuffle:
                return "showShuffleButton"
            case .repeatOne:
                return "showRepeatButton"
            case .quickQueue:
                return "showQuickQueueButton"
            }
        }

        var settingsTitle: String {
            switch self {
            case .stop:
                return "Show Stop button"
            case .volume:
                return "Show Volume button"
            case .shuffle:
                return "Show Shuffle button"
            case .repeatOne:
                return "Show Repeat button"
            case .quickQueue:
                return "Show Quick Queue button"
            }
        }
    }

    static let shared = SettingsWindowController()

    // MARK: - UserDefaults keys

    /// Non-fullscreen transport auto-hide. Default: false.
    static let autoHideKey          = "autoHideTransportWindowed"

    /// Optional transport button visibility keys. All default OFF (hidden).
    static let showStopKey          = OptionalTransportControl.stop.defaultsKey
    static let showVolumeKey        = OptionalTransportControl.volume.defaultsKey
    static let showShuffleKey       = OptionalTransportControl.shuffle.defaultsKey
    static let showRepeatKey        = OptionalTransportControl.repeatOne.defaultsKey
    static let showQuickQueueKey    = OptionalTransportControl.quickQueue.defaultsKey
    static let persistedVolumeKey   = "lastEffectiveVolume"
    static let skipDurationKey      = "skipDurationSeconds"
    static let defaultSkipDurationSeconds = 10

    struct SkipDurationOption {
        let seconds: Int
        let title: String
    }

    static let skipDurationOptions: [SkipDurationOption] = [
        SkipDurationOption(seconds: 10, title: "10 seconds"),
        SkipDurationOption(seconds: 30, title: "30 seconds"),
        SkipDurationOption(seconds: 60, title: "60 seconds"),
        SkipDurationOption(seconds: 180, title: "3 minutes")
    ]

    static func registerDefaults() {
        var defaults: [String: Any] = [
            autoHideKey: false,
            skipDurationKey: defaultSkipDurationSeconds
        ]
        for control in OptionalTransportControl.allCases {
            defaults[control.defaultsKey] = false
        }
        UserDefaults.standard.register(defaults: defaults)
    }

    static func validatedSkipDurationSeconds(_ value: Int) -> Int {
        skipDurationOptions.contains(where: { $0.seconds == value }) ? value : defaultSkipDurationSeconds
    }

    static func currentSkipDurationSeconds() -> Int {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: skipDurationKey).map { _ in defaults.integer(forKey: skipDurationKey) }
            ?? defaultSkipDurationSeconds
        let validated = validatedSkipDurationSeconds(stored)
        if validated != stored {
            defaults.set(validated, forKey: skipDurationKey)
        }
        return validated
    }

    static func skipDurationTitle(seconds: Int) -> String {
        skipDurationOptions.first(where: { $0.seconds == validatedSkipDurationSeconds(seconds) })?.title
            ?? "\(defaultSkipDurationSeconds) seconds"
    }

    static func skipActionTitle(isForward: Bool, seconds: Int) -> String {
        "\(isForward ? "Forward" : "Rewind") \(skipDurationTitle(seconds: seconds))"
    }

    static func isOptionalTransportControlVisible(_ control: OptionalTransportControl) -> Bool {
        UserDefaults.standard.bool(forKey: control.defaultsKey)
    }

    // MARK: - Controls

    private let autoHideCheckbox        = NSButton()
    private let skipDurationLabel       = NSTextField(labelWithString: "Skip duration")
    private let skipDurationPopup       = NSPopUpButton()
    private var optionalControlCheckboxes: [OptionalTransportControl: NSButton] = [:]

    // MARK: - Init

    private init() {
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 356),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Settings"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI construction

    private func buildUI() {
        guard let cv = window?.contentView else { return }
        let lead: CGFloat = 20
        let gap:  CGFloat = 4   // tight spacing between rows

        // Helper: configure a switch-style checkbox
        func configure(_ btn: NSButton, title: String, state: Bool) {
            btn.setButtonType(.switch)
            btn.title = title
            btn.font  = .systemFont(ofSize: NSFont.systemFontSize)
            btn.target = self
            btn.action = #selector(checkboxToggled(_:))
            btn.state  = state ? .on : .off
            btn.translatesAutoresizingMaskIntoConstraints = false
            cv.addSubview(btn)
        }

        let controlsLabel = NSTextField(labelWithString: "Player Controls")
        controlsLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        controlsLabel.textColor = .secondaryLabelColor
        controlsLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(controlsLabel)

        configure(autoHideCheckbox,
                  title: "Auto-hide controls bar in windowed mode",
                  state: UserDefaults.standard.bool(forKey: Self.autoHideKey))

        skipDurationLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        skipDurationLabel.textColor = .labelColor
        skipDurationLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(skipDurationLabel)

        skipDurationPopup.translatesAutoresizingMaskIntoConstraints = false
        skipDurationPopup.target = self
        skipDurationPopup.action = #selector(skipDurationPopupChanged(_:))
        for option in Self.skipDurationOptions {
            skipDurationPopup.addItem(withTitle: option.title)
            skipDurationPopup.lastItem?.tag = option.seconds
        }
        cv.addSubview(skipDurationPopup)

        // Section header (read-only label)
        let sectionLabel = NSTextField(labelWithString: "Optional Controls")
        sectionLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        sectionLabel.textColor = .secondaryLabelColor
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(sectionLabel)

        let sectionNote = NSTextField(labelWithString: "These stay hidden by default until enabled here.")
        sectionNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sectionNote.textColor = .secondaryLabelColor
        sectionNote.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(sectionNote)

        var previousOptionalCheckbox: NSButton?
        for control in OptionalTransportControl.allCases {
            let checkbox = NSButton()
            configure(checkbox,
                      title: control.settingsTitle,
                      state: Self.isOptionalTransportControlVisible(control))
            optionalControlCheckboxes[control] = checkbox
            if let previousOptionalCheckbox {
                checkbox.topAnchor.constraint(equalTo: previousOptionalCheckbox.bottomAnchor, constant: gap).isActive = true
            } else {
                checkbox.topAnchor.constraint(equalTo: sectionNote.bottomAnchor, constant: gap).isActive = true
            }
            checkbox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead).isActive = true
            previousOptionalCheckbox = checkbox
        }

        NSLayoutConstraint.activate([
            controlsLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            controlsLabel.topAnchor.constraint(equalTo: cv.topAnchor, constant: 16),

            autoHideCheckbox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            autoHideCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            autoHideCheckbox.topAnchor.constraint(equalTo: controlsLabel.bottomAnchor, constant: 6),

            skipDurationLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            skipDurationLabel.topAnchor.constraint(equalTo: autoHideCheckbox.bottomAnchor, constant: 16),

            skipDurationPopup.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            skipDurationPopup.topAnchor.constraint(equalTo: skipDurationLabel.bottomAnchor, constant: 6),
            skipDurationPopup.widthAnchor.constraint(equalToConstant: 160),

            sectionLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            sectionLabel.topAnchor.constraint(equalTo: skipDurationPopup.bottomAnchor, constant: 16),
            sectionNote.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            sectionNote.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            sectionNote.topAnchor.constraint(equalTo: sectionLabel.bottomAnchor, constant: 2),
        ])

        syncUIFromDefaults()
    }

    // MARK: - Actions

    @objc private func checkboxToggled(_ sender: NSButton) {
        let enabled = sender.state == .on

        if sender === autoHideCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.autoHideKey)
            NotificationCenter.default.post(name: .autoHideSettingChanged, object: nil)
            return
        }

        guard let control = optionalControlCheckboxes.first(where: { $0.value === sender })?.key else { return }
        UserDefaults.standard.set(enabled, forKey: control.defaultsKey)
        NotificationCenter.default.post(name: .transportVisibilityChanged, object: nil)
    }

    @objc private func skipDurationPopupChanged(_ sender: NSPopUpButton) {
        let selected = Self.validatedSkipDurationSeconds(sender.selectedTag())
        UserDefaults.standard.set(selected, forKey: Self.skipDurationKey)
        NotificationCenter.default.post(name: .skipDurationChanged, object: nil)
        syncUIFromDefaults()
    }

    private func syncUIFromDefaults() {
        autoHideCheckbox.state = UserDefaults.standard.bool(forKey: Self.autoHideKey) ? .on : .off
        for (control, checkbox) in optionalControlCheckboxes {
            checkbox.state = Self.isOptionalTransportControlVisible(control) ? .on : .off
        }
        skipDurationPopup.selectItem(withTag: Self.currentSkipDurationSeconds())
    }

    // MARK: - Open

    func openSettings() {
        syncUIFromDefaults()
        if !window!.isVisible {
            window?.center()
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
