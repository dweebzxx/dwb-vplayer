import Cocoa
import VLCKitSPM

extension Notification.Name {
    static let autoHideSettingChanged         = Notification.Name("dwb.autoHideSettingChanged")
    /// Posted when playback control chrome settings change.
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
/// Sidebar sections: Playback, Controls, Queue & Files, Shortcuts, Advanced, About.
/// Navigation uses the suite-shared settings pattern (matches dwb skim):
/// visual-effect sidebar with rounded, suite-accent-selected items.
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {

    enum OptionalTransportControl: CaseIterable, Hashable {
        case stop, volume, shuffle, repeatOne

        var defaultsKey: String {
            switch self {
            case .stop:
                return SettingsDefaultsRegistry.Keys.OptionalTransportControl.stop.defaultsKey
            case .volume:
                return SettingsDefaultsRegistry.Keys.OptionalTransportControl.volume.defaultsKey
            case .shuffle:
                return SettingsDefaultsRegistry.Keys.OptionalTransportControl.shuffle.defaultsKey
            case .repeatOne:
                return SettingsDefaultsRegistry.Keys.OptionalTransportControl.repeatOne.defaultsKey
            }
        }

    }

    static let shared = SettingsWindowController()

    // MARK: - UserDefaults keys

    /// Non-fullscreen transport auto-hide. Default: false.
    static let autoHideKey              = SettingsDefaultsRegistry.Keys.autoHideTransportWindowed
    /// Retained for old defaults/reset compatibility; the shipped UI uses BottomRailView.
    static let showStopKey              = OptionalTransportControl.stop.defaultsKey
    static let showVolumeKey            = OptionalTransportControl.volume.defaultsKey
    static let showShuffleKey           = OptionalTransportControl.shuffle.defaultsKey
    static let showRepeatKey            = OptionalTransportControl.repeatOne.defaultsKey
    static let persistedVolumeKey       = SettingsDefaultsRegistry.Keys.persistedVolume
    static let skipDurationKey          = SettingsDefaultsRegistry.Keys.skipDurationSeconds
    static let defaultSkipDurationSeconds = SettingsDefaultsRegistry.Defaults.skipDurationSeconds
    /// Titlebar auto-hide in windowed mode. Default: false.
    static let autoHideTitlebarKey      = SettingsDefaultsRegistry.Keys.autoHideTitlebar
    /// Hide the titlebar chrome in windowed mode so video reaches the top edge. Default: false.
    static let completeVideoWindowModeKey = SettingsDefaultsRegistry.Keys.completeVideoWindowMode
    /// Image slideshow display duration in seconds. Default: 3.
    static let imageDurationKey         = SettingsDefaultsRegistry.Keys.imageDurationSeconds
    static let defaultImageDurationSeconds = SettingsDefaultsRegistry.Defaults.imageDurationSeconds
    /// GIF playback loop count before queue advance. Default: 1.
    static let gifLoopCountKey          = SettingsDefaultsRegistry.Keys.gifLoopCount
    static let defaultGIFLoopCount      = SettingsDefaultsRegistry.Defaults.gifLoopCount
    /// Accepted media types for open/drop intake. Defaults: all true.
    static let acceptVideoKey           = SettingsDefaultsRegistry.Keys.acceptVideoMedia
    static let acceptImagesKey          = SettingsDefaultsRegistry.Keys.acceptImageMedia
    static let acceptGIFKey             = SettingsDefaultsRegistry.Keys.acceptGIFMedia
    /// Show title overlay when video or image playback starts. Default: true.
    static let showTitleOverlayKey      = SettingsDefaultsRegistry.Keys.showTitleOverlay
    /// One-click delete_ prefix rename in Queue Page (legacy key; migrated to customPrefixQueuePageKey).
    static let deletePrefixRenameKey    = SettingsDefaultsRegistry.Keys.deletePrefixRenameEnabled
    /// Show d_ rename button in player/video page (legacy key; migrated to customPrefixVideoPageKey).
    static let videoPageDButtonKey      = SettingsDefaultsRegistry.Keys.videoPageDButtonEnabled
    /// Stored custom prefix string for one-click rename. Trailing spaces preserved. Default: "".
    static let customPrefixValueKey     = SettingsDefaultsRegistry.Keys.customPrefixValue
    /// One-click custom prefix rename in Queue Page. Default: false (migrates from deletePrefixRenameKey).
    static let customPrefixQueuePageKey = SettingsDefaultsRegistry.Keys.customPrefixQueuePageEnabled
    /// Show custom prefix button in player/video page. Default: false (migrates from videoPageDButtonKey).
    static let customPrefixVideoPageKey = SettingsDefaultsRegistry.Keys.customPrefixVideoPageEnabled
    /// Stored secondary custom prefix string for one-click rename. Default: "".
    static let customPrefixSecondaryValueKey = SettingsDefaultsRegistry.Keys.customPrefixSecondaryValue
    /// Show in-app debug console. Default: false.
    static let debugConsoleKey          = SettingsDefaultsRegistry.Keys.debugConsoleEnabled
    /// Verbose per-tick watchdog trace in Xcode console. Debug builds only. Default: false.
    static let verboseAutoplayTraceKey  = SettingsDefaultsRegistry.Keys.verboseAutoplayTrace
    /// Shared quiet-rail chrome idle threshold. Default: 3.0 seconds.
    static let chromeAutohideThresholdKey = SettingsDefaultsRegistry.Keys.chromeAutohideThreshold
    /// Reduce quiet-rail chrome animation. Default mirrors the system reduce-motion setting at launch.
    static let chromeReducedMotionKey   = SettingsDefaultsRegistry.Keys.chromeReducedMotion
    /// Open the Queue Page when a player window launches. Default: false.
    static let queuePanelOpenAtLaunchKey = SettingsDefaultsRegistry.Keys.queuePanelOpenAtLaunch
    /// Playback-bar button visibility toggles. All default ON to preserve the
    /// current unified-rail look; the user can hide individual buttons from
    /// Settings → Controls → Playback bar buttons.
    static let bottomRailShowXKey         = SettingsDefaultsRegistry.Keys.bottomRailShowXButton
    static let bottomRailShowShuffleKey   = SettingsDefaultsRegistry.Keys.bottomRailShowShuffleButton
    static let bottomRailShowReplayKey    = SettingsDefaultsRegistry.Keys.bottomRailShowReplayButton
    static let bottomRailShowVolumeKey    = SettingsDefaultsRegistry.Keys.bottomRailShowVolumeButton
    static let bottomRailShowBookmarkKey  = SettingsDefaultsRegistry.Keys.bottomRailShowBookmarkButton
    /// Default opacity for newly created player windows. Current windows keep local state.
    static let playerWindowOpacityKey   = SettingsDefaultsRegistry.Keys.playerWindowOpacity
    static let playerWindowOpacityMin: CGFloat = CGFloat(SettingsDefaultsRegistry.Defaults.playerWindowOpacityMin)
    static let playerWindowOpacityMax: CGFloat = CGFloat(SettingsDefaultsRegistry.Defaults.playerWindowOpacityMax)
    static let defaultPlayerWindowOpacityValue: CGFloat = CGFloat(SettingsDefaultsRegistry.Defaults.playerWindowOpacity)
    static let githubURLString = "https://github.com/dweebzxx/dwb-player"
    static let githubIssuesURLString = "https://github.com/dweebzxx/dwb-player/issues"

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
    static func vlcBackendVersionText() -> String {
        let version = VLCLibrary.shared().version.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? "Unavailable" : version
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
    private static func settingsDefaultValues() -> [String: Any] {
        SettingsDefaultsRegistry.defaultValues(
            reduceMotionDefault: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
    static func registerDefaults() {
        SettingsDefaultsRegistry.register(
            reduceMotionDefault: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
    static func restoreSettingsDefaults() {
        let defaults = UserDefaults.standard
        for (key, value) in settingsDefaultValues() {
            defaults.set(value, forKey: key)
        }
        NotificationCenter.default.post(name: .autoHideSettingChanged, object: nil)
        NotificationCenter.default.post(name: .transportVisibilityChanged, object: nil)
        NotificationCenter.default.post(name: .skipDurationChanged, object: nil)
        NotificationCenter.default.post(name: .autoHideTitlebarChanged, object: nil)
        NotificationCenter.default.post(name: .completeVideoWindowModeChanged, object: nil)
        NotificationCenter.default.post(name: .imageDurationChanged, object: nil)
        NotificationCenter.default.post(name: .gifLoopCountChanged, object: nil)
        NotificationCenter.default.post(name: .acceptedMediaTypesChanged, object: nil)
        NotificationCenter.default.post(name: .titleOverlaySettingChanged, object: nil)
        NotificationCenter.default.post(name: .customPrefixRenameChanged, object: nil)
        NotificationCenter.default.post(name: .videoPageCustomPrefixButtonSettingChanged, object: nil)
        NotificationCenter.default.post(name: .customPrefixValueChanged, object: nil)
        NotificationCenter.default.post(name: .debugConsoleSettingChanged, object: nil)
        NotificationCenter.default.post(name: .bottomRailButtonVisibilityChanged, object: nil)
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
    private let bottomRailShowXCheckbox        = NSButton()
    private let bottomRailShowShuffleCheckbox  = NSButton()
    private let bottomRailShowReplayCheckbox   = NSButton()
    private let bottomRailShowVolumeCheckbox   = NSButton()
    private let bottomRailShowBookmarkCheckbox = NSButton()
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

    // Advanced section
    private let debugConsoleCheckbox          = NSButton()
    private let verboseAutoplayTraceCheckbox  = NSButton()
    private let restoreDefaultsButton         = NSButton()
    private let clearBookmarksButton          = NSButton()

    // MARK: - Sidebar / detail state

    private var sidebarButtons: [SettingsSidebarItemButton] = []
    private let detailContainer = NSView()
    private var sectionViews:   [NSView] = []
    private let sectionNames    = ["Playback", "Controls", "Queue & Files", "Shortcuts", "Advanced", "About"]

    // MARK: - Init

    private init() {
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Settings"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 560, height: 390)
        win.standardWindowButton(.closeButton)?.isHidden = false
        win.standardWindowButton(.closeButton)?.isEnabled = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = false
        win.standardWindowButton(.miniaturizeButton)?.isEnabled = true
        win.standardWindowButton(.zoomButton)?.isHidden = false
        win.standardWindowButton(.zoomButton)?.isEnabled = false
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
            buildShortcutsSection(),
            buildAdvancedSection(),
            buildAboutSection(),
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
        
        configure(bottomRailShowXCheckbox,        title: "Show x_ button in playback bar",       state: Self.isBottomRailShowXEnabled())
        configure(bottomRailShowShuffleCheckbox,  title: "Show Shuffle button in playback bar",  state: Self.isBottomRailShowShuffleEnabled())
        configure(bottomRailShowReplayCheckbox,   title: "Show Replay button in playback bar",   state: Self.isBottomRailShowReplayEnabled())
        configure(bottomRailShowVolumeCheckbox,   title: "Show Volume button in playback bar",   state: Self.isBottomRailShowVolumeEnabled())
        configure(bottomRailShowBookmarkCheckbox, title: "Show Bookmark button in playback bar", state: Self.isBottomRailShowBookmarkEnabled())

        let section1 = buildSection(title: "Playback bar behavior", rows: [
            buildRow(label: nil, control: autoHideCheckbox),
            buildRow(label: "Rail auto-hide delay", control: chromeAutohideThresholdPopup),
            buildRow(label: nil, control: chromeReducedMotionCheckbox)
        ])

        let section1b = buildSection(title: "Playback bar buttons", rows: [
            buildRow(label: nil, control: bottomRailShowXCheckbox),
            buildRow(label: nil, control: bottomRailShowShuffleCheckbox),
            buildRow(label: nil, control: bottomRailShowReplayCheckbox),
            buildRow(label: nil, control: bottomRailShowVolumeCheckbox),
            buildRow(label: nil, control: bottomRailShowBookmarkCheckbox)
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

    // MARK: - Section: Advanced

    private func buildAdvancedSection() -> NSView {
        configure(debugConsoleCheckbox, title: "Show debug console", state: Self.isDebugConsoleEnabled())
        configure(verboseAutoplayTraceCheckbox, title: "Verbose autoplay trace (debug builds only)", state: Self.isVerboseAutoplayTraceEnabled())
        restoreDefaultsButton.title = "Restore All Settings to Default"
        restoreDefaultsButton.bezelStyle = .rounded
        restoreDefaultsButton.target = self
        restoreDefaultsButton.action = #selector(restoreAllSettingsToDefault(_:))
        restoreDefaultsButton.translatesAutoresizingMaskIntoConstraints = false

        clearBookmarksButton.title = "Clear All Bookmarks…"
        clearBookmarksButton.bezelStyle = .rounded
        clearBookmarksButton.target = self
        clearBookmarksButton.action = #selector(clearAllBookmarks(_:))
        clearBookmarksButton.translatesAutoresizingMaskIntoConstraints = false

        let section1 = buildSection(title: "Diagnostics", rows: [
            buildRow(label: nil, control: debugConsoleCheckbox),
            buildRow(label: nil, control: verboseAutoplayTraceCheckbox)
        ])

        let section2 = buildSection(title: "Bookmarks", rows: [
            buildRow(label: nil, control: clearBookmarksButton,
                     helperText: "Bookmarks are stored locally on this device and may include full file paths of bookmarked media. Clearing is permanent and cannot be undone.")
        ])

        let section3 = buildSection(title: "Reset", rows: [
            buildRow(label: nil, control: restoreDefaultsButton,
                     helperText: "Restores dwb player preferences. Media files, queues, and bookmarks are not deleted.")
        ])

        return buildSectionContainer(sections: [section1, section2, section3])
    }

    // MARK: - Section: About

    private func buildAboutSection() -> NSView {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build   = info?["CFBundleVersion"]            as? String ?? "—"

        func makeLabel(_ text: String, size: CGFloat = NSFont.systemFontSize, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
            let lbl = NSTextField(labelWithString: text)
            lbl.font = .systemFont(ofSize: size, weight: weight)
            lbl.textColor = color
            lbl.isSelectable = false
            lbl.translatesAutoresizingMaskIntoConstraints = false
            return lbl
        }

        let iconView = NSImageView()
        iconView.image = NSImage(named: NSImage.applicationIconName)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 108),
            iconView.heightAnchor.constraint(equalToConstant: 108)
        ])

        let nameLabel     = makeLabel("dwb player", size: 17, weight: .semibold)
        let versionLabel  = makeLabel("Version \(version)  ·  Build \(build)", color: .secondaryLabelColor)
        let descLabel     = makeLabel("Local media playback for macOS", color: .secondaryLabelColor)
        let licenseLabel  = makeLabel("MIT License", color: .tertiaryLabelColor)
        let platformLabel = makeLabel("Requires macOS 13 or later", color: .tertiaryLabelColor)
        let techLabel     = makeLabel("Built with AppKit and VLCKit", color: .tertiaryLabelColor)
        let vlcLabel      = makeLabel("VLC backend: \(Self.vlcBackendVersionText())", color: .tertiaryLabelColor)

        let githubButton = makeAboutLinkButton(title: "GitHub Repository", action: #selector(openGitHubRepository(_:)))
        let issueButton = makeAboutLinkButton(title: "Report an Issue", action: #selector(openGitHubIssues(_:)))

        let textStack = NSStackView(views: [nameLabel, versionLabel, descLabel, licenseLabel, platformLabel, techLabel, vlcLabel, githubButton, issueButton])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 6
        textStack.setCustomSpacing(10, after: nameLabel)
        textStack.setCustomSpacing(4, after: versionLabel)
        textStack.setCustomSpacing(10, after: descLabel)
        textStack.setCustomSpacing(12, after: vlcLabel)
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [iconView, textStack])
        headerStack.orientation = .horizontal
        headerStack.alignment = .top
        headerStack.spacing = 16
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let copyrightLabel = makeLabel("© dwb", color: .tertiaryLabelColor)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerStack)
        container.addSubview(copyrightLabel)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

            copyrightLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            copyrightLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            headerStack.bottomAnchor.constraint(lessThanOrEqualTo: copyrightLabel.topAnchor, constant: -16)
        ])

        return container
    }

    private func makeAboutLinkButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.alignment = .left
        button.contentTintColor = .linkColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ]
        )
        return button
    }

    // MARK: - Section: Shortcuts

    private struct ShortcutItem {
        let title: String
        let shortcut: String
    }

    private struct ShortcutGroup {
        let title: String
        let items: [ShortcutItem]
    }

    private static let shortcutGroups: [ShortcutGroup] = [
        .init(title: "App & Files", items: [
            .init(title: "Open Settings", shortcut: "⌘,"),
            .init(title: "Quit dwb player", shortcut: "⌘Q"),
            .init(title: "Open File", shortcut: "⌘O"),
            .init(title: "Reveal in Finder", shortcut: "⇧⌘R"),
            .init(title: "Clear Queue", shortcut: "⇧⌘⌫"),
            .init(title: "New Window", shortcut: "⌘N")
        ]),
        .init(title: "Playback", items: [
            .init(title: "Play / Pause", shortcut: "Space"),
            .init(title: "Rewind by skip duration", shortcut: "← / ⌥←"),
            .init(title: "Forward by skip duration", shortcut: "→ / ⌥→"),
            .init(title: "Volume Up", shortcut: "↑ / ⌘↑"),
            .init(title: "Volume Down", shortcut: "↓ / ⌘↓"),
            .init(title: "Previous Item", shortcut: "Z"),
            .init(title: "Next Item", shortcut: "X"),
            .init(title: "Bookmark Current Item", shortcut: "B"),
            .init(title: "Primary Prefix Rename", shortcut: "Q"),
            .init(title: "Secondary Prefix Rename", shortcut: "⌥Q"),
            .init(title: "Shuffle", shortcut: "⌥⌘S"),
            .init(title: "Endless Shuffle", shortcut: "⌥⌘E"),
            .init(title: "Repeat One", shortcut: "⌥⌘R")
        ]),
        .init(title: "Skip Duration Presets", items: [
            .init(title: "10 seconds", shortcut: "1"),
            .init(title: "30 seconds", shortcut: "3"),
            .init(title: "60 seconds", shortcut: "6"),
            .init(title: "3 minutes", shortcut: "9")
        ]),
        .init(title: "Video & Window", items: [
            .init(title: "Fit", shortcut: "⌘1"),
            .init(title: "Fill", shortcut: "⌘2"),
            .init(title: "Stretch", shortcut: "⌘3"),
            .init(title: "Minimize", shortcut: "⌘M"),
            .init(title: "Four Window Grid", shortcut: "⌘4")
        ]),
        .init(title: "Queue & Settings", items: [
            .init(title: "Remove selected queue rows", shortcut: "Delete / Forward Delete"),
            .init(title: "Move Settings sidebar selection", shortcut: "↑ / ↓")
        ])
    ]

    private func buildShortcutsSection() -> NSView {
        let sections = Self.shortcutGroups.map { group in
            buildSection(title: group.title, rows: group.items.map(buildShortcutRow(_:)))
        }
        return buildSectionContainer(sections: sections)
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

    private func buildShortcutRow(_ item: ShortcutItem) -> NSView {
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 240).isActive = true

        let shortcut = NSTextField(labelWithString: item.shortcut)
        shortcut.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .right
        shortcut.lineBreakMode = .byTruncatingTail
        shortcut.translatesAutoresizingMaskIntoConstraints = false
        shortcut.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

        let row = NSStackView(views: [title, shortcut])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 18
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
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

    @objc private func restoreAllSettingsToDefault(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = "Restore all settings to default?"
        alert.informativeText = "This resets dwb player preferences. It does not delete media files, queues, or bookmarks."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")

        if let window = self.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.performRestoreSettingsDefaults()
            }
        } else {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            performRestoreSettingsDefaults()
        }
    }

    private func performRestoreSettingsDefaults() {
        Self.restoreSettingsDefaults()
        syncUIFromDefaults()
        targetPlayerWindowController()?.setWindowOpacityFromSettings(Self.defaultPlayerWindowOpacityValue)
        DebugConsoleController.log("settings", "restoreDefaults")
    }

    @objc private func clearAllBookmarks(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = "Clear all bookmarks?"
        alert.informativeText = "Bookmarks are stored locally and can include full file paths. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear Bookmarks")
        alert.addButton(withTitle: "Cancel")

        if let window = self.window {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                BookmarkStore.shared.clearAll()
                DebugConsoleController.log("settings", "clearAllBookmarks")
            }
        } else {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            BookmarkStore.shared.clearAll()
            DebugConsoleController.log("settings", "clearAllBookmarks")
        }
    }

    @objc private func openGitHubRepository(_ sender: Any) {
        guard let url = URL(string: Self.githubURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openGitHubIssues(_ sender: Any) {
        guard let url = URL(string: Self.githubIssuesURLString) else { return }
        NSWorkspace.shared.open(url)
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
