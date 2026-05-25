import Cocoa
import VLCKitSPM

final class BottomRailView: NSView {
    weak var player: VLCMediaPlayer?
    weak var controller: PlayerWindowController?

    var scrubDidBegin: (() -> Void)?
    var scrubDidEnd: (() -> Void)?

    private let veil = NSView()
    private let queueButton = RailButton()
    private let xPrefixButton = RailButton()
    private let dPrefixButton = RailButton()
    private let rewindButton = RailButton()
    private let prevButton = RailButton()
    private let playPauseButton = RailButton()
    private let nextButton = RailButton()
    private let forwardButton = RailButton()
    private let volumeButton = RailButton()
    private let shuffleButton = RailButton()
    private let repeatButton = RailButton()
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
    }

    required init?(coder: NSCoder) {
        fatalError("programmatic only")
    }

    func applyVisibilitySettings() {
        xPrefixButton.isHidden = !SettingsWindowController.isVideoPageXButtonEnabled()
        dPrefixButton.isHidden = !SettingsWindowController.isCustomPrefixVideoPageEnabled()
        applySkipDurationSettings()
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
            return
        }

        let hasMedia = player.media != nil
        let playSymbol = player.isPlaying ? "pause.fill" : "play.fill"
        if playSymbol != cachedPlayPauseSymbol {
            cachedPlayPauseSymbol = playSymbol
            playPauseButton.configureSymbol(playSymbol,
                                            pointSize: 15,
                                            accessibilityLabel: "Play or Pause",
                                            help: "Play / Pause")
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

        let hasSet = !(controller?.playbackSet.isEmpty ?? true)
        queueButton.isEnabled = hasSet
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
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        // Rail is 2pt taller than before to give room for the centered time label row.
        let railH: CGFloat = isFullscreenStyle ? 80 : 84
        let scrubH: CGFloat = 14
        let sidePad: CGFloat = w < 520 ? 12 : (isFullscreenStyle ? 16 : 20)
        let buttonSize: CGFloat = w < 440 ? 28 : 30
        let playSize: CGFloat = w < 440 ? 38 : 40
        let gap: CGFloat = w < 520 ? 6 : 8

        // Time label row sits between scrubber and button row.
        let timeLabelH: CGFloat = 14
        let timeLabelY: CGFloat = scrubH + 3    // 3 pt gap above scrubber top edge
        let buttonAreaBottom: CGFloat = timeLabelY + timeLabelH + 6  // 6 pt gap above time label
        let topSpace: CGFloat = railH - buttonAreaBottom
        let rowY: CGFloat = buttonAreaBottom + max(0, topSpace - buttonSize) / 2
        let playY: CGFloat = buttonAreaBottom + max(0, topSpace - playSize) / 2

        veil.frame = NSRect(x: 0, y: 0, width: w, height: railH)
        if isFullscreenStyle {
            veil.layer?.cornerRadius = 0
        } else {
            veil.layer?.cornerRadius = 8
            veil.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
        veil.layer?.backgroundColor = NSColor.black.withAlphaComponent(isFullscreenStyle ? 0.22 : 0.36).cgColor
        scrubber.frame = NSRect(x: 0, y: 0, width: w, height: scrubH)

        applyResponsiveVisibility(width: w)

        var leftX = sidePad
        for button in [queueButton, xPrefixButton, dPrefixButton] where !button.isHidden {
            place(button, x: leftX, y: rowY, size: buttonSize)
            leftX += buttonSize + gap
        }

        let center: [(RailButton, CGFloat)] = [
            (rewindButton, buttonSize),
            (prevButton, buttonSize),
            (playPauseButton, playSize),
            (nextButton, buttonSize),
            (forwardButton, buttonSize)
        ]
        let centerWidth = center.reduce(CGFloat(0)) { $0 + $1.1 } + CGFloat(center.count - 1) * gap
        let centerGroupLeft = max(leftX + gap, (w - centerWidth) / 2)
        var centerX = centerGroupLeft
        for (button, size) in center {
            place(button, x: centerX, y: size == playSize ? playY : rowY, size: size)
            centerX += size + gap
        }
        let centerGroupCenterX = centerGroupLeft + centerWidth / 2

        var rightX = w - sidePad - buttonSize
        for button in [fullscreenButton, repeatButton, shuffleButton, volumeButton] where !button.isHidden {
            place(button, x: rightX, y: rowY, size: buttonSize)
            rightX -= buttonSize + gap
        }

        // Time label centered with the central transport group, above the scrubber.
        let timeLabelW: CGFloat = 130
        let timeLabelX = max(sidePad, min(w - sidePad - timeLabelW,
                                          centerGroupCenterX - timeLabelW / 2))
        elapsedLabel.frame = NSRect(x: timeLabelX, y: timeLabelY, width: timeLabelW, height: timeLabelH)
        remainingLabel.frame = .zero   // combined time shown in elapsedLabel
    }

    private func applyResponsiveVisibility(width: CGFloat) {
        xPrefixButton.isHidden = !SettingsWindowController.isVideoPageXButtonEnabled() || width < 500
        dPrefixButton.isHidden = !SettingsWindowController.isCustomPrefixVideoPageEnabled() || width < 560
        elapsedLabel.isHidden = width < 640
        remainingLabel.isHidden = true   // combined time shown in elapsedLabel; always hidden
        shuffleButton.isHidden = width < 430
        repeatButton.isHidden = width < 390
        volumeButton.isHidden = width < 360
    }

    private func setupViews() {
        veil.wantsLayer = true
        addSubview(veil)

        configure(queueButton, symbol: "square.split.2x1", label: "Toggle Queue Page", help: "Toggle Queue Page", action: #selector(queueTapped), style: .utility, size: 11)
        configure(xPrefixButton, symbol: nil, label: "Add x_ Prefix", help: "Rename: add x_ prefix", action: #selector(xPrefixTapped), style: .warning, title: "x_")
        configure(dPrefixButton, symbol: "tag", label: "Apply Custom Prefix", help: "Rename: apply custom prefix", action: #selector(dPrefixTapped), style: .utility, size: 11)
        configure(rewindButton, symbol: "gobackward.10", label: "Rewind", help: "Rewind", action: #selector(rewindTapped), size: 13)
        configure(prevButton, symbol: "backward.end.fill", label: "Previous File", help: "Previous file", action: #selector(prevTapped), size: 11)
        configure(playPauseButton, symbol: "play.fill", label: "Play or Pause", help: "Play / Pause", action: #selector(playPauseTapped), style: .emphasized, size: 15)
        configure(nextButton, symbol: "forward.end.fill", label: "Next File", help: "Next file", action: #selector(nextTapped), size: 11)
        configure(forwardButton, symbol: "goforward.10", label: "Skip Forward", help: "Skip Forward", action: #selector(forwardTapped), size: 13)
        configure(volumeButton, symbol: "speaker.wave.2.fill", label: "Mute or Unmute", help: "Mute / Unmute", action: #selector(volumeTapped), size: 12)
        configure(shuffleButton, symbol: "shuffle", label: "Shuffle", help: "Shuffle", action: #selector(shuffleTapped), size: 11)
        configure(repeatButton, symbol: "repeat", label: "Repeat Current File", help: "Repeat current file", action: #selector(repeatTapped), size: 11)
        configure(fullscreenButton, symbol: "arrow.up.left.and.arrow.down.right", label: "Toggle Fullscreen", help: "Toggle Fullscreen", action: #selector(fullscreenTapped), size: 11)

        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = NSColor.white.withAlphaComponent(0.65)
            label.drawsBackground = false
            label.alignment = .center
            addSubview(label)
        }
        elapsedLabel.setAccessibilityLabel("Playback time")

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
                                            help: "Play / Pause")
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
        queueButton.isEnabled = !(controller?.playbackSet.isEmpty ?? true)
        queueButton.isToggled = controller?.isQueuePageOpen ?? false
        updateShuffleButtonState()
        repeatButton.isEnabled = true
        repeatButton.isToggled = controller?.isRepeatOne ?? false
        updatePrefixButtons()
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
        xPrefixButton.isEnabled = enabled
        dPrefixButton.isEnabled = enabled
    }

    private func setPlaybackButtonsEnabled(_ enabled: Bool) {
        [rewindButton, prevButton, playPauseButton, nextButton, forwardButton,
         volumeButton, shuffleButton, repeatButton, queueButton].forEach { $0.isEnabled = enabled }
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
    @objc private func xPrefixTapped() { controller?.performXPrefixRenameCurrentItem() }
    @objc private func dPrefixTapped() { controller?.performCustomPrefixRenameCurrentItem() }
    @objc private func playPauseTapped() { controller?.togglePlayPause() }
    @objc private func prevTapped() { controller?.playPrevious() }
    @objc private func nextTapped() { controller?.playNext() }
    @objc private func rewindTapped() { controller?.skipBackward10() }
    @objc private func forwardTapped() { controller?.skipForward10() }
    @objc private func shuffleTapped() { controller?.toggleShuffle() }
    @objc private func repeatTapped() { controller?.toggleRepeat() }
    @objc private func fullscreenTapped() { window?.toggleFullScreen(nil) }

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
