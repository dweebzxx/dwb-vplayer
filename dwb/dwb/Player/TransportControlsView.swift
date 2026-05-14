import Cocoa
import VLCKitSPM

/// Shared cinematic transport overlay used in both windowed and fullscreen presentations.
///
/// Layout:
///   Bottom edge: full-width knobless timeline with centered time label.
///   Lower third: frosted center pod with transport buttons.
///   Bottom corners: Queue Page on the left, fullscreen on the right.
///
/// Always-visible controls: queuePageButton, rewind, prev, play/pause, next, forward,
/// fullscreen, and the scrubber.
///
/// Optional controls (default hidden; toggled from Settings > Optional Controls):
///   stop, volume, shuffle, repeat.
///
/// performLayout() skips space for hidden buttons, so the streamlined default set
/// stays compact without gaps.
final class TransportControlsView: NSView {

    weak var player: VLCMediaPlayer? {
        didSet { bottomRail.player = player }
    }
    weak var controller: PlayerWindowController? {
        didSet { bottomRail.controller = controller }
    }

    // MARK: - Subviews

    private let effectView      = DraggableVisualEffectView()
    private let separator       = NSView()
    private let bottomRail      = BottomRailView()

    // Always-visible left cluster (order matches the on-screen left→right arrangement)
    private let xPrefixVideoPageButton = NSButton()   // above queuePageButton when enabled
    private let dPrefixVideoPageButton = NSButton()   // above xPrefixVideoPageButton when enabled
    private let queuePageButton = NSButton()   // leftmost: Queue Page toggle
    private let prevButton      = NSButton()
    private let rewindButton    = NSButton()
    private let playPauseButton = NSButton()
    private let forwardButton   = NSButton()
    private let nextButton      = NSButton()

    // Optional controls — hidden by default; shown when Settings enables them
    private let stopButton      = NSButton()
    private let shuffleButton   = NSButton()
    private let repeatButton    = NSButton()

    // Time / scrubber
    private let elapsedLabel    = NSTextField(labelWithString: "–:––")
    private let scrubber        = ScrubberSlider()
    private let remainingLabel  = NSTextField(labelWithString: "–:––")

    // Right cluster
    private let volumeButton     = NSButton()   // optional
    private let fullscreenButton = NSButton()   // always visible, rightmost

    // MARK: - State

    private var preMuteVolume: Int32 = 100
    /// Read by PlayerWindowController.logLayoutSnapshot for verification logging.
    private(set) var isFullscreenStyle = false
    /// True while the user is pressing or dragging the scrubber.
    private var isScrubbing = false
    private var useUnifiedBottomRail = UserDefaults.standard.bool(forKey: SettingsWindowController.useUnifiedBottomRailKey)
    private var railAutohideStarted = false
    private var railVisibilityGeneration = 0
    private lazy var railAutohideController = IdleAutohideController(
        threshold: UserDefaults.standard.double(forKey: SettingsWindowController.chromeAutohideThresholdKey),
        reduceMotion: UserDefaults.standard.bool(forKey: SettingsWindowController.chromeReducedMotionKey),
        visibilityHoldProvider: { [weak self] in
            guard let self = self else { return false }
            if self.isScrubbing { return true }
            if self.isImageMode { return !self.imageModeIsPlaying }
            return self.player?.isPlaying == false
        },
        visibilityHandler: { [weak self] visible, animated in
            self?.setBottomRailVisible(visible, animated: animated)
        }
    )

    var isUsingUnifiedBottomRail: Bool { useUnifiedBottomRail }

    // MARK: - Image mode state (set by PlayerWindowController for slideshow items)
    var isImageMode: Bool = false {
        didSet { bottomRail.isImageMode = isImageMode }
    }
    var imageModeElapsed: Double = 0 {
        didSet { bottomRail.imageModeElapsed = imageModeElapsed }
    }
    var imageModeDuration: Double = 3 {
        didSet { bottomRail.imageModeDuration = imageModeDuration }
    }
    var imageModeIsPlaying: Bool = true {
        didSet { bottomRail.imageModeIsPlaying = imageModeIsPlaying }
    }

    // H2: cached display state — prevents redundant UI mutations in update()
    private var _cachedPlayPauseSymbol: String? = nil
    private var _cachedVolumeSymbol:    String? = nil
    private var _cachedRepeatSymbol:    String? = nil
    private var _cachedElapsedText:     String? = nil
    private var _cachedScrubberValue:   Double  = -1.0
    // H2: NSImage.SymbolConfiguration instances keyed by point size (weight is always .medium)
    private var _symbolConfigCache:     [CGFloat: NSImage.SymbolConfiguration] = [:]

    /// Pending seek position — suppresses timer-driven snap-back after a seek is issued.
    private var pendingSeekPosition: Float? = nil
    private var pendingSeekDate:     Date?  = nil
    private let pendingSeekTimeout: TimeInterval = 1.5
    private enum ControlPodPlacementMode: String, CaseIterable {
        case windowed
        case fullscreen

        var xDefaultsKey: String { "controlPodAnchorX.\(rawValue)" }
        var yDefaultsKey: String { "controlPodAnchorY.\(rawValue)" }
    }
    private var controlPodAnchors: [ControlPodPlacementMode: CGPoint] = [:]
    private var lastDisplayedPodAnchor: CGPoint?
    private var currentPodFrame: NSRect = .zero
    private var dragStartAnchor: CGPoint?

    // MARK: - Control pod scale

    /// Scale factor applied uniformly to pod geometry and corner-button sizes.
    /// Default (smallest) = 1.0; max = 1.6; step = 0.2.
    private(set) var controlPodScale: CGFloat = 1.0

    private static let podScaleKey:  String  = "controlPodScale"
    private static let podScaleMin:  CGFloat = 1.0
    private static let podScaleMax:  CGFloat = 1.6
    private static let podScaleStep: CGFloat = 0.2

    private let podShrinkButton = NSButton()
    private let podGrowButton   = NSButton()

    // MARK: - Init / deinit

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupViews() {
        restorePersistedControlPodAnchors()
        loadPersistedPodScale()

        effectView.material       = .hudWindow
        effectView.blendingMode   = .withinWindow
        effectView.state          = .active
        effectView.alphaValue     = 0.72   // M2: windowed default; initialized so setFullscreenStyle can early-return on first call
        effectView.wantsLayer     = true
        effectView.layer?.masksToBounds = true
        effectView.dragDidBegin = { [weak self] in
            guard let self = self else { return }
            self.dragStartAnchor = self.lastDisplayedPodAnchor ?? self.normalizedAnchor(for: self.currentPodFrame)
        }
        effectView.dragDidMove = { [weak self] delta in
            guard let self = self,
                  let dragStartAnchor = self.dragStartAnchor,
                  self.bounds.width > 1,
                  self.bounds.height > 1 else { return }
            let startCenter = NSPoint(x: dragStartAnchor.x * self.bounds.width,
                                      y: dragStartAnchor.y * self.bounds.height)
            let movedCenter = NSPoint(x: startCenter.x + delta.x,
                                      y: startCenter.y + delta.y)
            let movedAnchor = CGPoint(x: movedCenter.x / self.bounds.width,
                                      y: movedCenter.y / self.bounds.height)
            self.setControlPodAnchor(movedAnchor,
                                     for: self.currentControlPodPlacementMode(),
                                     persist: true)
            self.needsLayout = true
        }
        addSubview(effectView)

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        separator.isHidden = true
        addSubview(separator)

        bottomRail.player = player
        bottomRail.controller = controller
        bottomRail.isHidden = true
        bottomRail.alphaValue = 1.0
        bottomRail.scrubDidBegin = { [weak self] in
            self?.isScrubbing = true
            self?.railAutohideController.beginSuspension(reveal: true)
        }
        bottomRail.scrubDidEnd = { [weak self] in
            guard let self = self else { return }
            self.isScrubbing = false
            self.railAutohideController.endSuspension()
        }
        addSubview(bottomRail)

        // Always-visible left cluster
        makeButton(queuePageButton, symbol: "square.split.2x1",                   size: 11, action: #selector(queuePageTapped))
        queuePageButton.toolTip = "Toggle Queue Page"

        makeButton(prevButton,      symbol: "backward.end.fill",                   size: 11, action: #selector(prevTapped))
        prevButton.toolTip = "Previous file"

        makeButton(rewindButton,    symbol: "gobackward.10",                       size: 13, action: #selector(rewindTapped))

        makeButton(playPauseButton, symbol: "play.fill",                           size: 14, action: #selector(playPauseTapped))
        playPauseButton.toolTip = "Play / Pause"

        makeButton(forwardButton,   symbol: "goforward.10",                        size: 13, action: #selector(forwardTapped))

        makeButton(nextButton,      symbol: "forward.end.fill",                    size: 11, action: #selector(nextTapped))
        nextButton.toolTip = "Next file"

        // Optional controls
        makeButton(stopButton,      symbol: "stop.fill",                           size: 13, action: #selector(stopTapped))
        stopButton.toolTip = "Stop and open Queue Page"

        makeButton(shuffleButton,   symbol: "shuffle",                             size: 11, action: #selector(shuffleTapped))
        shuffleButton.toolTip = "Shuffle"

        makeButton(repeatButton,    symbol: "repeat",                              size: 11, action: #selector(repeatTapped))
        repeatButton.toolTip = "Repeat current file"

        // Time labels
        for label in [elapsedLabel, remainingLabel] {
            label.font            = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor       = NSColor.white.withAlphaComponent(0.80)
            label.drawsBackground = false
            addSubview(label)
        }
        elapsedLabel.alignment   = .center
        remainingLabel.isHidden  = true

        // Scrubber
        scrubber.minValue    = 0
        scrubber.maxValue    = 1
        scrubber.doubleValue = 0
        scrubber.isContinuous = true
        scrubber.target      = self
        scrubber.action      = #selector(scrubberMoved(_:))
        scrubber.scrubDidBegin = { [weak self] in
            self?.pendingSeekPosition = nil
            self?.pendingSeekDate     = nil
            self?.isScrubbing         = true
            // Mark seek start so the .stopped handler knows position signals may reflect
            // a seek target rather than natural EOF for the next 1.5 s.
            if self?.isImageMode != true {
                self?.controller?.notifyUserSeek(source: "scrub-begin")
            }
        }
        scrubber.scrubDidEnd = { [weak self] in
            guard let self = self else { return }
            self.isScrubbing = false
            guard !self.isImageMode else { return }
            let raw = Float(self.scrubber.doubleValue)
            let pos = self.controller?.clampedUserSeekPosition(raw, source: "scrub-end")
                ?? max(0, min(0.985, raw))
            self.scrubber.doubleValue = Double(pos)
            self.controller?.notifyUserSeek(targetPosition: pos, source: "scrub-end")
            self.player?.position = pos
            self.notifySeek(to: pos)
        }
        addSubview(scrubber)

        // Right cluster: optional volume + always-visible fullscreen
        makeButton(volumeButton,     symbol: "speaker.wave.2.fill",                size: 12, action: #selector(volumeTapped))
        volumeButton.toolTip = "Mute / Unmute"

        makeButton(fullscreenButton, symbol: "arrow.up.left.and.arrow.down.right", size: 11, action: #selector(fullscreenTapped))
        fullscreenButton.toolTip = "Toggle Fullscreen"

        // Pod scale buttons — small +/- pair centered in the bottom bar.
        makeButton(podShrinkButton, symbol: "minus", size: 7, action: #selector(podShrinkTapped))
        podShrinkButton.toolTip = "Decrease control pod size"
        makeButton(podGrowButton,   symbol: "plus",  size: 7, action: #selector(podGrowTapped))
        podGrowButton.toolTip = "Increase control pod size"

        // x_ rename button — shown above queue button when setting is ON
        xPrefixVideoPageButton.isBordered   = false
        xPrefixVideoPageButton.bezelStyle   = .regularSquare
        xPrefixVideoPageButton.imageScaling = .scaleProportionallyDown
        xPrefixVideoPageButton.target       = self
        xPrefixVideoPageButton.action       = #selector(xPrefixVideoPageTapped)
        xPrefixVideoPageButton.wantsLayer   = true
        xPrefixVideoPageButton.layer?.backgroundColor = NSColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 0.20).cgColor
        xPrefixVideoPageButton.layer?.borderWidth     = 1
        xPrefixVideoPageButton.layer?.borderColor     = NSColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 0.30).cgColor
        xPrefixVideoPageButton.contentTintColor       = NSColor(red: 1.0, green: 0.75, blue: 0.3, alpha: 0.92)
        xPrefixVideoPageButton.toolTip = "Rename: add x_ prefix"
        xPrefixVideoPageButton.font    = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        xPrefixVideoPageButton.title   = "x_"
        xPrefixVideoPageButton.isHidden = true
        addSubview(xPrefixVideoPageButton)

        // Custom prefix rename button — shown above x_ button (or queue button) when setting is ON
        dPrefixVideoPageButton.isBordered   = false
        dPrefixVideoPageButton.bezelStyle   = .regularSquare
        dPrefixVideoPageButton.imageScaling = .scaleProportionallyDown
        dPrefixVideoPageButton.target       = self
        dPrefixVideoPageButton.action       = #selector(dPrefixVideoPageTapped)
        dPrefixVideoPageButton.wantsLayer   = true
        dPrefixVideoPageButton.layer?.backgroundColor = NSColor(red: 0.0, green: 0.45, blue: 1.0, alpha: 0.20).cgColor
        dPrefixVideoPageButton.layer?.borderWidth     = 1
        dPrefixVideoPageButton.layer?.borderColor     = NSColor(red: 0.0, green: 0.45, blue: 1.0, alpha: 0.30).cgColor
        dPrefixVideoPageButton.contentTintColor       = NSColor(red: 0.4, green: 0.75, blue: 1.0, alpha: 0.92)
        dPrefixVideoPageButton.toolTip = "Rename: apply custom prefix"
        dPrefixVideoPageButton.setAccessibilityLabel("Apply custom prefix to current file")
        let tagSymCfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        if let tagImg = NSImage(systemSymbolName: "tag", accessibilityDescription: "Apply custom prefix") {
            dPrefixVideoPageButton.image = tagImg.withSymbolConfiguration(tagSymCfg) ?? tagImg
        }
        dPrefixVideoPageButton.isHidden = true
        addSubview(dPrefixVideoPageButton)

        // Apply initial visibility from UserDefaults (all optional controls default hidden)
        applyVisibilitySettings()
        applySkipDurationSettings()
        setVideoPageXButtonVisible(SettingsWindowController.isVideoPageXButtonEnabled())
        setVideoPageDButtonVisible(SettingsWindowController.isCustomPrefixVideoPageEnabled())
        refreshUnifiedBottomRailMode()

        // Live-update when Settings changes optional-control visibility
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVisibilityChange),
            name: .transportVisibilityChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSkipDurationChange),
            name: .skipDurationChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVideoPageXButtonSettingChange),
            name: .videoPageXButtonSettingChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVideoPageDButtonSettingChange),
            name: .videoPageCustomPrefixButtonSettingChanged,
            object: nil
        )
    }

    func setVideoPageXButtonVisible(_ visible: Bool) {
        xPrefixVideoPageButton.isHidden = !visible
        bottomRail.applyVisibilitySettings()
        needsLayout = true
    }

    @objc private func handleVideoPageXButtonSettingChange() {
        setVideoPageXButtonVisible(SettingsWindowController.isVideoPageXButtonEnabled())
    }

    @objc private func xPrefixVideoPageTapped() {
        controller?.performXPrefixRenameCurrentItem()
    }

    func setVideoPageDButtonVisible(_ visible: Bool) {
        dPrefixVideoPageButton.isHidden = !visible
        bottomRail.applyVisibilitySettings()
        needsLayout = true
    }

    @objc private func handleVideoPageDButtonSettingChange() {
        setVideoPageDButtonVisible(SettingsWindowController.isCustomPrefixVideoPageEnabled())
    }

    @objc private func dPrefixVideoPageTapped() {
        controller?.performCustomPrefixRenameCurrentItem()
    }

    // MARK: - Visibility settings

    /// Apply optional-control visibility from UserDefaults.
    /// Call this on init and whenever transportVisibilityChanged is posted.
    func applyVisibilitySettings() {
        refreshUnifiedBottomRailMode()
        stopButton.isHidden = !SettingsWindowController.isOptionalTransportControlVisible(.stop)
        volumeButton.isHidden = !SettingsWindowController.isOptionalTransportControlVisible(.volume)
        shuffleButton.isHidden = !SettingsWindowController.isOptionalTransportControlVisible(.shuffle)
        repeatButton.isHidden = !SettingsWindowController.isOptionalTransportControlVisible(.repeatOne)
        bottomRail.applyVisibilitySettings()
        invalidateCachedDisplayState()
        needsLayout = true
    }

    @objc private func handleVisibilityChange() {
        applyVisibilitySettings()
    }

    func applySkipDurationSettings() {
        let seconds = SettingsWindowController.currentSkipDurationSeconds()
        let rewindTitle = SettingsWindowController.skipActionTitle(isForward: false, seconds: seconds)
        let forwardTitle = SettingsWindowController.skipActionTitle(isForward: true, seconds: seconds)
        rewindButton.toolTip = rewindTitle
        forwardButton.toolTip = forwardTitle
        applySymbol(rewindButton,
                    skipSymbolName(isForward: false, seconds: seconds),
                    fallbackNames: ["gobackward"],
                    pointSize: 13,
                    accessibilityDescription: rewindTitle)
        applySymbol(forwardButton,
                    skipSymbolName(isForward: true, seconds: seconds),
                    fallbackNames: ["goforward"],
                    pointSize: 13,
                    accessibilityDescription: forwardTitle)
        bottomRail.applySkipDurationSettings()
    }

    @objc private func handleSkipDurationChange() {
        applySkipDurationSettings()
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

    private func makeButton(_ button: NSButton, symbol: String, size: CGFloat, action: Selector?) {
        button.isBordered   = false
        button.bezelStyle   = .regularSquare
        button.imageScaling = .scaleProportionallyDown
        button.target       = self
        button.action       = action
        button.wantsLayer   = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor
        button.layer?.borderWidth     = 1
        button.layer?.borderColor     = NSColor.white.withAlphaComponent(0.12).cgColor
        button.contentTintColor       = NSColor.white.withAlphaComponent(0.90)
        applySymbol(button, symbol, pointSize: size)
        addSubview(button)
    }

    // MARK: - Mode configuration

    /// Toggle the NSVisualEffectView backdrop sampling to match visible state.
    /// Call with `false` after the view is fully hidden to stop backdrop blur work,
    /// and with `true` before un-hiding so the effect is live when it becomes visible.
    func setBackdropActive(_ active: Bool) {
        guard !useUnifiedBottomRail else { return }
        effectView.state = active ? .active : .inactive
    }

    /// Clears all H2 cached display values so the next update() performs a full refresh.
    /// Call before media replacement, player rebuild, or settings changes that affect content.
    func invalidateCachedDisplayState() {
        _cachedPlayPauseSymbol = nil
        _cachedVolumeSymbol    = nil
        _cachedRepeatSymbol    = nil
        _cachedElapsedText     = nil
        _cachedScrubberValue   = -1.0
        bottomRail.invalidateCachedDisplayState()
    }

    func setFullscreenStyle(_ fullscreen: Bool) {
        // M2: skip redundant symbol/alpha/layout work when style is already current.
        guard isFullscreenStyle != fullscreen else { return }
        isFullscreenStyle = fullscreen
        bottomRail.setFullscreenStyle(fullscreen)
        separator.isHidden = true
        effectView.alphaValue = fullscreen ? 0.60 : 0.72
        applySymbol(fullscreenButton,
                    fullscreen ? "arrow.down.right.and.arrow.up.left"
                               : "arrow.up.left.and.arrow.down.right",
                    pointSize: fullscreen ? 10 : 11)
        needsLayout = true
    }

    func noteChromeActivity() {
        guard useUnifiedBottomRail else { return }
        railAutohideController.noteMouseMoved()
    }

    func showChromeFromHost(animated: Bool) {
        guard useUnifiedBottomRail else { return }
        setBottomRailVisible(true, animated: animated && !railAutohideController.reduceMotion)
    }

    func scheduleChromeHideFromHost() {
        guard useUnifiedBottomRail else { return }
        railAutohideController.noteMouseMoved()
    }

    private func refreshUnifiedBottomRailMode() {
        let next = UserDefaults.standard.bool(forKey: SettingsWindowController.useUnifiedBottomRailKey)
        useUnifiedBottomRail = next
        configureSubviewVisibilityForCurrentRailMode()
        if useUnifiedBottomRail {
            railAutohideController.threshold = UserDefaults.standard.double(forKey: SettingsWindowController.chromeAutohideThresholdKey)
            railAutohideController.reduceMotion = UserDefaults.standard.bool(forKey: SettingsWindowController.chromeReducedMotionKey)
            if !railAutohideStarted {
                railAutohideController.start(visible: true)
                railAutohideStarted = true
            }
        } else if railAutohideStarted {
            railAutohideController.stop(visible: true)
            railAutohideStarted = false
        }
        needsLayout = true
    }

    private func configureSubviewVisibilityForCurrentRailMode() {
        let legacyHidden = useUnifiedBottomRail
        let legacyViews: [NSView] = [
            effectView, separator, xPrefixVideoPageButton, dPrefixVideoPageButton,
            queuePageButton, prevButton, rewindButton, playPauseButton, forwardButton,
            nextButton, stopButton, shuffleButton, repeatButton, elapsedLabel,
            scrubber, remainingLabel, volumeButton, fullscreenButton,
            podShrinkButton, podGrowButton
        ]
        legacyViews.forEach { $0.isHidden = legacyHidden }
        if !legacyHidden {
            separator.isHidden = true
            xPrefixVideoPageButton.isHidden = !SettingsWindowController.isVideoPageXButtonEnabled()
            dPrefixVideoPageButton.isHidden = !SettingsWindowController.isCustomPrefixVideoPageEnabled()
            stopButton.isHidden = !SettingsWindowController.isOptionalTransportControlVisible(.stop)
            volumeButton.isHidden = !SettingsWindowController.isOptionalTransportControlVisible(.volume)
            shuffleButton.isHidden = !SettingsWindowController.isOptionalTransportControlVisible(.shuffle)
            repeatButton.isHidden = !SettingsWindowController.isOptionalTransportControlVisible(.repeatOne)
            podShrinkButton.isHidden = false
            podGrowButton.isHidden = false
        }
        if useUnifiedBottomRail {
            if !railAutohideStarted {
                bottomRail.isHidden = false
                bottomRail.alphaValue = 1.0
            }
        } else {
            bottomRail.isHidden = true
        }
    }

    private func setBottomRailVisible(_ visible: Bool, animated: Bool) {
        guard useUnifiedBottomRail else { return }
        railVisibilityGeneration += 1
        let generation = railVisibilityGeneration
        if visible {
            bottomRail.isHidden = false
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = railAutohideController.reduceMotion ? 0.05 : 0.15
                    bottomRail.animator().alphaValue = 1.0
                }
            } else {
                bottomRail.alphaValue = 1.0
            }
        } else if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = railAutohideController.reduceMotion ? 0.05 : 0.22
                bottomRail.animator().alphaValue = 0.0
            } completionHandler: { [weak self] in
                guard let self = self, generation == self.railVisibilityGeneration else { return }
                self.bottomRail.isHidden = true
            }
        } else {
            bottomRail.alphaValue = 0.0
            bottomRail.isHidden = true
        }
    }

    // MARK: - Layout
    //
    // Two-row design:
    //   scrubber row  (y = 0 … scrubRowH): elapsed | scrubber | remaining
    //   controls row  (y = scrubRowH … h): buttons
    //
    // performLayout() skips hidden optional buttons so no gap appears in their place.

    private let scrubRowH: CGFloat = 14

    override func layout() {
        super.layout()
        separator.frame  = .zero
        performLayout()
    }

    private func performLayout() {
        refreshUnifiedBottomRailMode()
        if useUnifiedBottomRail {
            let railH: CGFloat = isFullscreenStyle ? 80 : 84
            bottomRail.frame = NSRect(x: 0, y: 0, width: bounds.width, height: railH)
            return
        }

        let fs = isFullscreenStyle
        let s  = controlPodScale   // scale factor — applied to pod and corner-button geometry
        let w  = bounds.width
        let h  = bounds.height

        // edgePad stays fixed so corner buttons never leave screen regardless of scale.
        let edgePad: CGFloat        = fs ? 18 : 20
        let bottomButtonSize: CGFloat = (fs ? 28 : 32) * s
        let smallSize: CGFloat      = (fs ? 26 : 30) * s
        let playSize: CGFloat       = (fs ? 36 : 40) * s
        let optionalSize: CGFloat   = (fs ? 22 : 26) * s
        let gap: CGFloat            = (fs ? 7  :  8) * s
        let podPadX: CGFloat        = (fs ? 12 : 16) * s
        let podH: CGFloat           = (fs ? 48 : 54) * s

        // podY: at least 8px clearance above the tallest bottom-corner button.
        let bottomY: CGFloat        = fs ? 26 : 22
        let xBtnVisible = !xPrefixVideoPageButton.isHidden
        let dBtnVisible = !dPrefixVideoPageButton.isHidden
        let stackCount  = (xBtnVisible ? 1 : 0) + (dBtnVisible ? 1 : 0)
        let podMinY = bottomY + CGFloat(stackCount + 1) * bottomButtonSize + CGFloat(stackCount) * 4 + 8
        let podY = max(podMinY, h * (fs ? 0.15 : 0.18))

        func styleRound(_ button: NSButton, size: CGFloat, emphasized: Bool = false) {
            button.layer?.cornerRadius = size / 2
            let fillAlpha: CGFloat   = fs ? (emphasized ? 0.15 : 0.08) : (emphasized ? 0.26 : 0.13)
            let borderAlpha: CGFloat = fs ? (emphasized ? 0.12 : 0.08) : (emphasized ? 0.16 : 0.12)
            button.layer?.backgroundColor = NSColor.white.withAlphaComponent(fillAlpha).cgColor
            button.layer?.borderColor     = NSColor.white.withAlphaComponent(borderAlpha).cgColor
            button.contentTintColor       = NSColor.white.withAlphaComponent(
                fs ? (emphasized ? 0.88 : 0.78) : 0.90)
        }

        // Bottom-left Queue Page and bottom-right fullscreen — both scale with the pod.
        queuePageButton.frame = NSRect(x: edgePad, y: bottomY,
                                       width: bottomButtonSize, height: bottomButtonSize)
        styleRound(queuePageButton, size: bottomButtonSize)

        // x_ rename button: stacked above queue button when visible
        if !xPrefixVideoPageButton.isHidden {
            let xBtnY = queuePageButton.frame.maxY + 4
            xPrefixVideoPageButton.frame = NSRect(x: edgePad, y: xBtnY,
                                                  width: bottomButtonSize, height: bottomButtonSize)
            xPrefixVideoPageButton.layer?.cornerRadius = bottomButtonSize / 2
            xPrefixVideoPageButton.isEnabled = controller?.currentItemIsImage == false
            xPrefixVideoPageButton.alphaValue = xPrefixVideoPageButton.isEnabled ? 1.0 : 0.35
        }

        // d_ rename button: stacked above x_ button (or above queue button if x_ is hidden) when visible
        if !dPrefixVideoPageButton.isHidden {
            let baseMaxY: CGFloat = xPrefixVideoPageButton.isHidden
                ? queuePageButton.frame.maxY
                : xPrefixVideoPageButton.frame.maxY
            let dBtnY = baseMaxY + 4
            dPrefixVideoPageButton.frame = NSRect(x: edgePad, y: dBtnY,
                                                  width: bottomButtonSize, height: bottomButtonSize)
            dPrefixVideoPageButton.layer?.cornerRadius = bottomButtonSize / 2
            dPrefixVideoPageButton.isEnabled = controller?.currentItemIsImage == false
            dPrefixVideoPageButton.alphaValue = dPrefixVideoPageButton.isEnabled ? 1.0 : 0.35
        }

        fullscreenButton.frame = NSRect(x: max(edgePad, w - edgePad - bottomButtonSize),
                                        y: bottomY,
                                        width: bottomButtonSize, height: bottomButtonSize)
        styleRound(fullscreenButton, size: bottomButtonSize)

        if !volumeButton.isHidden {
            let volumeX = fullscreenButton.frame.minX - gap - bottomButtonSize
            volumeButton.frame = NSRect(x: volumeX, y: bottomY,
                                        width: bottomButtonSize, height: bottomButtonSize)
            styleRound(volumeButton, size: bottomButtonSize)
        }

        // Pod scale buttons — fixed-size pair centered between corner buttons.
        let scaleBtnSz: CGFloat = 20
        let scaleBtnGap: CGFloat = 6
        let scalePairW = scaleBtnSz * 2 + scaleBtnGap
        let scalePairX = (w - scalePairW) / 2
        let scaleBtnY  = bottomY + (bottomButtonSize - scaleBtnSz) / 2  // vertically center
        podShrinkButton.frame = NSRect(x: scalePairX,
                                       y: scaleBtnY,
                                       width: scaleBtnSz, height: scaleBtnSz)
        styleRound(podShrinkButton, size: scaleBtnSz)
        podShrinkButton.alphaValue = controlPodScale <= Self.podScaleMin ? 0.28 : 0.62

        podGrowButton.frame = NSRect(x: scalePairX + scaleBtnSz + scaleBtnGap,
                                     y: scaleBtnY,
                                     width: scaleBtnSz, height: scaleBtnSz)
        styleRound(podGrowButton, size: scaleBtnSz)
        podGrowButton.alphaValue = controlPodScale >= Self.podScaleMax ? 0.28 : 0.62

        // Center transport pod. Default order:
        // 10s rewind, previous, play/pause, next, 10s forward.
        var centerButtons: [(NSButton, CGFloat, Bool)] = [
            (rewindButton,    smallSize,    false),
            (prevButton,      smallSize,    false),
            (playPauseButton, playSize,     true),
            (nextButton,      smallSize,    false),
            (forwardButton,   smallSize,    false)
        ]
        for item in [(stopButton,    optionalSize, false),
                     (shuffleButton, optionalSize, false),
                     (repeatButton,  optionalSize, false)] where !item.0.isHidden {
            centerButtons.append(item)
        }

        let visibleCenter = centerButtons.filter { !$0.0.isHidden }
        let buttonsW = visibleCenter.reduce(CGFloat(0)) { $0 + $1.1 }
        let gapsW = CGFloat(max(0, visibleCenter.count - 1)) * gap
        let podW = min(max(0, w - 2 * edgePad), buttonsW + gapsW + 2 * podPadX)
        let defaultPodX = (w - podW) / 2
        let defaultPodFrame = NSRect(x: defaultPodX, y: podY, width: podW, height: podH)
        let bottomCornerMaxY = bottomY + CGFloat(stackCount + 1) * bottomButtonSize + CGFloat(stackCount) * 4
        let podFrame = boundedPodFrame(defaultPodFrame,
                                       edgePad: edgePad,
                                       bottomButtonMaxY: bottomCornerMaxY,
                                       mode: currentControlPodPlacementMode())
        let podX      = podFrame.minX
        let podYActual = podFrame.minY
        effectView.frame = podFrame
        effectView.layer?.cornerRadius = podH / 2
        effectView.layer?.borderWidth  = fs ? 0.8 : 1.0
        effectView.layer?.borderColor  = NSColor.white.withAlphaComponent(fs ? 0.10 : 0.14).cgColor
        currentPodFrame        = podFrame
        lastDisplayedPodAnchor = normalizedAnchor(for: podFrame)

        var x = podX + podPadX
        for (button, size, emphasized) in visibleCenter {
            let y = podYActual + (podH - size) / 2
            button.frame = NSRect(x: x, y: y, width: size, height: size)
            styleRound(button, size: size, emphasized: emphasized)
            x += size + gap
        }

        // Thin full-width bottom timeline plus a centered time label aligned to it.
        let sH: CGFloat = 12
        scrubber.frame = NSRect(x: 0, y: 0, width: w, height: sH)

        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: fs ? 9.5 : 10.5, weight: .regular)
        elapsedLabel.textColor = NSColor.white.withAlphaComponent(fs ? 0.72 : 0.82)
        let labelW = min(CGFloat(220), max(120, w - 2 * edgePad))
        elapsedLabel.frame = NSRect(x: (w - labelW) / 2,
                                    y: sH + 2,
                                    width: labelW,
                                    height: 14)
        remainingLabel.frame = .zero
    }

    private func boundedPodFrame(_ defaultFrame: NSRect,
                                 edgePad: CGFloat,
                                 bottomButtonMaxY: CGFloat = 54,
                                 mode: ControlPodPlacementMode) -> NSRect {
        var frame = defaultFrame
        if let anchor = controlPodAnchors[mode] ?? lastDisplayedPodAnchor,
           bounds.width > 1,
           bounds.height > 1 {
            frame.origin.x = anchor.x * bounds.width - frame.width / 2
            frame.origin.y = anchor.y * bounds.height - frame.height / 2
        }
        let minX = edgePad
        let maxX = max(minX, bounds.width - edgePad - frame.width)
        // minY: just above the scrubber/label row; corner-button overlap is acceptable when user drags low.
        let minY = max(CGFloat(4), scrubRowH + 2)
        let maxY = max(minY, bounds.height - edgePad - frame.height)
        frame.origin.x = min(max(frame.origin.x, minX), maxX)
        frame.origin.y = min(max(frame.origin.y, minY), maxY)
        return frame
    }

    private func restorePersistedControlPodAnchors() {
        for mode in ControlPodPlacementMode.allCases {
            guard let xObject = UserDefaults.standard.object(forKey: mode.xDefaultsKey),
                  let yObject = UserDefaults.standard.object(forKey: mode.yDefaultsKey) else { continue }
            let x = UserDefaults.standard.double(forKey: mode.xDefaultsKey)
            let y = UserDefaults.standard.double(forKey: mode.yDefaultsKey)
            guard xObject is NSNumber, yObject is NSNumber else { continue }
            controlPodAnchors[mode] = CGPoint(x: max(0, min(1, x)),
                                              y: max(0, min(1, y)))
        }
    }

    private func currentControlPodPlacementMode() -> ControlPodPlacementMode {
        isFullscreenStyle ? .fullscreen : .windowed
    }

    private func normalizedAnchor(for frame: NSRect) -> CGPoint? {
        guard !frame.isEmpty, bounds.width > 1, bounds.height > 1 else { return nil }
        return CGPoint(x: max(0, min(1, frame.midX / bounds.width)),
                       y: max(0, min(1, frame.midY / bounds.height)))
    }

    private func setControlPodAnchor(_ anchor: CGPoint,
                                     for mode: ControlPodPlacementMode,
                                     persist: Bool) {
        guard !useUnifiedBottomRail else { return }
        let clampedAnchor = CGPoint(x: max(0, min(1, anchor.x)),
                                    y: max(0, min(1, anchor.y)))
        controlPodAnchors[mode] = clampedAnchor
        if persist {
            UserDefaults.standard.set(clampedAnchor.x, forKey: mode.xDefaultsKey)
            UserDefaults.standard.set(clampedAnchor.y, forKey: mode.yDefaultsKey)
        }
    }

    // MARK: - Control pod scale

    private func loadPersistedPodScale() {
        guard UserDefaults.standard.object(forKey: Self.podScaleKey) != nil else { return }
        let raw = CGFloat(UserDefaults.standard.double(forKey: Self.podScaleKey))
        controlPodScale = max(Self.podScaleMin, min(Self.podScaleMax, raw))
    }

    @objc private func podGrowTapped() {
        guard !useUnifiedBottomRail else { return }
        guard controlPodScale < Self.podScaleMax else { return }
        let raw = Double(controlPodScale) + Double(Self.podScaleStep)
        controlPodScale = CGFloat(min(Double(Self.podScaleMax), (raw * 10).rounded() / 10))
        UserDefaults.standard.set(Double(controlPodScale), forKey: Self.podScaleKey)
        needsLayout = true
    }

    @objc private func podShrinkTapped() {
        guard !useUnifiedBottomRail else { return }
        guard controlPodScale > Self.podScaleMin else { return }
        let raw = Double(controlPodScale) - Double(Self.podScaleStep)
        controlPodScale = CGFloat(max(Double(Self.podScaleMin), (raw * 10).rounded() / 10))
        UserDefaults.standard.set(Double(controlPodScale), forKey: Self.podScaleKey)
        needsLayout = true
    }

    // MARK: - Seek notification

    func notifySeek(to position: Float) {
        bottomRail.notifySeek(to: position)
        pendingSeekPosition = position
        pendingSeekDate     = Date()
    }

    // MARK: - State update

    func update() {
        refreshUnifiedBottomRailMode()
        bottomRail.player = player
        bottomRail.controller = controller
        bottomRail.isImageMode = isImageMode
        bottomRail.imageModeElapsed = imageModeElapsed
        bottomRail.imageModeDuration = imageModeDuration
        bottomRail.imageModeIsPlaying = imageModeIsPlaying
        if useUnifiedBottomRail {
            bottomRail.update()
            return
        }

        if isImageMode {
            updateForImageMode()
            return
        }

        guard let player = player else {
            // Disable all interactive buttons (visibility unchanged — isHidden governs that)
            [prevButton, nextButton, rewindButton, forwardButton, stopButton,
             shuffleButton, repeatButton, queuePageButton].forEach {
                $0.isEnabled  = false
                $0.alphaValue = 0.30
            }
            return
        }

        let hasMedia = player.media != nil

        // H2: play/pause symbol — skip applySymbol when unchanged
        let ppSymbol = player.isPlaying ? "pause.fill" : "play.fill"
        if ppSymbol != _cachedPlayPauseSymbol {
            _cachedPlayPauseSymbol = ppSymbol
            applySymbol(playPauseButton, ppSymbol, pointSize: 14)
        }

        // Scrubber: priority — scrubbing > pendingSeekPosition > player.position
        // H2: skip doubleValue assignment when change is below 0.001 (sub-pixel for typical widths)
        if !isScrubbing {
            var targetPos: Double? = nil
            if let pending = pendingSeekPosition {
                let current = player.position
                let elapsed = pendingSeekDate.map { Date().timeIntervalSince($0) } ?? pendingSeekTimeout
                if abs(current - pending) < 0.01 || elapsed > pendingSeekTimeout {
                    pendingSeekPosition = nil
                    pendingSeekDate     = nil
                    let pos = Double(current)
                    if pos.isFinite { targetPos = max(0, min(1, pos)) }
                } else {
                    let pos = Double(pending)
                    if pos.isFinite { targetPos = max(0, min(1, pos)) }
                }
            } else {
                let pos = Double(player.position)
                if pos.isFinite { targetPos = max(0, min(1, pos)) }
            }
            if let pos = targetPos, abs(pos - _cachedScrubberValue) > 0.001 {
                _cachedScrubberValue = pos
                scrubber.doubleValue = pos
            }
        }

        // H2: elapsed label — skip stringValue assignment when text is unchanged
        let elapsed   = player.time.stringValue
        let remaining = player.remainingTime?.stringValue ?? "–:––"
        let newElapsedText: String
        if controller?.isShowingProvisionalDuration == true {
            newElapsedText = "\(elapsed)  \(MediaFileSupport.durationLoadingText)"
        } else {
            newElapsedText = "\(elapsed)  \(remaining)"
        }
        if newElapsedText != _cachedElapsedText {
            _cachedElapsedText = newElapsedText
            elapsedLabel.stringValue = newElapsedText
        }
        remainingLabel.stringValue = ""

        // H2: volume symbol — skip applySymbol when unchanged
        if let audio = player.audio {
            let volSymbol = audio.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
            if volSymbol != _cachedVolumeSymbol {
                _cachedVolumeSymbol = volSymbol
                applySymbol(volumeButton, volSymbol, pointSize: 12)
            }
        }

        rewindButton.isEnabled  = hasMedia
        forwardButton.isEnabled = hasMedia
        stopButton.isEnabled    = hasMedia
        prevButton.isEnabled    = hasMedia && (controller?.hasPrevious ?? false)
        nextButton.isEnabled    = hasMedia && (controller?.hasNext ?? false)
        prevButton.alphaValue   = prevButton.isEnabled  ? 1.0 : 0.35
        nextButton.alphaValue   = nextButton.isEnabled  ? 1.0 : 0.35
        stopButton.alphaValue   = stopButton.isEnabled  ? 1.0 : 0.35

        // Shuffle: enabled when set has 2+ items; reflects both shuffle and endless shuffle states
        let shuffleEnabled = (controller?.playbackSet.count ?? 0) > 1
        let shuffleOn  = controller?.isShuffleOn ?? false
        let endlessOn  = controller?.isEndlessShuffleOn ?? false
        shuffleButton.isEnabled  = shuffleEnabled
        shuffleButton.alphaValue = (shuffleOn || endlessOn) ? 1.0 : (shuffleEnabled ? 0.55 : 0.30)
        let shuffleTip = endlessOn ? "Endless Shuffle (on)" : shuffleOn ? "Shuffle (on)" : "Shuffle"
        if shuffleButton.toolTip != shuffleTip {
            shuffleButton.toolTip = shuffleTip
            let shuffleSymbol = endlessOn ? "arrow.triangle.2.circlepath" : "shuffle"
            applySymbol(shuffleButton, shuffleSymbol, pointSize: 11)
        }

        // Repeat: symbol changes when active
        // H2: skip applySymbol when repeat symbol is unchanged
        repeatButton.isEnabled = hasMedia
        let repeatActive = controller?.isRepeatOne ?? false
        repeatButton.alphaValue = repeatActive ? 1.0 : (hasMedia ? 0.55 : 0.30)
        let repeatSymbol = repeatActive ? "repeat.1" : "repeat"
        if repeatSymbol != _cachedRepeatSymbol {
            _cachedRepeatSymbol = repeatSymbol
            applySymbol(repeatButton, repeatSymbol, pointSize: 11)
        }

        // Queue page toggle button: highlighted when page is open
        let hasSet = !(controller?.playbackSet.isEmpty ?? true)
        let queuePageOpen = controller?.isQueuePageOpen ?? false
        queuePageButton.isEnabled  = hasSet
        queuePageButton.alphaValue = queuePageOpen ? 1.0 : (hasSet ? 0.70 : 0.30)
    }

    // MARK: - Button actions

    @objc private func playPauseTapped()  { controller?.togglePlayPause() }
    @objc private func stopTapped()       { controller?.stopPlayback() }
    @objc private func prevTapped()       { controller?.playPrevious() }
    @objc private func nextTapped()       { controller?.playNext() }
    @objc private func rewindTapped()     { controller?.skipBackward10() }
    @objc private func forwardTapped()    { controller?.skipForward10() }
    @objc private func shuffleTapped()    { controller?.toggleShuffle() }
    @objc private func repeatTapped()     { controller?.toggleRepeat() }
    @objc private func queuePageTapped()  { controller?.toggleQueuePage() }

    @objc private func scrubberMoved(_ sender: NSSlider) {
        guard !isImageMode else { return }
        let raw = Float(sender.doubleValue)
        let pos = controller?.clampedUserSeekPosition(raw, source: "scrubber-move")
            ?? max(0, min(0.985, raw))
        if abs(Double(pos) - sender.doubleValue) > 0.0005 {
            sender.doubleValue = Double(pos)
        }
        player?.position = pos
        notifySeek(to: pos)
    }

    @objc private func volumeTapped() {
        controller?.toggleMuteFromTransport()
        applySymbol(volumeButton,
                    (player?.audio?.volume ?? 0) == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    pointSize: 12)
    }

    @objc private func fullscreenTapped() {
        window?.toggleFullScreen(nil)
    }

    // MARK: - Image mode update

    private func updateForImageMode() {
        let ppSymbol = imageModeIsPlaying ? "pause.fill" : "play.fill"
        if ppSymbol != _cachedPlayPauseSymbol {
            _cachedPlayPauseSymbol = ppSymbol
            applySymbol(playPauseButton, ppSymbol, pointSize: 14)
        }

        if !isScrubbing {
            let pos = imageModeDuration > 0 ? min(1.0, imageModeElapsed / imageModeDuration) : 0
            if abs(pos - _cachedScrubberValue) > 0.001 {
                _cachedScrubberValue = pos
                scrubber.doubleValue = pos
            }
        }

        let elapsedStr  = formatImageTime(imageModeElapsed)
        let totalStr    = formatImageTime(imageModeDuration)
        let newText     = "\(elapsedStr)  \(totalStr)"
        if newText != _cachedElapsedText {
            _cachedElapsedText = newText
            elapsedLabel.stringValue = newText
        }
        remainingLabel.stringValue = ""

        rewindButton.isEnabled  = false
        forwardButton.isEnabled = false
        rewindButton.alphaValue  = 0.30
        forwardButton.alphaValue = 0.30

        stopButton.isEnabled    = true
        stopButton.alphaValue   = 1.0

        prevButton.isEnabled    = controller?.hasPrevious ?? false
        nextButton.isEnabled    = controller?.hasNext     ?? false
        prevButton.alphaValue   = prevButton.isEnabled ? 1.0 : 0.35
        nextButton.alphaValue   = nextButton.isEnabled ? 1.0 : 0.35

        let shuffleEnabled = (controller?.playbackSet.count ?? 0) > 1
        let shuffleOn  = controller?.isShuffleOn ?? false
        let endlessOn  = controller?.isEndlessShuffleOn ?? false
        shuffleButton.isEnabled  = shuffleEnabled
        shuffleButton.alphaValue = (shuffleOn || endlessOn) ? 1.0 : (shuffleEnabled ? 0.55 : 0.30)
        let imgShuffleTip = endlessOn ? "Endless Shuffle (on)" : shuffleOn ? "Shuffle (on)" : "Shuffle"
        if shuffleButton.toolTip != imgShuffleTip {
            shuffleButton.toolTip = imgShuffleTip
            let imgShuffleSymbol = endlessOn ? "arrow.triangle.2.circlepath" : "shuffle"
            applySymbol(shuffleButton, imgShuffleSymbol, pointSize: 11)
        }

        repeatButton.isEnabled = true
        let repeatActive = controller?.isRepeatOne ?? false
        repeatButton.alphaValue = repeatActive ? 1.0 : 0.55
        let repeatSymbol = repeatActive ? "repeat.1" : "repeat"
        if repeatSymbol != _cachedRepeatSymbol {
            _cachedRepeatSymbol = repeatSymbol
            applySymbol(repeatButton, repeatSymbol, pointSize: 11)
        }

        let hasSet       = !(controller?.playbackSet.isEmpty ?? true)
        let queuePageOpen = controller?.isQueuePageOpen ?? false
        queuePageButton.isEnabled  = hasSet
        queuePageButton.alphaValue = queuePageOpen ? 1.0 : (hasSet ? 0.70 : 0.30)
    }

    private func formatImageTime(_ seconds: Double) -> String {
        MediaFileSupport.formatShortDuration(max(0, Int(seconds)))
    }

    // MARK: - Helpers

    private func applySymbol(_ button: NSButton,
                             _ name: String,
                             fallbackNames: [String] = [],
                             pointSize: CGFloat,
                             accessibilityDescription: String? = nil) {
        // H2: reuse cached NSImage.SymbolConfiguration per point size (weight is always .medium)
        let cfg: NSImage.SymbolConfiguration
        if let cached = _symbolConfigCache[pointSize] {
            cfg = cached
        } else {
            cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            _symbolConfigCache[pointSize] = cfg
        }
        for symbolName in [name] + fallbackNames {
            if let img = NSImage(systemSymbolName: symbolName,
                                 accessibilityDescription: accessibilityDescription) {
                button.image = img.withSymbolConfiguration(cfg) ?? img
                return
            }
        }
        button.image = nil
    }
}

// MARK: - ScrubberSlider

/// NSSlider subclass that fires begin/end callbacks around a complete mouse interaction
/// and uses a KnoblessSliderCell so the thumb is hidden while seek remains fully
/// interactive (click-to-seek and drag-to-seek work via track hit testing).
final class ScrubberSlider: NSSlider {
    var scrubDidBegin: (() -> Void)?
    var scrubDidEnd:   (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Replace the default cell with the knobless variant before any property
        // configuration in setupViews() so min/max/value writes go to the new cell.
        cell = KnoblessSliderCell()
    }
    required init?(coder: NSCoder) { fatalError("programmatic only") }

    override func mouseDown(with event: NSEvent) {
        scrubDidBegin?()
        super.mouseDown(with: event)   // tracking loop — returns only on mouse-up
        scrubDidEnd?()
    }
}

// MARK: - KnoblessSliderCell

/// NSSliderCell that hides the visible knob while preserving all seek interactions.
///
/// drawKnob(_:) is a no-op so no thumb is rendered.
/// drawBar(inside:flipped:) replaces the system bar with a 2 pt track +
/// a tinted progress fill so the scrubber still gives positional feedback.
///
/// Mouse hit-testing in NSSliderCell is track-based (not knob-based) for continuous
/// sliders without tick marks, so click-to-seek and drag-to-seek continue to work.
private final class KnoblessSliderCell: NSSliderCell {

    // No knob drawn — thumb is intentionally absent.
    override func drawKnob(_ knobRect: NSRect) {}

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let h: CGFloat  = 3
        let barRect     = NSRect(x: rect.minX,
                                 y: rect.midY - h / 2,
                                 width: rect.width,
                                 height: h)
        // Background track
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 1, yRadius: 1).fill()

        // Progress fill — tinted portion from 0 to current position
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

private final class DraggableVisualEffectView: NSVisualEffectView {
    var dragDidBegin: (() -> Void)?
    var dragDidMove: ((NSPoint) -> Void)?
    private var dragStartPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = event.locationInWindow
        dragDidBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let current = event.locationInWindow
        dragDidMove?(NSPoint(x: current.x - start.x, y: current.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragStartPoint = nil
    }
}
