import Cocoa

extension Notification.Name {
    static let autoHideSettingChanged         = Notification.Name("dwb.autoHideSettingChanged")
    /// Posted when any optional-control visibility setting changes.
    /// All open TransportControlsView instances observe this and call applyVisibilitySettings().
    static let transportVisibilityChanged     = Notification.Name("dwb.transportVisibilityChanged")
    /// Posted when the shared skip-duration preference changes.
    static let skipDurationChanged            = Notification.Name("dwb.skipDurationChanged")
    /// Posted when the one-click x_ prefix rename setting changes.
    static let xPrefixRenameChanged           = Notification.Name("dwb.xPrefixRenameChanged")
    /// Posted when the titlebar auto-hide setting changes.
    static let autoHideTitlebarChanged        = Notification.Name("dwb.autoHideTitlebarChanged")
    /// Posted when windowed Complete Video Mode changes.
    static let completeVideoWindowModeChanged = Notification.Name("dwb.completeVideoWindowModeChanged")
    /// Posted when the image slideshow display duration changes.
    static let imageDurationChanged           = Notification.Name("dwb.imageDurationChanged")
    /// Posted when the GIF playback loop-count setting changes.
    static let gifLoopCountChanged            = Notification.Name("dwb.gifLoopCountChanged")
    /// Posted when the title overlay on playback start setting changes.
    static let titleOverlaySettingChanged     = Notification.Name("dwb.titleOverlaySettingChanged")
    /// Posted when the video-page x_ rename button visibility setting changes.
    static let videoPageXButtonSettingChanged = Notification.Name("dwb.videoPageXButtonSettingChanged")
    /// Posted when the one-click custom prefix rename setting changes.
    static let customPrefixRenameChanged                   = Notification.Name("dwb.customPrefixRenameChanged")
    /// Posted when the video-page custom prefix button visibility setting changes.
    static let videoPageCustomPrefixButtonSettingChanged   = Notification.Name("dwb.videoPageCustomPrefixButtonSettingChanged")
    /// Posted when the stored custom prefix value changes.
    static let customPrefixValueChanged                    = Notification.Name("dwb.customPrefixValueChanged")
    /// Posted when the debug console enable setting changes.
    static let debugConsoleSettingChanged     = Notification.Name("dwb.debugConsoleSettingChanged")
}

/// Singleton settings panel. Open via dwb > Settings… (Cmd+,).
/// Four sidebar sections: Playback, Controls, Queue & Files, Developer.
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

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
    /// One-click x_ prefix rename in Queue Page. Default: false.
    static let xPrefixRenameKey         = "xPrefixRenameEnabled"
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
    /// Show title overlay when video or image playback starts. Default: true.
    static let showTitleOverlayKey      = "showTitleOverlay"
    /// Show x_ rename button in player/video page. Default: false.
    static let videoPageXButtonKey      = "videoPageXButtonEnabled"
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
    static func isXPrefixRenameEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: xPrefixRenameKey)
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
    static func isVideoPageXButtonEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: videoPageXButtonKey)
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
            xPrefixRenameKey:           false,
            autoHideTitlebarKey:        false,
            completeVideoWindowModeKey: false,
            showTitleOverlayKey:        true,
            videoPageXButtonKey:        false,
            deletePrefixRenameKey:      false,
            videoPageDButtonKey:        false,
            customPrefixValueKey:       "",
            debugConsoleKey:            false,
            verboseAutoplayTraceKey:    false,
            chromeAutohideThresholdKey: 3.0,
            chromeReducedMotionKey:     NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            queuePanelOpenAtLaunchKey:  false,
            useUnifiedBottomRailKey:    true,
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
    private let showTitleOverlayCheckbox    = NSButton()
    private let imageDurationPopup          = NSPopUpButton()
    private let gifLoopCountPopup           = NSPopUpButton()

    // Controls section
    private let autoHideCheckbox             = NSButton()
    private var optionalControlCheckboxes:   [OptionalTransportControl: NSButton] = [:]
    private let useUnifiedBottomRailCheckbox = NSButton()
    private let chromeAutohideThresholdPopup = NSPopUpButton()
    private let chromeReducedMotionCheckbox  = NSButton()
    private let autoHideTitlebarCheckbox     = NSButton()
    private let completeVideoWindowModeCheckbox = NSButton()
    private let windowOpacitySlider       = NSSlider()
    private let windowOpacityPercentLabel = NSTextField(labelWithString: "100%")
    private let windowOpacityResetButton  = NSButton()

    // Queue & Files section
    private let xPrefixRenameCheckbox          = NSButton()
    private let customPrefixQueuePageCheckbox  = NSButton()
    private let customPrefixValueTextField     = NSTextField()
    private let videoPageXButtonCheckbox       = NSButton()
    private let customPrefixVideoPageCheckbox  = NSButton()
    private let queuePanelOpenAtLaunchCheckbox = NSButton()

    // Developer section
    private let debugConsoleCheckbox          = NSButton()
    private let verboseAutoplayTraceCheckbox  = NSButton()

    // MARK: - Sidebar / detail state

    private let sidebarTable    = NSTableView()
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
        super.init(window: win)
        buildUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: win
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI construction

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        // Sidebar scroll + table
        let sidebarScroll = NSScrollView()
        sidebarScroll.hasVerticalScroller   = false
        sidebarScroll.hasHorizontalScroller = false
        sidebarScroll.borderType            = .noBorder
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        col.isEditable = false
        sidebarTable.addTableColumn(col)
        sidebarTable.headerView                = nil
        sidebarTable.rowHeight                 = 36
        sidebarTable.dataSource                = self
        sidebarTable.delegate                  = self
        sidebarTable.allowsMultipleSelection   = false
        sidebarTable.allowsEmptySelection      = false
        sidebarTable.style                     = .sourceList
        sidebarScroll.documentView             = sidebarTable

        // Vertical separator
        let sepLine = SettingsSeparatorLine()
        sepLine.translatesAutoresizingMaskIntoConstraints = false

        // Detail container
        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        cv.addSubview(sidebarScroll)
        cv.addSubview(sepLine)
        cv.addSubview(detailContainer)

        NSLayoutConstraint.activate([
            sidebarScroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            sidebarScroll.topAnchor.constraint(equalTo: cv.topAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 152),

            sepLine.leadingAnchor.constraint(equalTo: sidebarScroll.trailingAnchor),
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

        sidebarTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        syncUIFromDefaults()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { sectionNames.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("sectionCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            let c = NSTableCellView()
            c.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.font = .systemFont(ofSize: NSFont.systemFontSize)
            tf.textColor = .labelColor
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.textField = tf
            c.addSubview(tf)
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 10),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            cell = c
        }
        cell.textField?.stringValue = sectionNames[row]
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebarTable.selectedRow
        guard row >= 0, row < sectionViews.count else { return }
        for (i, sv) in sectionViews.enumerated() {
            sv.isHidden = (i != row)
        }
    }

    // MARK: - Section: Playback

    private func buildPlaybackSection() -> NSView {
        let cv   = NSView()
        let lead: CGFloat = 20
        let gap:  CGFloat = 4

        let secA = makeSectionLabel("Skip duration")
        cv.addSubview(secA)

        let skipDescLabel = makeBodyLabel("Duration for backward and forward skip")
        cv.addSubview(skipDescLabel)

        skipDurationPopup.translatesAutoresizingMaskIntoConstraints = false
        skipDurationPopup.target = self
        skipDurationPopup.action = #selector(skipDurationPopupChanged(_:))
        for opt in Self.skipDurationOptions {
            skipDurationPopup.addItem(withTitle: opt.title)
            skipDurationPopup.lastItem?.tag = opt.seconds
        }
        cv.addSubview(skipDurationPopup)

        let secB = makeSectionLabel("Appearance")
        cv.addSubview(secB)

        configure(showTitleOverlayCheckbox,
                  title: "Show title overlay on playback start",
                  state: Self.isShowTitleOverlayEnabled(), in: cv)

        let secC = makeSectionLabel("Images & animated GIFs")
        cv.addSubview(secC)

        let imgLabel = makeBodyLabel("Image slideshow duration")
        cv.addSubview(imgLabel)

        imageDurationPopup.translatesAutoresizingMaskIntoConstraints = false
        imageDurationPopup.target = self
        imageDurationPopup.action = #selector(imageDurationPopupChanged(_:))
        for opt in Self.imageDurationOptions {
            imageDurationPopup.addItem(withTitle: opt.title)
            imageDurationPopup.lastItem?.tag = opt.seconds
        }
        cv.addSubview(imageDurationPopup)

        let imgNote = makeNoteLabel("Duration each image is displayed before advancing.")
        cv.addSubview(imgNote)

        let gifLabel = makeBodyLabel("GIF loop count before advancing")
        cv.addSubview(gifLabel)

        gifLoopCountPopup.translatesAutoresizingMaskIntoConstraints = false
        gifLoopCountPopup.target = self
        gifLoopCountPopup.action = #selector(gifLoopCountPopupChanged(_:))
        for opt in Self.gifLoopCountOptions {
            gifLoopCountPopup.addItem(withTitle: opt.title)
            gifLoopCountPopup.lastItem?.tag = opt.loops
        }
        cv.addSubview(gifLoopCountPopup)

        let gifNote = makeNoteLabel("Animated GIFs advance after the selected number of full loops.")
        cv.addSubview(gifNote)

        NSLayoutConstraint.activate([
            secA.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            secA.topAnchor.constraint(equalTo: cv.topAnchor, constant: 16),

            skipDescLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            skipDescLabel.topAnchor.constraint(equalTo: secA.bottomAnchor, constant: 6),

            skipDurationPopup.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            skipDurationPopup.topAnchor.constraint(equalTo: skipDescLabel.bottomAnchor, constant: gap),
            skipDurationPopup.widthAnchor.constraint(equalToConstant: 160),

            secB.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            secB.topAnchor.constraint(equalTo: skipDurationPopup.bottomAnchor, constant: 18),

            showTitleOverlayCheckbox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            showTitleOverlayCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            showTitleOverlayCheckbox.topAnchor.constraint(equalTo: secB.bottomAnchor, constant: 6),

            secC.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            secC.topAnchor.constraint(equalTo: showTitleOverlayCheckbox.bottomAnchor, constant: 18),

            imgLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            imgLabel.topAnchor.constraint(equalTo: secC.bottomAnchor, constant: 6),

            imageDurationPopup.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            imageDurationPopup.topAnchor.constraint(equalTo: imgLabel.bottomAnchor, constant: gap),
            imageDurationPopup.widthAnchor.constraint(equalToConstant: 160),

            imgNote.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            imgNote.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            imgNote.topAnchor.constraint(equalTo: imageDurationPopup.bottomAnchor, constant: 5),

            gifLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            gifLabel.topAnchor.constraint(equalTo: imgNote.bottomAnchor, constant: 14),

            gifLoopCountPopup.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            gifLoopCountPopup.topAnchor.constraint(equalTo: gifLabel.bottomAnchor, constant: gap),
            gifLoopCountPopup.widthAnchor.constraint(equalToConstant: 160),

            gifNote.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            gifNote.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            gifNote.topAnchor.constraint(equalTo: gifLoopCountPopup.bottomAnchor, constant: 5),
        ])

        return cv
    }

    // MARK: - Section: Controls

    private func buildControlsSection() -> NSView {
        let cv   = NSView()
        let lead: CGFloat = 20
        let gap:  CGFloat = 4

        let secA = makeSectionLabel("Transport")
        cv.addSubview(secA)

        configure(autoHideCheckbox,
                  title: "Auto-hide controls bar in windowed mode",
                  state: UserDefaults.standard.bool(forKey: Self.autoHideKey), in: cv)

        let secB = makeSectionLabel("Optional controls")
        cv.addSubview(secB)

        let optNote = makeNoteLabel("These stay hidden by default until enabled here.")
        cv.addSubview(optNote)

        var prevOpt: NSButton?
        for control in OptionalTransportControl.allCases {
            let cb = NSButton()
            configure(cb, title: control.settingsTitle,
                      state: Self.isOptionalTransportControlVisible(control), in: cv)
            optionalControlCheckboxes[control] = cb
            if let prev = prevOpt {
                cb.topAnchor.constraint(equalTo: prev.bottomAnchor, constant: gap).isActive = true
            } else {
                cb.topAnchor.constraint(equalTo: optNote.bottomAnchor, constant: gap + 2).isActive = true
            }
            cb.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead).isActive = true
            cb.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead).isActive = true
            prevOpt = cb
        }
        let lastOpt = prevOpt ?? optNote

        let secC = makeSectionLabel("Bottom rail")
        cv.addSubview(secC)

        configure(useUnifiedBottomRailCheckbox,
                  title: "Use unified bottom rail",
                  state: UserDefaults.standard.bool(forKey: Self.useUnifiedBottomRailKey), in: cv)

        let railNote = makeNoteLabel("When off, falls back to the draggable control pod.")
        cv.addSubview(railNote)

        let thresholdLabel = makeBodyLabel("Rail auto-hide delay")
        cv.addSubview(thresholdLabel)

        chromeAutohideThresholdPopup.translatesAutoresizingMaskIntoConstraints = false
        chromeAutohideThresholdPopup.target = self
        chromeAutohideThresholdPopup.action = #selector(chromeThresholdPopupChanged(_:))
        for opt in Self.chromeThresholdOptions {
            chromeAutohideThresholdPopup.addItem(withTitle: opt.title)
            chromeAutohideThresholdPopup.lastItem?.tag = Self.chromeThresholdTag(for: opt.seconds)
        }
        cv.addSubview(chromeAutohideThresholdPopup)

        configure(chromeReducedMotionCheckbox,
                  title: "Reduce motion",
                  state: UserDefaults.standard.bool(forKey: Self.chromeReducedMotionKey), in: cv)

        let secD = makeSectionLabel("Titlebar")
        cv.addSubview(secD)

        configure(autoHideTitlebarCheckbox,
                  title: "Auto-hide titlebar",
                  state: Self.isAutoHideTitlebarEnabled(), in: cv)

        configure(completeVideoWindowModeCheckbox,
                  title: "Complete video mode (windowed)",
                  state: Self.isCompleteVideoWindowModeEnabled(), in: cv)

        let completeVideoModeNote = makeNoteLabel("Hide the titlebar and traffic-light buttons so video fills the window.")
        cv.addSubview(completeVideoModeNote)

        let secE = makeSectionLabel("Window")
        cv.addSubview(secE)

        let windowOpacityLabel = makeBodyLabel("Window opacity")
        cv.addSubview(windowOpacityLabel)

        windowOpacitySlider.translatesAutoresizingMaskIntoConstraints = false
        windowOpacitySlider.minValue = Double(Self.playerWindowOpacityMin * 100.0)
        windowOpacitySlider.maxValue = Double(Self.playerWindowOpacityMax * 100.0)
        windowOpacitySlider.target = self
        windowOpacitySlider.action = #selector(windowOpacitySliderChanged(_:))
        cv.addSubview(windowOpacitySlider)

        windowOpacityPercentLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        windowOpacityPercentLabel.textColor = .secondaryLabelColor
        windowOpacityPercentLabel.alignment = .right
        windowOpacityPercentLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(windowOpacityPercentLabel)

        windowOpacityResetButton.title = "Default"
        windowOpacityResetButton.bezelStyle = .rounded
        windowOpacityResetButton.target = self
        windowOpacityResetButton.action = #selector(resetWindowOpacity(_:))
        windowOpacityResetButton.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(windowOpacityResetButton)

        NSLayoutConstraint.activate([
            secA.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            secA.topAnchor.constraint(equalTo: cv.topAnchor, constant: 16),

            autoHideCheckbox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            autoHideCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            autoHideCheckbox.topAnchor.constraint(equalTo: secA.bottomAnchor, constant: 6),

            secB.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            secB.topAnchor.constraint(equalTo: autoHideCheckbox.bottomAnchor, constant: 14),

            optNote.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            optNote.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            optNote.topAnchor.constraint(equalTo: secB.bottomAnchor, constant: 4),

            secC.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            secC.topAnchor.constraint(equalTo: lastOpt.bottomAnchor, constant: 14),

            useUnifiedBottomRailCheckbox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            useUnifiedBottomRailCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            useUnifiedBottomRailCheckbox.topAnchor.constraint(equalTo: secC.bottomAnchor, constant: 6),

            railNote.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            railNote.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            railNote.topAnchor.constraint(equalTo: useUnifiedBottomRailCheckbox.bottomAnchor, constant: 4),

            thresholdLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            thresholdLabel.topAnchor.constraint(equalTo: railNote.bottomAnchor, constant: 10),

            chromeAutohideThresholdPopup.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            chromeAutohideThresholdPopup.topAnchor.constraint(equalTo: thresholdLabel.bottomAnchor, constant: gap),
            chromeAutohideThresholdPopup.widthAnchor.constraint(equalToConstant: 160),

            chromeReducedMotionCheckbox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            chromeReducedMotionCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            chromeReducedMotionCheckbox.topAnchor.constraint(equalTo: chromeAutohideThresholdPopup.bottomAnchor, constant: gap + 4),

            secD.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            secD.topAnchor.constraint(equalTo: chromeReducedMotionCheckbox.bottomAnchor, constant: 14),

            autoHideTitlebarCheckbox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            autoHideTitlebarCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            autoHideTitlebarCheckbox.topAnchor.constraint(equalTo: secD.bottomAnchor, constant: 6),

            completeVideoWindowModeCheckbox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            completeVideoWindowModeCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            completeVideoWindowModeCheckbox.topAnchor.constraint(equalTo: autoHideTitlebarCheckbox.bottomAnchor, constant: gap),

            completeVideoModeNote.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead + 18),
            completeVideoModeNote.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            completeVideoModeNote.topAnchor.constraint(equalTo: completeVideoWindowModeCheckbox.bottomAnchor, constant: 2),

            secE.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            secE.topAnchor.constraint(equalTo: completeVideoModeNote.bottomAnchor, constant: 14),

            windowOpacityLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            windowOpacityLabel.topAnchor.constraint(equalTo: secE.bottomAnchor, constant: 6),

            windowOpacitySlider.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            windowOpacitySlider.topAnchor.constraint(equalTo: windowOpacityLabel.bottomAnchor, constant: gap),
            windowOpacitySlider.widthAnchor.constraint(equalToConstant: 260),

            windowOpacityPercentLabel.leadingAnchor.constraint(equalTo: windowOpacitySlider.trailingAnchor, constant: 10),
            windowOpacityPercentLabel.centerYAnchor.constraint(equalTo: windowOpacitySlider.centerYAnchor),
            windowOpacityPercentLabel.widthAnchor.constraint(equalToConstant: 46),

            windowOpacityResetButton.leadingAnchor.constraint(equalTo: windowOpacityPercentLabel.trailingAnchor, constant: 10),
            windowOpacityResetButton.centerYAnchor.constraint(equalTo: windowOpacitySlider.centerYAnchor),
        ])

        return cv
    }

    // MARK: - Section: Queue & Files

    private func buildQueueFilesSection() -> NSView {
        let cv   = NSView()
        let lead: CGFloat = 20
        let gap:  CGFloat = 4

        let secA = makeSectionLabel("Queue page rename")
        cv.addSubview(secA)

        configure(xPrefixRenameCheckbox,
                  title: "Enable one-click x_ prefix rename",
                  state: Self.isXPrefixRenameEnabled(), in: cv)

        configure(customPrefixQueuePageCheckbox,
                  title: "Enable one-click custom prefix rename",
                  state: Self.isCustomPrefixQueuePageEnabled(), in: cv)

        let prefixLabel = makeBodyLabel("Custom prefix")
        cv.addSubview(prefixLabel)

        customPrefixValueTextField.isEditable = true
        customPrefixValueTextField.isBordered = true
        customPrefixValueTextField.bezelStyle = .roundedBezel
        customPrefixValueTextField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        customPrefixValueTextField.placeholderString = "e.g. Studio - "
        customPrefixValueTextField.stringValue = Self.customPrefixValue()
        customPrefixValueTextField.delegate = self
        customPrefixValueTextField.toolTip = "Prefix applied to filename stem. Spaces and punctuation are preserved. The \"/\" character is not allowed."
        customPrefixValueTextField.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(customPrefixValueTextField)

        let prefixNote = makeNoteLabel("Applied as: prefix + filename stem + extension. Trailing spaces are preserved.")
        cv.addSubview(prefixNote)

        let secB = makeSectionLabel("Player page buttons")
        cv.addSubview(secB)

        configure(videoPageXButtonCheckbox,
                  title: "Show x_ rename button in player page",
                  state: Self.isVideoPageXButtonEnabled(), in: cv)

        let xNote = makeNoteLabel("Also bound to the q key.")
        cv.addSubview(xNote)

        configure(customPrefixVideoPageCheckbox,
                  title: "Show custom prefix button in player page",
                  state: Self.isCustomPrefixVideoPageEnabled(), in: cv)

        let secC = makeSectionLabel("Queue behavior")
        cv.addSubview(secC)

        configure(queuePanelOpenAtLaunchCheckbox,
                  title: "Open queue panel when a player window opens",
                  state: UserDefaults.standard.bool(forKey: Self.queuePanelOpenAtLaunchKey), in: cv)

        NSLayoutConstraint.activate([
            secA.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            secA.topAnchor.constraint(equalTo: cv.topAnchor, constant: 16),

            xPrefixRenameCheckbox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            xPrefixRenameCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            xPrefixRenameCheckbox.topAnchor.constraint(equalTo: secA.bottomAnchor, constant: 6),

            customPrefixQueuePageCheckbox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            customPrefixQueuePageCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            customPrefixQueuePageCheckbox.topAnchor.constraint(equalTo: xPrefixRenameCheckbox.bottomAnchor, constant: gap),

            prefixLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            prefixLabel.topAnchor.constraint(equalTo: customPrefixQueuePageCheckbox.bottomAnchor, constant: 12),

            customPrefixValueTextField.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            customPrefixValueTextField.topAnchor.constraint(equalTo: prefixLabel.bottomAnchor, constant: gap),
            customPrefixValueTextField.widthAnchor.constraint(equalToConstant: 220),

            prefixNote.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            prefixNote.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            prefixNote.topAnchor.constraint(equalTo: customPrefixValueTextField.bottomAnchor, constant: 4),

            secB.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            secB.topAnchor.constraint(equalTo: prefixNote.bottomAnchor, constant: 18),

            videoPageXButtonCheckbox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            videoPageXButtonCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            videoPageXButtonCheckbox.topAnchor.constraint(equalTo: secB.bottomAnchor, constant: 6),

            xNote.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead + 18),
            xNote.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            xNote.topAnchor.constraint(equalTo: videoPageXButtonCheckbox.bottomAnchor, constant: 2),

            customPrefixVideoPageCheckbox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            customPrefixVideoPageCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            customPrefixVideoPageCheckbox.topAnchor.constraint(equalTo: xNote.bottomAnchor, constant: gap),

            secC.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            secC.topAnchor.constraint(equalTo: customPrefixVideoPageCheckbox.bottomAnchor, constant: 18),

            queuePanelOpenAtLaunchCheckbox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            queuePanelOpenAtLaunchCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            queuePanelOpenAtLaunchCheckbox.topAnchor.constraint(equalTo: secC.bottomAnchor, constant: 6),
        ])

        return cv
    }

    // MARK: - Section: Developer

    private func buildDeveloperSection() -> NSView {
        let cv   = NSView()
        let lead: CGFloat = 20

        let secA = makeSectionLabel("Debug console")
        cv.addSubview(secA)

        configure(debugConsoleCheckbox,
                  title: "Show debug console",
                  state: Self.isDebugConsoleEnabled(), in: cv)

        let debugNote = makeNoteLabel("Displays high-signal diagnostic events. Default: off.")
        cv.addSubview(debugNote)

        let secB = makeSectionLabel("Autoplay diagnostics")
        cv.addSubview(secB)

        configure(verboseAutoplayTraceCheckbox,
                  title: "Verbose autoplay trace (debug builds only)",
                  state: Self.isVerboseAutoplayTraceEnabled(), in: cv)

        let traceNote = makeNoteLabel("Prints per-tick watchdog trace to Xcode console. Default: off.")
        cv.addSubview(traceNote)

        NSLayoutConstraint.activate([
            secA.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            secA.topAnchor.constraint(equalTo: cv.topAnchor, constant: 16),

            debugConsoleCheckbox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            debugConsoleCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            debugConsoleCheckbox.topAnchor.constraint(equalTo: secA.bottomAnchor, constant: 6),

            debugNote.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            debugNote.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            debugNote.topAnchor.constraint(equalTo: debugConsoleCheckbox.bottomAnchor, constant: 4),

            secB.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            secB.topAnchor.constraint(equalTo: debugNote.bottomAnchor, constant: 16),

            verboseAutoplayTraceCheckbox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            verboseAutoplayTraceCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            verboseAutoplayTraceCheckbox.topAnchor.constraint(equalTo: secB.bottomAnchor, constant: 6),

            traceNote.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: lead),
            traceNote.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -lead),
            traceNote.topAnchor.constraint(equalTo: verboseAutoplayTraceCheckbox.bottomAnchor, constant: 4),
        ])

        return cv
    }

    // MARK: - Layout helpers

    private func configure(_ btn: NSButton, title: String, state: Bool, in view: NSView) {
        btn.setButtonType(.switch)
        btn.title  = title
        btn.font   = .systemFont(ofSize: NSFont.systemFontSize)
        btn.target = self
        btn.action = #selector(checkboxToggled(_:))
        btn.state  = state ? .on : .off
        btn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(btn)
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        lbl.textColor = .secondaryLabelColor
        lbl.translatesAutoresizingMaskIntoConstraints = false
        return lbl
    }

    private func makeBodyLabel(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: NSFont.systemFontSize)
        lbl.textColor = .labelColor
        lbl.translatesAutoresizingMaskIntoConstraints = false
        return lbl
    }

    private func makeNoteLabel(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        lbl.textColor = .secondaryLabelColor
        lbl.translatesAutoresizingMaskIntoConstraints = false
        return lbl
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
        if sender === xPrefixRenameCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.xPrefixRenameKey)
            NotificationCenter.default.post(name: .xPrefixRenameChanged, object: nil)
            DebugConsoleController.log("settings", "xPrefixRename=\(enabled)")
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
        if sender === videoPageXButtonCheckbox {
            UserDefaults.standard.set(enabled, forKey: Self.videoPageXButtonKey)
            NotificationCenter.default.post(name: .videoPageXButtonSettingChanged, object: nil)
            DebugConsoleController.log("settings", "videoPageXButton=\(enabled)")
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
    }

    // MARK: - Sync

    private func syncUIFromDefaults() {
        autoHideCheckbox.state = UserDefaults.standard.bool(forKey: Self.autoHideKey) ? .on : .off
        for (control, cb) in optionalControlCheckboxes {
            cb.state = Self.isOptionalTransportControlVisible(control) ? .on : .off
        }
        xPrefixRenameCheckbox.state            = Self.isXPrefixRenameEnabled()             ? .on : .off
        videoPageXButtonCheckbox.state         = Self.isVideoPageXButtonEnabled()         ? .on : .off
        customPrefixQueuePageCheckbox.state    = Self.isCustomPrefixQueuePageEnabled()    ? .on : .off
        customPrefixVideoPageCheckbox.state    = Self.isCustomPrefixVideoPageEnabled()    ? .on : .off
        customPrefixValueTextField.stringValue = Self.customPrefixValue()
        autoHideTitlebarCheckbox.state         = Self.isAutoHideTitlebarEnabled()      ? .on : .off
        completeVideoWindowModeCheckbox.state  = Self.isCompleteVideoWindowModeEnabled() ? .on : .off
        showTitleOverlayCheckbox.state         = Self.isShowTitleOverlayEnabled()      ? .on : .off
        debugConsoleCheckbox.state             = Self.isDebugConsoleEnabled()          ? .on : .off
        verboseAutoplayTraceCheckbox.state     = Self.isVerboseAutoplayTraceEnabled()  ? .on : .off
        useUnifiedBottomRailCheckbox.state     = UserDefaults.standard.bool(forKey: Self.useUnifiedBottomRailKey)    ? .on : .off
        chromeReducedMotionCheckbox.state      = UserDefaults.standard.bool(forKey: Self.chromeReducedMotionKey)     ? .on : .off
        queuePanelOpenAtLaunchCheckbox.state   = UserDefaults.standard.bool(forKey: Self.queuePanelOpenAtLaunchKey) ? .on : .off

        skipDurationPopup.selectItem(withTag: Self.currentSkipDurationSeconds())
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
        guard let field = obj.object as? NSTextField, field === customPrefixValueTextField else { return }
        let prefix = field.stringValue
        guard !prefix.contains("/"), !prefix.contains("\0") else { return }
        UserDefaults.standard.set(prefix, forKey: Self.customPrefixValueKey)
        NotificationCenter.default.post(name: .customPrefixValueChanged, object: nil)
        DebugConsoleController.log("settings", "customPrefixValue='\(prefix)'")
    }

    // MARK: - Open

    func openSettings() {
        syncUIFromDefaults()
        if !(window?.isVisible ?? false) {
            window?.center()
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Appearance-aware vertical separator

private final class SettingsSeparatorLine: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}
