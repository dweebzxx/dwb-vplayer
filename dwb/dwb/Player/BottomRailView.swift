import Cocoa
import VLCKitSPM

final class BottomRailView: NSView {
    weak var player: VLCMediaPlayer?
    weak var controller: PlayerWindowController?

    var scrubDidBegin: (() -> Void)?
    var scrubDidEnd: (() -> Void)?

    private let veil = NSView()
    private let queueButton = RailButton()
    private let dPrefixButton = RailButton()
    private let secondaryPrefixButton = RailButton()
    private let rewindButton = RailButton()
    private let prevButton = RailButton()
    private let playPauseButton = RailButton()
    private let nextButton = RailButton()
    private let forwardButton = RailButton()
    private let volumeButton = RailButton()
    private let shuffleButton = RailButton()
    private let repeatButton = RailButton()
    private let bookmarkButton = RailButton()
    private let moreButton = RailButton()
    private let settingsButton = RailButton()
    private let fullscreenButton = RailButton()
    private let elapsedLabel = NSTextField(labelWithString: "-:--")
    private let remainingLabel = NSTextField(labelWithString: "-:--")
    private let scrubber = ScrubberSlider()

    private var preMuteVolume: Int32 = 100
    private var isScrubbing = false
    private var isFullscreenStyle = false
    private var pendingSeekPosition: Float?
    private var pendingSeekDate: Date?
    private let pendingSeekTimeout: TimeInterval = 1.5

    var isImageMode: Bool = false
    var imageModeElapsed: Double = 0
    var imageModeDuration: Double = 3
    var imageModeIsPlaying: Bool = true

    private var cachedPlayPauseSymbol: String?
    private var cachedVolumeSymbol: String?
    private var cachedRepeatSymbol: String?
    private var cachedElapsedText: String?
    private var cachedRemainingText: String?
    private var cachedScrubberValue = -1.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setupViews()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBottomRailButtonVisibilityChanged),
            name: .bottomRailButtonVisibilityChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCustomPrefixValueChanged),
            name: .customPrefixValueChanged,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("programmatic only")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleBottomRailButtonVisibilityChanged() {
        applyVisibilitySettings()
    }

    @objc private func handleCustomPrefixValueChanged() {
        updatePrefixButtonLabels()
        applyVisibilitySettings()
    }

    fileprivate static func trimmedPrefix(_ prefix: String) -> String {
        prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func railPrefixLabel(_ prefix: String) -> String {
        let trimmed = trimmedPrefix(prefix)
        guard let first = trimmed.first else { return "" }
        return "\(first)_"
    }

    private static func hasConfiguredPrefix(_ prefix: String) -> Bool {
        !trimmedPrefix(prefix).isEmpty
    }

    private static func hasDistinctSecondaryPrefix(primary: String, secondary: String) -> Bool {
        let primaryTrimmed = trimmedPrefix(primary)
        let secondaryTrimmed = trimmedPrefix(secondary)
        return !secondaryTrimmed.isEmpty && secondaryTrimmed != primaryTrimmed
    }

    private func updatePrefixButtonLabels() {
        dPrefixButton.title = BottomRailView.railPrefixLabel(SettingsWindowController.customPrefixValue())
        secondaryPrefixButton.title = BottomRailView.railPrefixLabel(SettingsWindowController.customPrefixSecondaryValue())
    }

    func applyVisibilitySettings() {
        updatePrefixButtonLabels()
        let primary = SettingsWindowController.customPrefixValue()
        let secondary = SettingsWindowController.customPrefixSecondaryValue()
        let showPrefixButtons = SettingsWindowController.isBottomRailShowXEnabled()
        dPrefixButton.isHidden         = !showPrefixButtons || !BottomRailView.hasConfiguredPrefix(primary)
        secondaryPrefixButton.isHidden = !showPrefixButtons || !BottomRailView.hasDistinctSecondaryPrefix(primary: primary, secondary: secondary)
        shuffleButton.isHidden         = !SettingsWindowController.isBottomRailShowShuffleEnabled()
        repeatButton.isHidden          = !SettingsWindowController.isBottomRailShowReplayEnabled()
        volumeButton.isHidden          = !SettingsWindowController.isBottomRailShowVolumeEnabled()
        bookmarkButton.isHidden        = !SettingsWindowController.isBottomRailShowBookmarkEnabled()
        // Rebuild any open More popover so visibility changes take effect live.
        if let popover = moreMenuPopover, popover.isShown {
            popover.performClose(nil)
            moreMenuPopover = nil
        }
        applySkipDurationSettings()
        invalidateCachedDisplayState()
        needsLayout = true
    }

    func applySkipDurationSettings() {
        let seconds = SettingsWindowController.currentSkipDurationSeconds()
        let rewindTitle = SettingsWindowController.skipActionTitle(isForward: false, seconds: seconds)
        let forwardTitle = SettingsWindowController.skipActionTitle(isForward: true, seconds: seconds)
        rewindButton.configureSymbol(skipSymbolName(isForward: false, seconds: seconds),
                                     pointSize: 13,
                                     accessibilityLabel: rewindTitle,
                                     help: rewindTitle,
                                     fallbackNames: ["gobackward"])
        forwardButton.configureSymbol(skipSymbolName(isForward: true, seconds: seconds),
                                      pointSize: 13,
                                      accessibilityLabel: forwardTitle,
                                      help: forwardTitle,
                                      fallbackNames: ["goforward"])
    }

    func setFullscreenStyle(_ fullscreen: Bool) {
        guard isFullscreenStyle != fullscreen else { return }
        isFullscreenStyle = fullscreen
        fullscreenButton.configureSymbol(fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                         pointSize: fullscreen ? 10 : 11,
                                         accessibilityLabel: "Toggle Fullscreen",
                                         help: "Toggle Fullscreen")
        needsLayout = true
    }

    func invalidateCachedDisplayState() {
        cachedPlayPauseSymbol = nil
        cachedVolumeSymbol = nil
        cachedRepeatSymbol = nil
        cachedElapsedText = nil
        cachedRemainingText = nil
        cachedScrubberValue = -1
    }

    func notifySeek(to position: Float) {
        pendingSeekPosition = position
        pendingSeekDate = Date()
    }

    func update() {
        if isImageMode {
            updateForImageMode()
            return
        }

        guard let player else {
            setPlaybackButtonsEnabled(false)
            updateBookmarkButtonState()
            return
        }

        let hasMedia = player.media != nil
        let playSymbol = player.isPlaying ? "pause.fill" : "play.fill"
        if playSymbol != cachedPlayPauseSymbol {
            cachedPlayPauseSymbol = playSymbol
            playPauseButton.configureSymbol(playSymbol,
                                            pointSize: 15,
                                            accessibilityLabel: "Play or Pause",
                                            help: "Play / Pause (Space)")
        }

        updateScrubberFromPlayer(player)

        let elapsed = player.time.stringValue
        let remaining = player.remainingTime?.stringValue ?? "-:--"
        let timeText = controller?.isShowingProvisionalDuration == true
            ? "\(elapsed)  \(MediaFileSupport.durationLoadingText)"
            : "\(elapsed)  \(remaining)"
        setLabel(elapsedLabel, cached: &cachedElapsedText, text: timeText)
        // remainingLabel is always hidden; combined time is shown in elapsedLabel

        if let audio = player.audio {
            let volumeSymbol = audio.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
            if volumeSymbol != cachedVolumeSymbol {
                cachedVolumeSymbol = volumeSymbol
                volumeButton.configureSymbol(volumeSymbol,
                                             pointSize: 12,
                                             accessibilityLabel: "Mute or Unmute",
                                             help: "Mute / Unmute")
            }
        }

        rewindButton.isEnabled = hasMedia
        forwardButton.isEnabled = hasMedia
        playPauseButton.isEnabled = hasMedia
        prevButton.isEnabled = hasMedia && (controller?.hasPrevious ?? false)
        nextButton.isEnabled = hasMedia && (controller?.hasNext ?? false)

        queueButton.isEnabled = controller != nil
        queueButton.isToggled = controller?.isQueuePageOpen ?? false

        updateShuffleButtonState()

        repeatButton.isEnabled = hasMedia
        let repeatActive = controller?.isRepeatOne ?? false
        repeatButton.isToggled = repeatActive
        let repeatSymbol = repeatActive ? "repeat.1" : "repeat"
        if repeatSymbol != cachedRepeatSymbol {
            cachedRepeatSymbol = repeatSymbol
            repeatButton.configureSymbol(repeatSymbol,
                                         pointSize: 11,
                                         accessibilityLabel: "Repeat Current File",
                                         help: "Repeat current file")
        }

        updatePrefixButtons()
        updateBookmarkButtonState()
    }

    private func updateBookmarkButtonState() {
        let hasItem = controller?.currentMediaURL != nil
        bookmarkButton.isEnabled = hasItem
        let isBookmarked = controller?.isCurrentItemBookmarked ?? false
        bookmarkButton.isToggled = isBookmarked
        let symbol = isBookmarked ? "bookmark.fill" : "bookmark"
        let label = isBookmarked ? "Remove Bookmark" : "Bookmark"
        bookmarkButton.configureSymbol(symbol, pointSize: 11,
                                       accessibilityLabel: label,
                                       help: "Bookmark (B)")
        bookmarkButton.setAccessibilityValue(isBookmarked ? "bookmarked" : "not bookmarked")
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let railH: CGFloat = isFullscreenStyle ? 80 : 84
        let scrubH: CGFloat = 14
        let sidePad: CGFloat = w < 520 ? 12 : (isFullscreenStyle ? 16 : 20)
        let buttonSize: CGFloat = w < 440 ? 28 : 30
        let playSize: CGFloat = w < 440 ? 38 : 40
        let gap: CGFloat = w < 520 ? 6 : 8

        // Scrubber pinned to the very top edge of the rail; it bleeds off both window sides.
        let scrubY: CGFloat = railH - scrubH
        // Time labels float directly under the scrubber, centered above the play/pause button.
        let timeLabelH: CGFloat = 14
        let timeLabelGap: CGFloat = 2
        let timeLabelY: CGFloat = max(0, scrubY - timeLabelGap - timeLabelH)
        // Transport buttons vertically centered in the area beneath the time label row.
        let buttonRowAreaH: CGFloat = timeLabelY
        let rowY: CGFloat = max(0, (buttonRowAreaH - buttonSize) / 2)
        let playY: CGFloat = max(0, (buttonRowAreaH - playSize) / 2)

        // Veil background: top edge = scrubber bar bottom so the 3pt scrubber bar
        // visually IS the top edge of the shaded area. The scrubber frame extends
        // 11pt above the veil for hit-testing, but no shaded strip is visible above
        // the scrubber bar.
        let barThickness: CGFloat = 3
        let veilTopY = scrubY + scrubH - barThickness  // bottom of the visible 3pt bar
        veil.frame = NSRect(x: 0, y: 0, width: w, height: veilTopY)
        veil.layer?.cornerRadius = 0
        veil.layer?.maskedCorners = []
        veil.layer?.backgroundColor = NSColor.black.withAlphaComponent(isFullscreenStyle ? 0.22 : 0.36).cgColor
        scrubber.frame = NSRect(x: 0, y: scrubY, width: w, height: scrubH)

        applyResponsiveVisibility(width: w)

        // Left cluster: Queue, primary prefix, secondary prefix, Bookmark
        var leftX = sidePad
        for button in [queueButton, dPrefixButton, secondaryPrefixButton, bookmarkButton] where !button.isHidden {
            place(button, x: leftX, y: rowY, size: buttonSize)
            leftX += buttonSize + gap
        }

        // Pre-calculate right cluster left boundary so center group can be
        // clamped against it before either cluster is placed.
        let rightClusterOrder: [RailButton] = [fullscreenButton, moreButton, volumeButton, repeatButton, shuffleButton]
        let rightClusterCount = CGFloat(rightClusterOrder.filter { !$0.isHidden }.count)
        let rightClusterLeft: CGFloat = rightClusterCount == 0
            ? w - sidePad
            : w - sidePad - rightClusterCount * buttonSize - (rightClusterCount - 1) * gap

        let center: [(RailButton, CGFloat)] = [
            (rewindButton, buttonSize),
            (prevButton, buttonSize),
            (playPauseButton, playSize),
            (nextButton, buttonSize),
            (forwardButton, buttonSize)
        ]
        let centerWidth = center.reduce(CGFloat(0)) { $0 + $1.1 } + CGFloat(center.count - 1) * gap
        let maxCenterLeft = rightClusterLeft - centerWidth - gap
        let centerGroupLeft = min(maxCenterLeft, max(leftX + gap, (w - centerWidth) / 2))
        var centerX = centerGroupLeft
        for (button, size) in center {
            place(button, x: centerX, y: size == playSize ? playY : rowY, size: size)
            centerX += size + gap
        }
        let centerGroupCenterX = centerGroupLeft + centerWidth / 2

        // Right cluster: Fullscreen, More, Volume, Replay, Shuffle (laid out right-to-left)
        var rightX = w - sidePad - buttonSize
        for button in [fullscreenButton, moreButton, volumeButton, repeatButton, shuffleButton] where !button.isHidden {
            place(button, x: rightX, y: rowY, size: buttonSize)
            rightX -= buttonSize + gap
        }

        // Time label centered with the central transport group, directly under the scrubber.
        let timeLabelW: CGFloat = 130
        let timeLabelX = max(sidePad, min(w - sidePad - timeLabelW,
                                          centerGroupCenterX - timeLabelW / 2))
        elapsedLabel.frame = NSRect(x: timeLabelX, y: timeLabelY, width: timeLabelW, height: timeLabelH)
        remainingLabel.frame = .zero   // combined time shown in elapsedLabel
    }

    private func applyResponsiveVisibility(width: CGFloat) {
        // Settings act as the authoritative "show this button" gate; width is an
        // additional compression rule when the window is narrow.
        let primary = SettingsWindowController.customPrefixValue()
        let secondary = SettingsWindowController.customPrefixSecondaryValue()
        let showPrefixButtons = SettingsWindowController.isBottomRailShowXEnabled()
        dPrefixButton.isHidden = !showPrefixButtons
            || !BottomRailView.hasConfiguredPrefix(primary)
            || width < 500
        secondaryPrefixButton.isHidden = !showPrefixButtons
            || !BottomRailView.hasDistinctSecondaryPrefix(primary: primary, secondary: secondary)
            || width < 540
        elapsedLabel.isHidden    = width < 640
        remainingLabel.isHidden  = true   // combined time shown in elapsedLabel; always hidden
        shuffleButton.isHidden   = !SettingsWindowController.isBottomRailShowShuffleEnabled()  || width < 430
        repeatButton.isHidden    = !SettingsWindowController.isBottomRailShowReplayEnabled()   || width < 390
        volumeButton.isHidden    = !SettingsWindowController.isBottomRailShowVolumeEnabled()   || width < 360
        bookmarkButton.isHidden  = !SettingsWindowController.isBottomRailShowBookmarkEnabled() || width < 560
        moreButton.isHidden = width < 330
        settingsButton.isHidden = width < 330
    }

    private func setupViews() {
        veil.wantsLayer = true
        addSubview(veil)

        configure(queueButton, symbol: "square.split.2x1", label: "Toggle Queue Page", help: "Toggle Queue Page", action: #selector(queueTapped), style: .utility, size: 11)
        updatePrefixButtonLabels()
        configure(dPrefixButton, symbol: nil, label: "Apply Primary Custom Prefix", help: "Rename: apply primary custom prefix (Q)", action: #selector(dPrefixTapped), style: .prefixPrimary, title: dPrefixButton.title, size: 11)
        configure(secondaryPrefixButton, symbol: nil, label: "Apply Secondary Custom Prefix", help: "Rename: apply secondary custom prefix (Option-Q)", action: #selector(secondaryPrefixTapped), style: .prefixSecondary, title: secondaryPrefixButton.title, size: 11)
        configure(rewindButton, symbol: "gobackward.10", label: "Rewind", help: "Rewind", action: #selector(rewindTapped), size: 13)
        configure(prevButton, symbol: "backward.end.fill", label: "Previous File", help: "Previous file (Z)", action: #selector(prevTapped), size: 11)
        configure(playPauseButton, symbol: "play.fill", label: "Play or Pause", help: "Play / Pause (Space)", action: #selector(playPauseTapped), style: .emphasized, size: 15)
        configure(nextButton, symbol: "forward.end.fill", label: "Next File", help: "Next file (X)", action: #selector(nextTapped), size: 11)
        configure(forwardButton, symbol: "goforward.10", label: "Skip Forward", help: "Skip Forward", action: #selector(forwardTapped), size: 13)
        configure(volumeButton, symbol: "speaker.wave.2.fill", label: "Mute or Unmute", help: "Mute / Unmute", action: #selector(volumeTapped), size: 12)
        configure(shuffleButton, symbol: "shuffle", label: "Shuffle", help: "Shuffle", action: #selector(shuffleTapped), size: 11)
        configure(repeatButton, symbol: "repeat", label: "Repeat Current File", help: "Repeat current file", action: #selector(repeatTapped), size: 11)
        configure(bookmarkButton, symbol: "bookmark", label: "Bookmark", help: "Bookmark (B)", action: #selector(bookmarkTapped), size: 11)
        configure(moreButton, symbol: nil, label: "More", help: "More actions", action: #selector(moreTapped), title: "...")
        configure(settingsButton, symbol: "gearshape", label: "Settings", help: "Settings (⌘,)", action: #selector(settingsTapped), size: 11)
        configure(fullscreenButton, symbol: "arrow.up.left.and.arrow.down.right", label: "Toggle Fullscreen", help: "Toggle Fullscreen", action: #selector(fullscreenTapped), size: 11)

        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = NSColor.white.withAlphaComponent(0.65)
            label.drawsBackground = false
            label.alignment = .center
            addSubview(label)
        }
        elapsedLabel.setAccessibilityLabel("Playback time")

        // Draw the scrubber bar at the very top of the slider frame so the bar
        // visually reads as the top edge of the rail veil (no transparent strip
        // above the scrubber). Hit testing remains the full slider frame.
        scrubber.cell = TopAlignedKnoblessSliderCell()
        scrubber.minValue = 0
        scrubber.maxValue = 1
        scrubber.doubleValue = 0
        scrubber.isContinuous = true
        scrubber.target = self
        scrubber.action = #selector(scrubberMoved(_:))
        scrubber.scrubDidBegin = { [weak self] in
            guard let self else { return }
            self.pendingSeekPosition = nil
            self.pendingSeekDate = nil
            self.isScrubbing = true
            self.scrubDidBegin?()
            if !self.isImageMode {
                self.controller?.notifyUserSeek(source: "rail-scrub-begin")
            }
        }
        scrubber.scrubDidEnd = { [weak self] in
            guard let self else { return }
            self.isScrubbing = false
            defer { self.scrubDidEnd?() }
            guard !self.isImageMode else { return }
            let raw = Float(self.scrubber.doubleValue)
            let pos = self.controller?.clampedUserSeekPosition(raw, source: "rail-scrub-end")
                ?? max(0, min(0.985, raw))
            self.scrubber.doubleValue = Double(pos)
            self.controller?.notifyUserSeek(targetPosition: pos, source: "rail-scrub-end")
            self.player?.position = pos
            self.notifySeek(to: pos)
        }
        addSubview(scrubber)

        applyVisibilitySettings()
    }

    private func configure(_ button: RailButton,
                           symbol: String?,
                           label: String,
                           help: String,
                           action: Selector,
                           style: RailButton.Style = .normal,
                           title: String = "",
                           size: CGFloat = 11) {
        button.railStyle = style
        button.target = self
        button.action = action
        button.title = title
        if let symbol {
            button.configureSymbol(symbol, pointSize: size, accessibilityLabel: label, help: help)
        } else {
            button.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            button.setAccessibilityLabel(label)
            button.setAccessibilityHelp(help)
            button.toolTip = help
        }
        addSubview(button)
    }

    private func place(_ button: RailButton, x: CGFloat, y: CGFloat, size: CGFloat) {
        button.frame = NSRect(x: x, y: y, width: size, height: size)
        button.layer?.cornerRadius = size / 2
    }

    private func updateScrubberFromPlayer(_ player: VLCMediaPlayer) {
        guard !isScrubbing else { return }
        var targetPos: Double?
        if let pending = pendingSeekPosition {
            let current = player.position
            let elapsed = pendingSeekDate.map { Date().timeIntervalSince($0) } ?? pendingSeekTimeout
            if abs(current - pending) < 0.01 || elapsed > pendingSeekTimeout {
                pendingSeekPosition = nil
                pendingSeekDate = nil
                let pos = Double(current)
                if pos.isFinite { targetPos = max(0, min(1, pos)) }
            } else {
                targetPos = Double(pending)
            }
        } else {
            let pos = Double(player.position)
            if pos.isFinite { targetPos = max(0, min(1, pos)) }
        }
        if let targetPos, abs(targetPos - cachedScrubberValue) > 0.001 {
            cachedScrubberValue = targetPos
            scrubber.doubleValue = targetPos
        }
    }

    private func updateForImageMode() {
        let playSymbol = imageModeIsPlaying ? "pause.fill" : "play.fill"
        if playSymbol != cachedPlayPauseSymbol {
            cachedPlayPauseSymbol = playSymbol
            playPauseButton.configureSymbol(playSymbol,
                                            pointSize: 15,
                                            accessibilityLabel: "Play or Pause",
                                            help: "Play / Pause (Space)")
        }
        if !isScrubbing {
            let pos = imageModeDuration > 0 ? min(1.0, imageModeElapsed / imageModeDuration) : 0
            if abs(pos - cachedScrubberValue) > 0.001 {
                cachedScrubberValue = pos
                scrubber.doubleValue = pos
            }
        }
        setLabel(elapsedLabel, cached: &cachedElapsedText,
                 text: "\(formatImageTime(imageModeElapsed))  \(formatImageTime(imageModeDuration))")
        // remainingLabel is always hidden; combined time is shown in elapsedLabel
        rewindButton.isEnabled = false
        forwardButton.isEnabled = false
        playPauseButton.isEnabled = true
        prevButton.isEnabled = controller?.hasPrevious ?? false
        nextButton.isEnabled = controller?.hasNext ?? false
        queueButton.isEnabled = controller != nil
        queueButton.isToggled = controller?.isQueuePageOpen ?? false
        updateShuffleButtonState()
        repeatButton.isEnabled = true
        repeatButton.isToggled = controller?.isRepeatOne ?? false
        updatePrefixButtons()
        updateBookmarkButtonState()
    }

    private func updateShuffleButtonState() {
        let shuffleEnabled = (controller?.playbackSet.count ?? 0) > 1
        let shuffleOn = controller?.isShuffleOn ?? false
        let endlessOn = controller?.isEndlessShuffleOn ?? false
        shuffleButton.isEnabled = shuffleEnabled
        shuffleButton.isToggled = shuffleOn || endlessOn
        let help: String
        let label: String
        let symbol: String
        if endlessOn {
            help   = "Endless Shuffle on — click to turn off"
            label  = "Endless Shuffle"
            symbol = "arrow.triangle.2.circlepath"
        } else if shuffleOn {
            help   = "Shuffle on — click for Endless Shuffle"
            label  = "Shuffle"
            symbol = "shuffle"
        } else {
            help   = "Shuffle"
            label  = "Shuffle"
            symbol = "shuffle"
        }
        if shuffleButton.toolTip != help {
            shuffleButton.configureSymbol(symbol, pointSize: 11, accessibilityLabel: label, help: help)
        }
    }

    private func updatePrefixButtons() {
        let enabled = controller?.canRenameCurrentMedia == true
        dPrefixButton.isEnabled = enabled
        secondaryPrefixButton.isEnabled = enabled
    }

    private func setPlaybackButtonsEnabled(_ enabled: Bool) {
        [rewindButton, prevButton, playPauseButton, nextButton, forwardButton,
         volumeButton, shuffleButton, repeatButton, queueButton,
         dPrefixButton, secondaryPrefixButton].forEach { $0.isEnabled = enabled }
        queueButton.isEnabled = controller != nil
    }

    private func setLabel(_ label: NSTextField, cached: inout String?, text: String) {
        guard cached != text else { return }
        cached = text
        label.stringValue = text
    }

    private func skipSymbolName(isForward: Bool, seconds: Int) -> String {
        switch seconds {
        case 10:
            return isForward ? "goforward.10" : "gobackward.10"
        case 30:
            return isForward ? "goforward.30" : "gobackward.30"
        case 60:
            return isForward ? "goforward.60" : "gobackward.60"
        default:
            return isForward ? "goforward" : "gobackward"
        }
    }

    private func formatImageTime(_ seconds: Double) -> String {
        MediaFileSupport.formatShortDuration(max(0, Int(seconds)))
    }

    @objc private func queueTapped() { controller?.toggleQueuePage() }
    @objc private func dPrefixTapped() { controller?.performCustomPrefixRenameCurrentItem() }
    @objc private func secondaryPrefixTapped() { controller?.performSecondaryCustomPrefixRenameCurrentItem(source: "bottomRail-secondary") }
    @objc private func playPauseTapped() { controller?.togglePlayPause() }
    @objc private func prevTapped() { controller?.playPrevious() }
    @objc private func nextTapped() { controller?.playNext() }
    @objc private func rewindTapped() { controller?.skipBackward10() }
    @objc private func forwardTapped() { controller?.skipForward10() }
    @objc private func shuffleTapped() { controller?.toggleShuffle() }
    @objc private func repeatTapped() { controller?.toggleRepeat() }
    @objc private func bookmarkTapped() { controller?.toggleBookmark() }
    @objc private func settingsTapped() { SettingsWindowController.shared.openSettings() }
    @objc private func fullscreenTapped() { window?.toggleFullScreen(nil) }

    private var moreMenuPopover: NSPopover?

    @objc private func moreTapped() {
        if let existing = moreMenuPopover, existing.isShown {
            existing.performClose(nil)
            moreMenuPopover = nil
            return
        }

        let shuffleEnabled = (controller?.playbackSet.count ?? 0) > 1
        let shuffleOn = (controller?.isShuffleOn ?? false) || (controller?.isEndlessShuffleOn ?? false)
        let renameEnabled = controller?.canRenameCurrentMedia == true
        let hasItem = controller?.currentMediaURL != nil
        let isBookmarked = controller?.isCurrentItemBookmarked ?? false
        let isRepeat = controller?.isRepeatOne ?? false

        let primary = SettingsWindowController.customPrefixValue()
        let secondary = SettingsWindowController.customPrefixSecondaryValue()
        let showPrefixButtons = SettingsWindowController.isBottomRailShowXEnabled()
        let hasPrimary = BottomRailView.hasConfiguredPrefix(primary)
        let hasDistinctSecondary = BottomRailView.hasDistinctSecondaryPrefix(primary: primary, secondary: secondary)

        // Show each action in More when its dedicated rail button is hidden,
        // whether from Settings being off or narrow-width responsive hiding.
        // Controls that are visible on the bar are not duplicated here.
        // Secondary prefix follows the same More fallback when configured and distinct.
        var items: [MoreMenuItem] = []
        if hasPrimary && (dPrefixButton.isHidden || !showPrefixButtons) {
            let primaryTitle = BottomRailView.railPrefixLabel(primary)
            items.append(MoreMenuItem(title: primaryTitle, action: .customPrefix, isOn: false, isEnabled: renameEnabled))
        }
        if hasDistinctSecondary && (secondaryPrefixButton.isHidden || !showPrefixButtons) {
            let secondaryTitle = BottomRailView.railPrefixLabel(secondary)
            items.append(MoreMenuItem(title: secondaryTitle, action: .customPrefixSecondary, isOn: false, isEnabled: renameEnabled))
        }
        if shuffleButton.isHidden {
            items.append(MoreMenuItem(title: "Shuffle",  action: .shuffle,      isOn: shuffleOn,    isEnabled: shuffleEnabled))
        }
        if repeatButton.isHidden {
            items.append(MoreMenuItem(title: "Replay",   action: .replay,       isOn: isRepeat,     isEnabled: true))
        }
        if bookmarkButton.isHidden {
            items.append(MoreMenuItem(title: "Bookmark", action: .bookmark,     isOn: isBookmarked, isEnabled: hasItem))
        }
        // Settings is always present in the More menu and always last so it
        // stays reachable even when every dedicated button is visible.
        items.append(MoreMenuItem(title: "Settings",     action: .settings,     isOn: false,        isEnabled: true))

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        let content = MoreMenuViewController(items: items)
        content.onSelect = { [weak self, weak popover] action in
            popover?.performClose(nil)
            guard let self else { return }
            switch action {
            case .customPrefix:          self.controller?.performCustomPrefixRenameCurrentItem()
            case .customPrefixSecondary: self.controller?.performSecondaryCustomPrefixRenameCurrentItem(source: "bottomRail-more")
            case .shuffle:               self.controller?.toggleShuffle()
            case .replay:                self.controller?.toggleRepeat()
            case .bookmark:              self.controller?.toggleBookmark()
            case .settings:              SettingsWindowController.shared.openSettings()
            }
        }
        popover.contentViewController = content
        moreMenuPopover = popover
        popover.show(relativeTo: moreButton.bounds, of: moreButton, preferredEdge: .maxY)
    }


    @objc private func scrubberMoved(_ sender: NSSlider) {
        guard !isImageMode else { return }
        let raw = Float(sender.doubleValue)
        let pos = controller?.clampedUserSeekPosition(raw, source: "rail-scrubber-move")
            ?? max(0, min(0.985, raw))
        if abs(Double(pos) - sender.doubleValue) > 0.0005 {
            sender.doubleValue = Double(pos)
        }
        player?.position = pos
        notifySeek(to: pos)
    }

    @objc private func volumeTapped() {
        controller?.toggleMuteFromTransport()
        cachedVolumeSymbol = nil
        update()
    }
}

// MARK: - More menu (popover)

fileprivate enum MoreMenuAction {
    case customPrefix, customPrefixSecondary, shuffle, replay, bookmark, settings
}

fileprivate struct MoreMenuItem {
    let title: String
    let action: MoreMenuAction
    let isOn: Bool
    let isEnabled: Bool
}

/// Lightweight popover content that mirrors the rail's dark/translucent chrome so the
/// More menu reads as an extension of the playback bar rather than a stock system menu.
fileprivate final class MoreMenuViewController: NSViewController {
    private let items: [MoreMenuItem]
    var onSelect: ((MoreMenuAction) -> Void)?

    init(items: [MoreMenuItem]) {
        self.items = items
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("programmatic only") }

    override func loadView() {
        let rowH: CGFloat = 28
        let topPad: CGFloat = 6
        let botPad: CGFloat = 6
        let width: CGFloat = 168
        let height = rowH * CGFloat(items.count) + topPad + botPad

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor

        // Subtle dark wash on top of the popover's native vibrant chrome so the
        // background matches the rail veil's translucency.
        let darken = NSView(frame: root.bounds)
        darken.wantsLayer = true
        darken.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        darken.autoresizingMask = [.width, .height]
        root.addSubview(darken)

        for (i, item) in items.enumerated() {
            let rowY = height - topPad - CGFloat(i + 1) * rowH
            let row = MoreMenuRowView(title: item.title, showCheck: item.isOn, enabled: item.isEnabled)
            row.frame = NSRect(x: 0, y: rowY, width: width, height: rowH)
            row.autoresizingMask = [.width]
            row.onClick = { [weak self] in self?.onSelect?(item.action) }
            root.addSubview(row)
        }

        preferredContentSize = NSSize(width: width, height: height)
        view = root
    }
}

fileprivate final class MoreMenuRowView: NSView {
    private let titleText: String
    private let showCheck: Bool
    private let enabledRow: Bool
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?

    init(title: String, showCheck: Bool, enabled: Bool) {
        self.titleText = title
        self.showCheck = showCheck
        self.enabledRow = enabled
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError("programmatic only") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard enabledRow else { return }
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    override func mouseDown(with event: NSEvent) {
        guard enabledRow else { return }
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = enabledRow
            ? NSColor.white.withAlphaComponent(0.94)
            : NSColor.white.withAlphaComponent(0.38)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let titleStr = titleText as NSString
        let titleSize = titleStr.size(withAttributes: attrs)
        let titleY = (bounds.height - titleSize.height) / 2
        titleStr.draw(at: NSPoint(x: 14, y: titleY), withAttributes: attrs)
        if showCheck {
            let check = "✓" as NSString
            let cSize = check.size(withAttributes: attrs)
            let cX = bounds.width - 14 - cSize.width
            let cY = (bounds.height - cSize.height) / 2
            check.draw(at: NSPoint(x: cX, y: cY), withAttributes: attrs)
        }
    }
}

// MARK: - Top-aligned knobless slider cell

/// Variant of the legacy KnoblessSliderCell that draws the track and progress
/// fill flush with the absolute top pixel of the slider control (the scrubber
/// frame's max-Y). The system-provided `rect` in drawBar(inside:flipped:) may
/// be vertically inset, so this cell ignores the rect's vertical position and
/// instead calculates barY from `controlView.bounds` to guarantee the bar
/// touches the very top edge of the slider frame. The BottomRailView positions
/// the scrubber so its top edge aligns with the rail veil's top edge, making
/// the visible scrubber bar literally the topmost visible pixel of the shaded
/// playback control bar. Click-to-seek and drag-to-seek remain functional
/// because the slider frame is the full hit-test area.
fileprivate final class TopAlignedKnoblessSliderCell: NSSliderCell {
    override var focusRingType: NSFocusRingType {
        get { return .none }
        set {}
    }

    override func drawKnob(_ knobRect: NSRect) {}

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let h: CGFloat = 3
        // Use the control view's full bounds to avoid any system inset that
        // would leave a visible shaded strip above the scrubber bar.
        let fullRect = controlView?.bounds ?? rect
        let barY: CGFloat
        if flipped {
            barY = fullRect.minY
        } else {
            barY = fullRect.maxY - h
        }
        let barRect = NSRect(x: fullRect.minX, y: barY, width: fullRect.width, height: h)

        NSColor.white.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 1, yRadius: 1).fill()

        let range = maxValue - minValue
        if range > 0 {
            let frac    = CGFloat((doubleValue - minValue) / range)
            let filledW = max(0, barRect.width * frac)
            let filled  = NSRect(x: barRect.minX, y: barRect.minY,
                                 width: filledW,  height: barRect.height)
            NSColor.white.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: filled, xRadius: 1, yRadius: 1).fill()
        }
    }
}
