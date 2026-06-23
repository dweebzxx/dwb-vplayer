import Cocoa

extension Notification.Name {
    static let autoHideSettingChanged         = Notification.Name("dwb.autoHideSettingChanged")
    /// Posted when any optional-control visibility setting changes.
    /// All open TransportControlsView instances observe this and call applyVisibilitySettings().
    static let transportVisibilityChanged     = Notification.Name("dwb.transportVisibilityChanged")
    /// Posted when the shared skip-duration preference changes.
    static let skipDurationChanged            = Notification.Name("dwb.skipDurationChanged")
    /// Posted when the titlebar auto-hide setting changes.
    static let autoHideTitlebarChanged        = Notification.Name("dwb.autoHideTitlebarChanged")
    /// Posted when windowed Complete Video Mode changes.
    static let completeVideoWindowModeChanged = Notification.Name("dwb.completeVideoWindowModeChanged")
    /// Posted when the image slideshow display duration changes.
    static let imageDurationChanged           = Notification.Name("dwb.imageDurationChanged")
    /// Posted when the GIF playback loop-count setting changes.
    static let gifLoopCountChanged            = Notification.Name("dwb.gifLoopCountChanged")
    /// Posted when accepted media type settings change.
    static let acceptedMediaTypesChanged      = Notification.Name("dwb.acceptedMediaTypesChanged")
    /// Posted when the title overlay on playback start setting changes.
    static let titleOverlaySettingChanged     = Notification.Name("dwb.titleOverlaySettingChanged")
    /// Posted when the one-click custom prefix rename setting changes.
    static let customPrefixRenameChanged                   = Notification.Name("dwb.customPrefixRenameChanged")
    /// Posted when the video-page custom prefix button visibility setting changes.
    static let videoPageCustomPrefixButtonSettingChanged   = Notification.Name("dwb.videoPageCustomPrefixButtonSettingChanged")
    /// Posted when the stored custom prefix value changes.
    static let customPrefixValueChanged                    = Notification.Name("dwb.customPrefixValueChanged")
    /// Posted when the debug console enable setting changes.
    static let debugConsoleSettingChanged     = Notification.Name("dwb.debugConsoleSettingChanged")
    /// Posted when one player window's playback speed changes.
    static let playbackSpeedChanged           = Notification.Name("dwb.playbackSpeedChanged")
    /// Posted when any of the playback-bar button visibility toggles (x_,
    /// Shuffle, Replay, Volume, Bookmark) change. BottomRailView observes
    /// this and re-applies button visibility / rebuilds the More menu.
    static let bottomRailButtonVisibilityChanged = Notification.Name("dwb.bottomRailButtonVisibilityChanged")
}

/// Singleton settings panel. Open via dwb > Settings… (Cmd+,).
/// Four sidebar sections: Playback, Controls, Queue & Files, Developer.
/// Navigation uses the suite-shared settings pattern (matches dwb skim):
/// visual-effect sidebar with rounded, suite-accent-selected items.
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {

    enum OptionalTransportControl: CaseIterable, Hashable {
        case stop, volume, shuffle, repeatOne

        var defaultsKey: String {
            switch self {
            case .stop:      return "showStopButton"
            case .volume:    return "showVolumeButton"
            case .shuffle:   return "showShuffleButton"
            case .repeatOne: return "showRepeatButton"
            }
        }

        var settingsTitle: String {
            switch self {
            case .stop:      return "Show Stop button"
            case .volume:    return "Show Volume button"
            case .shuffle:   return "Show Shuffle button"
            case .repeatOne: return "Show Repeat button"
            }
        }
    }

    static let shared = SettingsWindowController()

    // MARK: - UserDefaults keys

    /// Non-fullscreen transport auto-hide. Default: false.
    static let autoHideKey              = "autoHideTransportWindowed"
    /// Optional transport button visibility keys. All default OFF (hidden).
    static let showStopKey              = OptionalTransportControl.stop.defaultsKey
    static let showVolumeKey            = OptionalTransportControl.volume.defaultsKey
    static let showShuffleKey           = OptionalTransportControl.shuffle.defaultsKey
    static let showRepeatKey            = OptionalTransportControl.repeatOne.defaultsKey
    static let persistedVolumeKey       = "lastEffectiveVolume"
    static let skipDurationKey          = "skipDurationSeconds"
    static let defaultSkipDurationSeconds = 10
    /// Titlebar auto-hide in windowed mode. Default: false.
    static let autoHideTitlebarKey      = "autoHideTitlebar"
    /// Hide the titlebar chrome in windowed mode so video reaches the top edge. Default: false.
    static let completeVideoWindowModeKey = "completeVideoWindowMode"
    /// Image slideshow display duration in seconds. Default: 3.
    static let imageDurationKey         = "imageDurationSeconds"
    static let defaultImageDurationSeconds = 3
    /// GIF playback loop count before queue advance. Default: 1.
    static let gifLoopCountKey          = "gifLoopCount"
    static let defaultGIFLoopCount      = 1
    /// Accepted media types for open/drop intake. Defaults: all true.
    static let acceptVideoKey           = "acceptVideoMedia"
    static let acceptImagesKey          = "acceptImageMedia"
    static let acceptGIFKey             = "acceptGIFMedia"
    /// Show title overlay when video or image playback starts. Default: true.
    static let showTitleOverlayKey      = "showTitleOverlay"
    /// One-click delete_ prefix rename in Queue Page (legacy key; migrated to customPrefixQueuePageKey).
    static let deletePrefixRenameKey    = "deletePrefixRenameEnabled"
    /// Show d_ rename button in player/video page (legacy key; migrated to customPrefixVideoPageKey).
    static let videoPageDButtonKey      = "videoPageDButtonEnabled"
    /// Stored custom prefix string for one-click rename. Trailing spaces preserved. Default: "".
    static let customPrefixValueKey     = "customPrefixValue"
    /// One-click custom prefix rename in Queue Page. Default: false (migrates from deletePrefixRenameKey).
    static let customPrefixQueuePageKey = "customPrefixQueuePageEnabled"
    /// Show custom prefix button in player/video page. Default: false (migrates from videoPageDButtonKey).
    static let customPrefixVideoPageKey = "customPrefixVideoPageEnabled"
    /// Stored secondary custom prefix string for one-click rename. Default: "".
    static let customPrefixSecondaryValueKey = "customPrefixValue2"
    /// Show in-app debug console. Default: false.
    static let debugConsoleKey          = "debugConsoleEnabled"
    /// Verbose per-tick watchdog trace in Xcode console. Debug builds only. Default: false.
    static let verboseAutoplayTraceKey  = "verboseAutoplayTrace"
    /// Shared quiet-rail chrome idle threshold. Default: 3.0 seconds.
    static let chromeAutohideThresholdKey = "chromeAutohideThreshold"
    /// Reduce quiet-rail chrome animation. Default mirrors the system reduce-motion setting at launch.
    static let chromeReducedMotionKey   = "chromeReducedMotion"
    /// Open the Queue Page when a player window launches. Default: false.
    static let queuePanelOpenAtLaunchKey = "queuePanelOpenAtLaunch"
    /// Feature gate for the unified bottom rail. Default: true as of P33.
    static let useUnifiedBottomRailKey  = "useUnifiedBottomRail"
    /// Playback-bar button visibility toggles. All default ON to preserve the
    /// current unified-rail look; the user can hide individual buttons from
    /// Settings → Controls → Playback bar buttons.
    static let bottomRailShowXKey         = "bottomRailShowXButton"
    static let bottomRailShowShuffleKey   = "bottomRailShowShuffleButton"
    static let bottomRailShowReplayKey    = "bottomRailShowReplayButton"
    static let bottomRailShowVolumeKey    = "bottomRailShowVolumeButton"
    static let bottomRailShowBookmarkKey  = "bottomRailShowBookmarkButton"
    /// Default opacity for newly created player windows. Current windows keep local state.
    static let playerWindowOpacityKey   = "playerWindowOpacity"
    static let playerWindowOpacityMin: CGFloat = 0.35
    static let playerWindowOpacityMax: CGFloat = 1.0
    static let defaultPlayerWindowOpacityValue: CGFloat = 1.0

    // MARK: - Static helpers

    static func clampedPlayerWindowOpacity(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultPlayerWindowOpacityValue }
        return min(playerWindowOpacityMax, max(playerWindowOpacityMin, value))
    }
    static func defaultPlayerWindowOpacity() -> CGFloat {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: playerWindowOpacityKey) != nil else {
            return defaultPlayerWindowOpacityValue
        }
        let value = CGFloat(defaults.double(forKey: playerWindowOpacityKey))
        let clamped = clampedPlayerWindowOpacity(value)
        if clamped != value {
            defaults.set(Double(clamped), forKey: playerWindowOpacityKey)
        }
        return clamped
    }
    static func setDefaultPlayerWindowOpacity(_ opacity: CGFloat) {
        UserDefaults.standard.set(Double(clampedPlayerWindowOpacity(opacity)), forKey: playerWindowOpacityKey)
    }
    static func playerWindowOpacityPercent(_ opacity: CGFloat) -> Int {
        Int((clampedPlayerWindowOpacity(opacity) * 100.0).rounded())
    }
    static func isVerboseAutoplayTraceEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: verboseAutoplayTraceKey)
    }
    static func isAutoHideTitlebarEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: autoHideTitlebarKey)
    }
    static func isCompleteVideoWindowModeEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: completeVideoWindowModeKey)
    }
    static func isShowTitleOverlayEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: showTitleOverlayKey)
    }
    static func isDeletePrefixRenameEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: deletePrefixRenameKey)
    }
    static func isVideoPageDButtonEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: videoPageDButtonKey)
    }
    static func customPrefixValue() -> String {
        UserDefaults.standard.string(forKey: customPrefixValueKey) ?? ""
    }
    static func customPrefixSecondaryValue() -> String {
        UserDefaults.standard.string(forKey: customPrefixSecondaryValueKey) ?? ""
    }
    /// Reads new key; migrates from old deletePrefixRenameKey if new key has never been written.
    static func isCustomPrefixQueuePageEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: customPrefixQueuePageKey) != nil {
            return defaults.bool(forKey: customPrefixQueuePageKey)
        }
        return defaults.bool(forKey: deletePrefixRenameKey)
    }
    /// Reads new key; migrates from old videoPageDButtonKey if new key has never been written.
    static func isCustomPrefixVideoPageEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: customPrefixVideoPageKey) != nil {
            return defaults.bool(forKey: customPrefixVideoPageKey)
        }
        return defaults.bool(forKey: videoPageDButtonKey)
    }
    static func isDebugConsoleEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: debugConsoleKey)
    }
    static func isBottomRailShowXEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: bottomRailShowXKey)
    }
    static func isBottomRailShowShuffleEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: bottomRailShowShuffleKey)
    }
    static func isBottomRailShowReplayEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: bottomRailShowReplayKey)
    }
    static func isBottomRailShowVolumeEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: bottomRailShowVolumeKey)
    }
    static func isBottomRailShowBookmarkEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: bottomRailShowBookmarkKey)
    }
    static func acceptsVideoMedia() -> Bool {
        UserDefaults.standard.bool(forKey: acceptVideoKey)
    }
    static func acceptsImageMedia() -> Bool {
        UserDefaults.standard.bool(forKey: acceptImagesKey)
    }
    static func acceptsGIFMedia() -> Bool {
        UserDefaults.standard.bool(forKey: acceptGIFKey)
    }
    static func acceptedMediaKinds() -> Set<MediaFileSupport.MediaKind> {
        var kinds = Set<MediaFileSupport.MediaKind>()
        if acceptsVideoMedia() { kinds.insert(.video) }
        if acceptsImageMedia() { kinds.insert(.image) }
        if acceptsGIFMedia() { kinds.insert(.gif) }
        return kinds
    }

    struct SkipDurationOption  { let seconds: Int;    let title: String }
    struct ImageDurationOption { let seconds: Int;    let title: String }
    struct GIFLoopCountOption  { let loops:   Int;    let title: String }

    static let skipDurationOptions: [SkipDurationOption] = [
        .init(seconds: 10,  title: "10 seconds"),
        .init(seconds: 30,  title: "30 seconds"),
        .init(seconds: 60,  title: "60 seconds"),
        .init(seconds: 180, title: "3 minutes"),
    ]
    static let imageDurationOptions: [ImageDurationOption] = [
        .init(seconds: 1,  title: "1 second"),
        .init(seconds: 2,  title: "2 seconds"),
        .init(seconds: 3,  title: "3 seconds"),
        .init(seconds: 5,  title: "5 seconds"),
        .init(seconds: 10, title: "10 seconds"),
    ]
    static let gifLoopCountOptions: [GIFLoopCountOption] = [
        .init(loops: 1,  title: "1 loop"),
        .init(loops: 3,  title: "3 loops"),
        .init(loops: 5,  title: "5 loops"),
        .init(loops: 10, title: "10 loops"),
    ]
    static let chromeThresholdOptions: [(seconds: Double, title: String)] = [
        (1.0, "1 second"),
        (1.5, "1.5 seconds"),
        (2.0, "2 seconds"),
        (3.0, "3 seconds"),
        (5.0, "5 seconds"),
        (8.0, "8 seconds"),
    ]

    static func chromeThresholdTag(for seconds: Double) -> Int {
        Int((seconds * 10).rounded())
    }

    static func validatedImageDurationSeconds(_ value: Int) -> Int {
        imageDurationOptions.contains(where: { $0.seconds == value }) ? value : defaultImageDurationSeconds
    }
    static func currentImageDurationSeconds() -> Int {
        let stored = UserDefaults.standard.integer(forKey: imageDurationKey)
        let v = validatedImageDurationSeconds(stored)
        if v != stored { UserDefaults.standard.set(v, forKey: imageDurationKey) }
        return v
    }
    static func validatedGIFLoopCount(_ value: Int) -> Int {
        gifLoopCountOptions.contains(where: { $0.loops == value }) ? value : defaultGIFLoopCount
    }
    static func currentGIFLoopCount() -> Int {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: gifLoopCountKey)
            .map { _ in defaults.integer(forKey: gifLoopCountKey) }
            ?? defaultGIFLoopCount
        let v = validatedGIFLoopCount(stored)
        if v != stored { defaults.set(v, forKey: gifLoopCountKey) }
        return v
    }
    static func registerDefaults() {
        var d: [String: Any] = [
            autoHideKey:                false,
            skipDurationKey:            defaultSkipDurationSeconds,
            imageDurationKey:           defaultImageDurationSeconds,
            gifLoopCountKey:            defaultGIFLoopCount,
            acceptVideoKey:             true,
            acceptImagesKey:            true,
            acceptGIFKey:               true,
            autoHideTitlebarKey:        false,
            completeVideoWindowModeKey: false,
            showTitleOverlayKey:        true,
            deletePrefixRenameKey:      false,
            videoPageDButtonKey:        false,
            customPrefixValueKey:          "",
            customPrefixSecondaryValueKey: "",
            debugConsoleKey:            false,
            verboseAutoplayTraceKey:    false,
            chromeAutohideThresholdKey: 3.0,
            chromeReducedMotionKey:     NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            queuePanelOpenAtLaunchKey:  false,
            useUnifiedBottomRailKey:    true,
            bottomRailShowXKey:         true,
            bottomRailShowShuffleKey:   true,
            bottomRailShowReplayKey:    true,
            bottomRailShowVolumeKey:    true,
            bottomRailShowBookmarkKey:  true,
            playerWindowOpacityKey:      Double(defaultPlayerWindowOpacityValue),
        ]
        for c in OptionalTransportControl.allCases { d[c.defaultsKey] = false }
        d[QueuePageView.durationColumnVisibleKey] = true
        d[QueuePageView.sizeColumnVisibleKey]     = true
        // Width keys remain registered for backward compatibility with prior
        // P43.2/P43.3 builds. As of P43.4 the active Queue Page layout uses fixed
        // adaptive widths and does not read these values.
        d[QueuePageView.durationColumnWidthKey]   = 92.0
        d[QueuePageView.sizeColumnWidthKey]       = 104.0
        UserDefaults.standard.register(defaults: d)
    }
    static func validatedSkipDurationSeconds(_ value: Int) -> Int {
        skipDurationOptions.contains(where: { $0.seconds == value }) ? value : defaultSkipDurationSeconds
    }
    static func currentSkipDurationSeconds() -> Int {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: skipDurationKey)
            .map { _ in defaults.integer(forKey: skipDurationKey) }
            ?? defaultSkipDurationSeconds
        let v = validatedSkipDurationSeconds(stored)
        if v != stored { defaults.set(v, forKey: skipDurationKey) }
        return v
    }
    static func setSkipDuration(_ seconds: Int) {
        let v = validatedSkipDurationSeconds(seconds)
        UserDefaults.standard.set(v, forKey: skipDurationKey)
        NotificationCenter.default.post(name: .skipDurationChanged, object: nil)
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

    // MARK: - UI controls

    // Playback section
    private let skipDurationPopup           = NSPopUpButton()
    private let playbackSpeedPopup          = NSPopUpButton()
    private let showTitleOverlayCheckbox    = NSButton()
    private let imageDurationPopup          = NSPopUpButton()
    private let gifLoopCountPopup           = NSPopUpButton()
    private let acceptVideoCheckbox         = NSButton()
    private let acceptImagesCheckbox        = NSButton()
    private let acceptGIFCheckbox           = NSButton()

    // Controls section
    private let autoHideCheckbox             = NSButton()
    private var optionalControlCheckboxes:   [OptionalTransportControl: NSButton] = [:]
    private let bottomRailShowXCheckbox        = NSButton()
    private let bottomRailShowShuffleCheckbox  = NSButton()
    private let bottomRailShowReplayCheckbox   = NSButton()
    private let bottomRailShowVolumeCheckbox   = NSButton()
    private let bottomRailShowBookmarkCheckbox = NSButton()
    private let useUnifiedBottomRailCheckbox = NSButton()
    private let chromeAutohideThresholdPopup = NSPopUpButton()
    private let chromeReducedMotionCheckbox  = NSButton()
    private let autoHideTitlebarCheckbox     = NSButton()
    private let completeVideoWindowModeCheckbox = NSButton()
    private let windowOpacitySlider       = NSSlider()
    private let windowOpacityPercentLabel = NSTextField(labelWithString: "100%")
    private let windowOpacityResetButton  = NSButton()

    // Queue & Files section
    private let customPrefixQueuePageCheckbox          = NSButton()
    private let customPrefixValueTextField             = NSTextField()
    private let customPrefixSecondaryValueTextField    = NSTextField()
    private let customPrefixVideoPageCheckbox          = NSButton()
    private let queuePanelOpenAtLaunchCheckbox = NSButton()

    // Developer section
    private let debugConsoleCheckbox          = NSButton()
    private let verboseAutoplayTraceCheckbox  = NSButton()

    // MARK: - Sidebar / detail state

    private var sidebarButtons: [SettingsSidebarItemButton] = []
    private let detailContainer = NSView()
    private var sectionViews:   [NSView] = []
    private let sectionNames    = ["Playback", "Controls", "Queue & Files", "Developer"]

    // MARK: - Init

    private init() {
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Settings"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 600, height: 420)
        // Suite dark-theme consistency: pin the settings window to dark Aqua so its
        // chrome and controls match dwb skim's settings window on any system theme.
        win.appearance = NSAppearance(named: .darkAqua)
        super.init(window: win)
        buildUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: win
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackSpeedDidChange(_:)),
            name: .playbackSpeedChanged,
            object: nil
        )
        // Keep Settings above player windows while the app is active, but do not use
        // a global floating level that would place it above other applications' windows.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(anyWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI construction

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        // Sidebar: suite-shared settings navigation — visual-effect sidebar with
        // rounded accent-selected items (same metrics as dwb skim: 160pt sidebar,
        // 136×32 items, 12pt insets).
        let sidebarEffect = NSVisualEffectView()
        sidebarEffect.material = .sidebar
        sidebarEffect.blendingMode = .behindWindow
        sidebarEffect.state = .active
        sidebarEffect.translatesAutoresizingMaskIntoConstraints = false

        let sidebarStack = NSStackView()
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .centerX
        sidebarStack.spacing = 4
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarEffect.addSubview(sidebarStack)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 16).isActive = true
        sidebarStack.addArrangedSubview(spacer)

        for (index, name) in sectionNames.enumerated() {
            let btn = SettingsSidebarItemButton(title: name,
                                                sectionIndex: index,
                                                target: self,
                                                action: #selector(sidebarButtonClicked(_:)))
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: 136).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
            sidebarStack.addArrangedSubview(btn)
            sidebarButtons.append(btn)
        }

        // Vertical separator
        let sepLine = SettingsSeparatorLine()
        sepLine.translatesAutoresizingMaskIntoConstraints = false

        // Detail container
        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        cv.addSubview(sidebarEffect)
        cv.addSubview(sepLine)
        cv.addSubview(detailContainer)

        NSLayoutConstraint.activate([
            sidebarEffect.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            sidebarEffect.topAnchor.constraint(equalTo: cv.topAnchor),
            sidebarEffect.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            sidebarEffect.widthAnchor.constraint(equalToConstant: 160),

            sidebarStack.leadingAnchor.constraint(equalTo: sidebarEffect.leadingAnchor, constant: 12),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebarEffect.trailingAnchor, constant: -12),
            sidebarStack.topAnchor.constraint(equalTo: sidebarEffect.topAnchor, constant: 12),

            sepLine.leadingAnchor.constraint(equalTo: sidebarEffect.trailingAnchor),
            sepLine.topAnchor.constraint(equalTo: cv.topAnchor),
            sepLine.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            sepLine.widthAnchor.constraint(equalToConstant: 1),

            detailContainer.leadingAnchor.constraint(equalTo: sepLine.trailingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            detailContainer.topAnchor.constraint(equalTo: cv.topAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])

        // Build section views; add all to container, show only the selected one
        sectionViews = [
            buildPlaybackSection(),
            buildControlsSection(),
            buildQueueFilesSection(),
            buildDeveloperSection(),
        ]
        for (i, sv) in sectionViews.enumerated() {
            sv.translatesAutoresizingMaskIntoConstraints = false
            detailContainer.addSubview(sv)
            NSLayoutConstraint.activate([
                sv.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
                sv.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
                sv.topAnchor.constraint(equalTo: detailContainer.topAnchor),
                sv.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
            ])
            sv.isHidden = (i != 0)
        }

        selectSection(0)
        syncUIFromDefaults()
    }

    // MARK: - Sidebar selection

    private func selectSection(_ index: Int) {
        guard index >= 0, index < sectionViews.count else { return }
        for (i, sv) in sectionViews.enumerated() {
            sv.isHidden = (i != index)
        }
        for btn in sidebarButtons {
            btn.isSelected = (btn.sectionIndex == index)
        }
    }

    @objc private func sidebarButtonClicked(_ sender: SettingsSidebarItemButton) {
        selectSection(sender.sectionIndex)
    }

    // MARK: - Section: Playback

    private func buildPlaybackSection() -> NSView {
        configure(showTitleOverlayCheckbox, title: "Show title overlay on playback start", state: Self.isShowTitleOverlayEnabled())
        
        skipDurationPopup.target = self
        skipDurationPopup.action = #selector(skipDurationPopupChanged(_:))
        for opt in Self.skipDurationOptions {
            skipDurationPopup.addItem(withTitle: opt.title)
            skipDurationPopup.lastItem?.tag = opt.seconds
        }
        skipDurationPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        
        playbackSpeedPopup.target = self
        playbackSpeedPopup.action = #selector(playbackSpeedPopupChanged(_:))
        for opt in PlaybackSpeedOption.all {
            playbackSpeedPopup.addItem(withTitle: opt.title)
            playbackSpeedPopup.lastItem?.tag = opt.tag
        }
        playbackSpeedPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        
        imageDurationPopup.target = self
        imageDurationPopup.action = #selector(imageDurationPopupChanged(_:))
        for opt in Self.imageDurationOptions {
            imageDurationPopup.addItem(withTitle: opt.title)
            imageDurationPopup.lastItem?.tag = opt.seconds
        }
        imageDurationPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        
        gifLoopCountPopup.target = self
        gifLoopCountPopup.action = #selector(gifLoopCountPopupChanged(_:))
        for opt in Self.gifLoopCountOptions {
            gifLoopCountPopup.addItem(withTitle: opt.title)
            gifLoopCountPopup.lastItem?.tag = opt.loops
        }
        gifLoopCountPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let section1 = buildSection(title: "Playback behavior", rows: [
            buildRow(label: "Skip duration", control: skipDurationPopup),
            buildRow(label: "Playback speed", control: playbackSpeedPopup, helperText: "Applies to the frontmost player window."),
            buildRow(label: nil, control: showTitleOverlayCheckbox)
        ])

        let section2 = buildSection(title: "Images & animated GIFs", rows: [
            buildRow(label: "Image slideshow duration", control: imageDurationPopup),
            buildRow(label: "GIF loop count before advancing", control: gifLoopCountPopup)
        ])

        configure(acceptVideoCheckbox, title: "Video", state: Self.acceptsVideoMedia())
        configure(acceptImagesCheckbox, title: "Images", state: Self.acceptsImageMedia())
        configure(acceptGIFCheckbox, title: "GIF", state: Self.acceptsGIFMedia())

        let section3 = buildSection(title: "Accept", rows: [
            buildRow(label: nil, control: acceptVideoCheckbox),
            buildRow(label: nil, control: acceptImagesCheckbox),
            buildRow(label: nil, control: acceptGIFCheckbox)
        ])

        return buildSectionContainer(sections: [section1, section2, section3])
    }

    // MARK: - Section: Controls

    private func buildControlsSection() -> NSView {
        configure(autoHideCheckbox, title: "Auto-hide controls bar in windowed mode", state: UserDefaults.standard.bool(forKey: Self.autoHideKey))
        configure(useUnifiedBottomRailCheckbox, title: "Use unified bottom rail", state: UserDefaults.standard.bool(forKey: Self.useUnifiedBottomRailKey))
        configure(chromeReducedMotionCheckbox, title: "Reduce motion", state: UserDefaults.standard.bool(forKey: Self.chromeReducedMotionKey))
        configure(autoHideTitlebarCheckbox, title: "Auto-hide titlebar", state: Self.isAutoHideTitlebarEnabled())
        configure(completeVideoWindowModeCheckbox, title: "Complete video mode (windowed)", state: Self.isCompleteVideoWindowModeEnabled())

        chromeAutohideThresholdPopup.target = self
        chromeAutohideThresholdPopup.action = #selector(chromeThresholdPopupChanged(_:))
        for opt in Self.chromeThresholdOptions {
            chromeAutohideThresholdPopup.addItem(withTitle: opt.title)
            chromeAutohideThresholdPopup.lastItem?.tag = Self.chromeThresholdTag(for: opt.seconds)
        }
        chromeAutohideThresholdPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        windowOpacitySlider.minValue = Double(Self.playerWindowOpacityMin * 100.0)
        windowOpacitySlider.maxValue = Double(Self.playerWindowOpacityMax * 100.0)
        windowOpacitySlider.target = self
        windowOpacitySlider.action = #selector(windowOpacitySliderChanged(_:))
        windowOpacitySlider.widthAnchor.constraint(equalToConstant: 200).isActive = true

        windowOpacityPercentLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        windowOpacityPercentLabel.textColor = .secondaryLabelColor
        windowOpacityPercentLabel.alignment = .right
        windowOpacityPercentLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true

        windowOpacityResetButton.title = "Default"
        windowOpacityResetButton.bezelStyle = .rounded
        windowOpacityResetButton.target = self
        windowOpacityResetButton.action = #selector(resetWindowOpacity(_:))
        
        let opacityStack = NSStackView(views: [windowOpacitySlider, windowOpacityPercentLabel, windowOpacityResetButton])
        opacityStack.orientation = .horizontal
        opacityStack.spacing = 10
        
        for control in OptionalTransportControl.allCases {
            let cb = NSButton()
            configure(cb, title: control.settingsTitle, state: Self.isOptionalTransportControlVisible(control))
            optionalControlCheckboxes[control] = cb
        }

        configure(bottomRailShowXCheckbox,        title: "Show x_ button in playback bar",       state: Self.isBottomRailShowXEnabled())
        configure(bottomRailShowShuffleCheckbox,  title: "Show Shuffle button in playback bar",  state: Self.isBottomRailShowShuffleEnabled())
        configure(bottomRailShowReplayCheckbox,   title: "Show Replay button in playback bar",   state: Self.isBottomRailShowReplayEnabled())
        configure(bottomRailShowVolumeCheckbox,   title: "Show Volume button in playback bar",   state: Self.isBottomRailShowVolumeEnabled())
        configure(bottomRailShowBookmarkCheckbox, title: "Show Bookmark button in playback bar", state: Self.isBottomRailShowBookmarkEnabled())

        let section1 = buildSection(title: "Transport visibility", rows: [
            buildRow(label: nil, control: autoHideCheckbox)
        ])

        let section1b = buildSection(title: "Playback bar buttons", rows: [
            buildRow(label: nil, control: bottomRailShowXCheckbox),
            buildRow(label: nil, control: bottomRailShowShuffleCheckbox),
            buildRow(label: nil, control: bottomRailShowReplayCheckbox),
            buildRow(label: nil, control: bottomRailShowVolumeCheckbox),
            buildRow(label: nil, control: bottomRailShowBookmarkCheckbox),
            buildRow(label: "Rail auto-hide delay", control: chromeAutohideThresholdPopup),
            buildRow(label: nil, control: chromeReducedMotionCheckbox)
        ])

        let section4 = buildSection(title: "Window chrome", rows: [
            buildRow(label: nil, control: autoHideTitlebarCheckbox),
            buildRow(label: nil, control: completeVideoWindowModeCheckbox),
            buildRow(label: "Window opacity", control: opacityStack)
        ])

        return buildSectionContainer(sections: [section1, section1b, section4])
    }

    // MARK: - Section: Queue & Files

    private func buildQueueFilesSection() -> NSView {
        configure(customPrefixQueuePageCheckbox, title: "Enable one-click custom prefix rename", state: Self.isCustomPrefixQueuePageEnabled())
        configure(customPrefixVideoPageCheckbox, title: "Show custom prefix button in player page", state: Self.isCustomPrefixVideoPageEnabled())
        configure(queuePanelOpenAtLaunchCheckbox, title: "Open queue panel when a player window opens", state: UserDefaults.standard.bool(forKey: Self.queuePanelOpenAtLaunchKey))

        customPrefixValueTextField.isEditable = true
        customPrefixValueTextField.isBordered = true
        customPrefixValueTextField.bezelStyle = .roundedBezel
        customPrefixValueTextField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        customPrefixValueTextField.placeholderString = "e.g. x_"
        customPrefixValueTextField.stringValue = Self.customPrefixValue()
        customPrefixValueTextField.delegate = self
        customPrefixValueTextField.toolTip = "Primary prefix applied to filename stem. The Q key and prefix button use this prefix. The \"/\" character is not allowed."
        customPrefixValueTextField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        customPrefixSecondaryValueTextField.isEditable = true
        customPrefixSecondaryValueTextField.isBordered = true
        customPrefixSecondaryValueTextField.bezelStyle = .roundedBezel
        customPrefixSecondaryValueTextField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        customPrefixSecondaryValueTextField.placeholderString = "e.g. fav_"
        customPrefixSecondaryValueTextField.stringValue = Self.customPrefixSecondaryValue()
        customPrefixSecondaryValueTextField.delegate = self
        customPrefixSecondaryValueTextField.toolTip = "Secondary prefix. Available from the rename menu and Option-Q. Leave empty to use one prefix only. The \"/\" character is not allowed."
        customPrefixSecondaryValueTextField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let section1 = buildSection(title: "Queue page rename", rows: [
            buildRow(label: nil, control: customPrefixQueuePageCheckbox),
            buildRow(label: "Primary prefix", control: customPrefixValueTextField,
                     helperText: "Q and the prefix button apply this prefix. Format: prefix + filename stem + extension."),
            buildRow(label: "Secondary prefix", control: customPrefixSecondaryValueTextField,
                     helperText: "Available from the rename menu and Option-Q. Leave empty to use one prefix only.")
        ])

        let section2 = buildSection(title: "Player page buttons", rows: [
            buildRow(label: nil, control: customPrefixVideoPageCheckbox)
        ])

        let section3 = buildSection(title: "Queue behavior", rows: [
            buildRow(label: nil, control: queuePanelOpenAtLaunchCheckbox)
        ])

        return buildSectionContainer(sections: [section1, section2, section3])
    }

    // MARK: - Section: Developer

    private func buildDeveloperSection() -> NSView {
        configure(debugConsoleCheckbox, title: "Show debug console", state: Self.isDebugConsoleEnabled())
        configure(verboseAutoplayTraceCheckbox, title: "Verbose autoplay trace (debug builds only)", state: Self.isVerboseAutoplayTraceEnabled())

        let section1 = buildSection(title: "Diagnostics", rows: [
            buildRow(label: nil, control: debugConsoleCheckbox),
            buildRow(label: nil, control: verboseAutoplayTraceCheckbox)
        ])

        return buildSectionContainer(sections: [section1])
    }

    // MARK: - Layout helpers

    private func configure(_ btn: NSButton, title: String, state: Bool) {
        btn.setButtonType(.switch)
        btn.title  = title
        btn.font   = .systemFont(ofSize: NSFont.systemFontSize)
        btn.target = self
        btn.action = #selector(checkboxToggled(_:))
        btn.state  = state ? .on : .off
        // Suite checkbox parity: neutral label-colored check chrome instead of the
        // system accent, matching dwb skim's settings checkboxes (native NSButton
        // switch semantics, focus, and accessibility are unchanged).
        btn.contentTintColor = .labelColor
        btn.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Suite accent #4C62A8 — matches dwb skim's DwbSkimProductSpec.accent.
    fileprivate static let suiteAccent = NSColor(calibratedRed: 76.0 / 255.0,
                                                 green: 98.0 / 255.0,
                                                 blue: 168.0 / 255.0,
                                                 alpha: 1.0)

    /// Flat settings section: all-caps accent header above the rows, no card chrome.
    /// Matches the dwb skim GeneralSettingsView section-header direction.
    private func buildSection(title: String, rows: [NSView]) -> NSView {
        let header = NSTextField(labelWithString: title.uppercased())
        header.font = .systemFont(ofSize: 10, weight: .bold)
        header.textColor = Self.suiteAccent.withAlphaComponent(0.8)
        header.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: header)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func buildRow(label: String?, control: NSView, helperText: String? = nil) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        
        let hStack = NSStackView()
        hStack.orientation = .horizontal
        hStack.alignment = .firstBaseline
        hStack.spacing = 16
        
        if let labelText = label {
            let lbl = NSTextField(labelWithString: labelText)
            lbl.font = .systemFont(ofSize: NSFont.systemFontSize)
            lbl.textColor = .labelColor
            lbl.isEditable = false
            lbl.isSelectable = false
            lbl.isBordered = false
            lbl.drawsBackground = false
            lbl.alignment = .left
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.widthAnchor.constraint(equalToConstant: 220).isActive = true
            hStack.addArrangedSubview(lbl)
        }
        
        hStack.addArrangedSubview(control)
        stack.addArrangedSubview(hStack)
        
        if let helper = helperText {
            let note = NSTextField(labelWithString: helper)
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            note.isEditable = false
            note.isSelectable = false
            note.isBordered = false
            note.drawsBackground = false
            note.lineBreakMode = .byWordWrapping
            note.preferredMaxLayoutWidth = 340
            note.translatesAutoresizingMaskIntoConstraints = false
            
            if label != nil {
                let pad = NSView()
                pad.translatesAutoresizingMaskIntoConstraints = false
                pad.widthAnchor.constraint(equalToConstant: 220 + 16).isActive = true
                let nStack = NSStackView(views: [pad, note])
                nStack.spacing = 0
                stack.addArrangedSubview(nStack)
            } else {
                let pad = NSView()
                pad.translatesAutoresizingMaskIntoConstraints = false
                pad.widthAnchor.constraint(equalToConstant: 18).isActive = true
                let nStack = NSStackView(views: [pad, note])
                nStack.spacing = 0
                stack.addArrangedSubview(nStack)
            }
        }
        
        return stack
    }

    private func buildSectionContainer(sections: [NSView]) -> NSView {
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = SettingsFlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        // Shared suite rhythm: 16pt vertical / 24pt horizontal content margins.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -16)
        ])
        
        scrollView.documentView = documentView
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        
        return container
    }

    // MARK: - Actions

    @objc private func checkboxToggled(_ sender: NSButton) {
        let enabled = sender.state == .on

        if sender === autoHideCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.autoHideKey)
            NotificationCenter.default.post(name: .autoHideSettingChanged, object: nil)
            DebugConsoleController.log("settings", "autoHideTransport=\(enabled)")
            return
        }
        if sender === autoHideTitlebarCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.autoHideTitlebarKey)
            NotificationCenter.default.post(name: .autoHideTitlebarChanged, object: nil)
            DebugConsoleController.log("settings", "autoHideTitlebar=\(enabled)")
            return
        }
        if sender === completeVideoWindowModeCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.completeVideoWindowModeKey)
            NotificationCenter.default.post(name: .completeVideoWindowModeChanged, object: nil)
            DebugConsoleController.log("settings", "completeVideoWindowMode=\(enabled)")
            return
        }
        if sender === customPrefixQueuePageCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.customPrefixQueuePageKey)
            NotificationCenter.default.post(name: .customPrefixRenameChanged, object: nil)
            DebugConsoleController.log("settings", "customPrefixQueuePage=\(enabled)")
            return
        }
        if sender === customPrefixVideoPageCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.customPrefixVideoPageKey)
            NotificationCenter.default.post(name: .videoPageCustomPrefixButtonSettingChanged, object: nil)
            DebugConsoleController.log("settings", "customPrefixVideoPage=\(enabled)")
            return
        }
        if sender === showTitleOverlayCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.showTitleOverlayKey)
            NotificationCenter.default.post(name: .titleOverlaySettingChanged, object: nil)
            DebugConsoleController.log("settings", "showTitleOverlay=\(enabled)")
            return
        }
        if sender === acceptVideoCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.acceptVideoKey)
            NotificationCenter.default.post(name: .acceptedMediaTypesChanged, object: nil)
            DebugConsoleController.log("settings", "acceptVideo=\(enabled)")
            return
        }
        if sender === acceptImagesCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.acceptImagesKey)
            NotificationCenter.default.post(name: .acceptedMediaTypesChanged, object: nil)
            DebugConsoleController.log("settings", "acceptImages=\(enabled)")
            return
        }
        if sender === acceptGIFCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.acceptGIFKey)
            NotificationCenter.default.post(name: .acceptedMediaTypesChanged, object: nil)
            DebugConsoleController.log("settings", "acceptGIF=\(enabled)")
            return
        }
        if sender === debugConsoleCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.debugConsoleKey)
            NotificationCenter.default.post(name: .debugConsoleSettingChanged, object: nil)
            return
        }
        if sender === verboseAutoplayTraceCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.verboseAutoplayTraceKey)
            return
        }
        if sender === useUnifiedBottomRailCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.useUnifiedBottomRailKey)
            NotificationCenter.default.post(name: .transportVisibilityChanged, object: nil)
            DebugConsoleController.log("settings", "useUnifiedBottomRail=\(enabled)")
            return
        }
        if sender === chromeReducedMotionCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.chromeReducedMotionKey)
            NotificationCenter.default.post(name: .transportVisibilityChanged, object: nil)
            DebugConsoleController.log("settings", "chromeReducedMotion=\(enabled)")
            return
        }
        if sender === queuePanelOpenAtLaunchCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.queuePanelOpenAtLaunchKey)
            DebugConsoleController.log("settings", "queuePanelOpenAtLaunch=\(enabled)")
            return
        }
        let bottomRailKey: String?
        switch sender {
        case bottomRailShowXCheckbox:        bottomRailKey = Self.bottomRailShowXKey
        case bottomRailShowShuffleCheckbox:  bottomRailKey = Self.bottomRailShowShuffleKey
        case bottomRailShowReplayCheckbox:   bottomRailKey = Self.bottomRailShowReplayKey
        case bottomRailShowVolumeCheckbox:   bottomRailKey = Self.bottomRailShowVolumeKey
        case bottomRailShowBookmarkCheckbox: bottomRailKey = Self.bottomRailShowBookmarkKey
        default: bottomRailKey = nil
        }
        if let key = bottomRailKey {
            UserDefaults.standard.set(enabled, forKey: key)
            NotificationCenter.default.post(name: .bottomRailButtonVisibilityChanged, object: nil)
            DebugConsoleController.log("settings", "\(key)=\(enabled)")
            return
        }
        guard let control = optionalControlCheckboxes.first(where: { $0.value === sender })?.key else { return }
        UserDefaults.standard.set(enabled, forKey: control.defaultsKey)
        NotificationCenter.default.post(name: .transportVisibilityChanged, object: nil)
        DebugConsoleController.log("settings", "optionalControl.\(control.defaultsKey)=\(enabled)")
    }

    @objc private func skipDurationPopupChanged(_ sender: NSPopUpButton) {
        let selected = Self.validatedSkipDurationSeconds(sender.selectedTag())
        UserDefaults.standard.set(selected, forKey: Self.skipDurationKey)
        NotificationCenter.default.post(name: .skipDurationChanged, object: nil)
        DebugConsoleController.log("settings", "skipDuration=\(selected)s")
        syncUIFromDefaults()
    }

    @objc private func imageDurationPopupChanged(_ sender: NSPopUpButton) {
        let selected = Self.validatedImageDurationSeconds(sender.selectedTag())
        UserDefaults.standard.set(selected, forKey: Self.imageDurationKey)
        NotificationCenter.default.post(name: .imageDurationChanged, object: nil)
        DebugConsoleController.log("settings", "imageDuration=\(selected)s")
        syncUIFromDefaults()
    }

    @objc private func gifLoopCountPopupChanged(_ sender: NSPopUpButton) {
        let selected = Self.validatedGIFLoopCount(sender.selectedTag())
        UserDefaults.standard.set(selected, forKey: Self.gifLoopCountKey)
        NotificationCenter.default.post(name: .gifLoopCountChanged, object: nil)
        DebugConsoleController.log("settings", "gifLoopCount=\(selected)")
        syncUIFromDefaults()
    }

    @objc private func playbackSpeedPopupChanged(_ sender: NSPopUpButton) {
        guard let option = PlaybackSpeedOption.option(forTag: sender.selectedTag()) else { return }
        targetPlayerWindowController()?.setPlaybackSpeed(option.rate, source: "settings")
        syncPlaybackSpeedControlsFromTarget()
    }

    @objc private func chromeThresholdPopupChanged(_ sender: NSPopUpButton) {
        let seconds = Double(sender.selectedTag()) / 10.0
        UserDefaults.standard.set(seconds, forKey: Self.chromeAutohideThresholdKey)
        NotificationCenter.default.post(name: .transportVisibilityChanged, object: nil)
        DebugConsoleController.log("settings", "chromeAutohideThreshold=\(seconds)s")
        syncUIFromDefaults()
    }

    @objc private func windowOpacitySliderChanged(_ sender: NSSlider) {
        let opacity = Self.clampedPlayerWindowOpacity(CGFloat(sender.doubleValue / 100.0))
        Self.setDefaultPlayerWindowOpacity(opacity)
        updateWindowOpacityControls(opacity)
        targetPlayerWindowController()?.setWindowOpacityFromSettings(opacity)
        DebugConsoleController.log("settings", "playerWindowOpacity=\(Self.playerWindowOpacityPercent(opacity))%")
    }

    @objc private func resetWindowOpacity(_ sender: NSButton) {
        let opacity = Self.defaultPlayerWindowOpacityValue
        Self.setDefaultPlayerWindowOpacity(opacity)
        updateWindowOpacityControls(opacity)
        targetPlayerWindowController()?.setWindowOpacityFromSettings(opacity)
        DebugConsoleController.log("settings", "playerWindowOpacity=100%")
    }

    @objc private func settingsWindowDidBecomeKey(_ notification: Notification) {
        syncWindowOpacityControlsFromTargetOrDefault()
        syncPlaybackSpeedControlsFromTarget()
    }

    @objc private func playbackSpeedDidChange(_ notification: Notification) {
        guard window?.isVisible == true else { return }
        syncPlaybackSpeedControlsFromTarget()
    }

    @objc private func anyWindowDidBecomeKey(_ notification: Notification) {
        guard let becameKeyWin = notification.object as? NSWindow,
              becameKeyWin !== window,
              window?.isVisible == true,
              becameKeyWin.windowController is PlayerWindowController else { return }
        window?.order(.above, relativeTo: becameKeyWin.windowNumber)
    }

    @objc private func appDidBecomeActive(_ notification: Notification) {
        orderAbovePlayerWindows()
    }

    private func orderAbovePlayerWindows() {
        guard let settingsWin = window, settingsWin.isVisible else { return }
        guard let frontmostPlayerWin = NSApp.orderedWindows.first(where: {
            $0 !== settingsWin && ($0.windowController is PlayerWindowController)
        }) else { return }
        settingsWin.order(.above, relativeTo: frontmostPlayerWin.windowNumber)
    }

    // MARK: - Sync

    private func syncUIFromDefaults() {
        autoHideCheckbox.state = UserDefaults.standard.bool(forKey: Self.autoHideKey) ? .on : .off
        for (control, cb) in optionalControlCheckboxes {
            cb.state = Self.isOptionalTransportControlVisible(control) ? .on : .off
        }
        customPrefixQueuePageCheckbox.state             = Self.isCustomPrefixQueuePageEnabled()    ? .on : .off
        customPrefixVideoPageCheckbox.state             = Self.isCustomPrefixVideoPageEnabled()    ? .on : .off
        customPrefixValueTextField.stringValue          = Self.customPrefixValue()
        customPrefixSecondaryValueTextField.stringValue = Self.customPrefixSecondaryValue()
        autoHideTitlebarCheckbox.state         = Self.isAutoHideTitlebarEnabled()      ? .on : .off
        completeVideoWindowModeCheckbox.state  = Self.isCompleteVideoWindowModeEnabled() ? .on : .off
        showTitleOverlayCheckbox.state         = Self.isShowTitleOverlayEnabled()      ? .on : .off
        acceptVideoCheckbox.state              = Self.acceptsVideoMedia()             ? .on : .off
        acceptImagesCheckbox.state             = Self.acceptsImageMedia()             ? .on : .off
        acceptGIFCheckbox.state                = Self.acceptsGIFMedia()               ? .on : .off
        debugConsoleCheckbox.state             = Self.isDebugConsoleEnabled()          ? .on : .off
        verboseAutoplayTraceCheckbox.state     = Self.isVerboseAutoplayTraceEnabled()  ? .on : .off
        useUnifiedBottomRailCheckbox.state     = UserDefaults.standard.bool(forKey: Self.useUnifiedBottomRailKey)    ? .on : .off
        chromeReducedMotionCheckbox.state      = UserDefaults.standard.bool(forKey: Self.chromeReducedMotionKey)     ? .on : .off
        queuePanelOpenAtLaunchCheckbox.state   = UserDefaults.standard.bool(forKey: Self.queuePanelOpenAtLaunchKey) ? .on : .off
        bottomRailShowXCheckbox.state          = Self.isBottomRailShowXEnabled()        ? .on : .off
        bottomRailShowShuffleCheckbox.state    = Self.isBottomRailShowShuffleEnabled()  ? .on : .off
        bottomRailShowReplayCheckbox.state     = Self.isBottomRailShowReplayEnabled()   ? .on : .off
        bottomRailShowVolumeCheckbox.state     = Self.isBottomRailShowVolumeEnabled()   ? .on : .off
        bottomRailShowBookmarkCheckbox.state   = Self.isBottomRailShowBookmarkEnabled() ? .on : .off

        skipDurationPopup.selectItem(withTag: Self.currentSkipDurationSeconds())
        syncPlaybackSpeedControlsFromTarget()
        imageDurationPopup.selectItem(withTag: Self.currentImageDurationSeconds())
        gifLoopCountPopup.selectItem(withTag: Self.currentGIFLoopCount())

        let rawThreshold = UserDefaults.standard.double(forKey: Self.chromeAutohideThresholdKey)
        let threshold    = rawThreshold > 0 ? rawThreshold : 3.0
        let tag          = Self.chromeThresholdTag(for: threshold)
        chromeAutohideThresholdPopup.selectItem(withTag: tag)
        if chromeAutohideThresholdPopup.selectedItem == nil {
            chromeAutohideThresholdPopup.selectItem(withTag: Self.chromeThresholdTag(for: 3.0))
        }
        syncWindowOpacityControlsFromTargetOrDefault()
    }

    private func syncWindowOpacityControlsFromTargetOrDefault() {
        let opacity = targetPlayerWindowController()?.currentWindowOpacity
            ?? Self.defaultPlayerWindowOpacity()
        updateWindowOpacityControls(opacity)
    }

    private func syncPlaybackSpeedControlsFromTarget() {
        let rate = targetPlayerWindowController()?.currentPlaybackSpeed
            ?? PlaybackSpeedOption.normalRate
        let option = PlaybackSpeedOption.validated(rate)
        playbackSpeedPopup.selectItem(withTag: option.tag)
    }

    private func updateWindowOpacityControls(_ opacity: CGFloat) {
        let clamped = Self.clampedPlayerWindowOpacity(opacity)
        windowOpacitySlider.doubleValue = Double(clamped * 100.0)
        windowOpacityPercentLabel.stringValue = "\(Self.playerWindowOpacityPercent(clamped))%"
    }

    private func targetPlayerWindowController() -> PlayerWindowController? {
        for window in NSApp.orderedWindows {
            if window === self.window { continue }
            guard window.isVisible,
                  let wc = window.windowController as? PlayerWindowController else { continue }
            return wc
        }
        if let appDelegate = NSApp.delegate as? AppDelegate {
            return appDelegate.windowControllers.last { $0.window?.isVisible == true }
        }
        return nil
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === customPrefixValueTextField {
            let prefix = field.stringValue
            guard !prefix.contains("/"), !prefix.contains("\0") else { return }
            UserDefaults.standard.set(prefix, forKey: Self.customPrefixValueKey)
            NotificationCenter.default.post(name: .customPrefixValueChanged, object: nil)
            DebugConsoleController.log("settings", "customPrefixValue='\(prefix)'")
        } else if field === customPrefixSecondaryValueTextField {
            let prefix = field.stringValue
            guard !prefix.contains("/"), !prefix.contains("\0") else { return }
            UserDefaults.standard.set(prefix, forKey: Self.customPrefixSecondaryValueKey)
            NotificationCenter.default.post(name: .customPrefixValueChanged, object: nil)
            DebugConsoleController.log("settings", "customPrefixSecondaryValue='\(prefix)'")
        }
    }

    // MARK: - Open

    func openSettings() {
        syncUIFromDefaults()
        if !(window?.isVisible ?? false) {
            window?.center()
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        orderAbovePlayerWindows()
    }
}

// MARK: - Suite-shared settings sidebar item
// Same visual pattern as dwb skim's SidebarItemButton: rounded row, suite-accent
// fill + semibold white title when selected, plain 13pt label otherwise.

private final class SettingsSidebarItemButton: NSButton {
    let sectionIndex: Int
    private let itemTitle: String

    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }

    init(title: String, sectionIndex: Int, target: AnyObject?, action: Selector) {
        self.sectionIndex = sectionIndex
        self.itemTitle = title
        super.init(frame: .zero)
        self.target = target
        self.action = action
        setButtonType(.momentaryPushIn)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Up/Down arrows switch panes — preserves the arrow-key navigation the
    /// previous NSTableView sidebar provided.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: activateSibling(offset: -1)  // Up Arrow
        case 125: activateSibling(offset: 1)   // Down Arrow
        default:  super.keyDown(with: event)
        }
    }

    private func activateSibling(offset: Int) {
        guard let stack = superview as? NSStackView else { return }
        let buttons = stack.arrangedSubviews.compactMap { $0 as? SettingsSidebarItemButton }
        guard let index = buttons.firstIndex(where: { $0 === self }),
              buttons.indices.contains(index + offset) else { return }
        let next = buttons[index + offset]
        window?.makeFirstResponder(next)
        next.performClick(nil)
    }

    private func updateAppearance() {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.firstLineHeadIndent = 10
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let textColor: NSColor
        let font: NSFont
        if isSelected {
            layer?.backgroundColor = SettingsWindowController.suiteAccent.cgColor
            textColor = .white
            font = .systemFont(ofSize: 13, weight: .semibold)
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            textColor = NSColor.labelColor.withAlphaComponent(0.85)
            font = .systemFont(ofSize: 13, weight: .regular)
        }

        attributedTitle = NSAttributedString(string: itemTitle, attributes: [
            .paragraphStyle: paragraphStyle,
            .foregroundColor: textColor,
            .font: font,
        ])
    }
}

// MARK: - Appearance-aware vertical separator

private final class SettingsSeparatorLine: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

private final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
