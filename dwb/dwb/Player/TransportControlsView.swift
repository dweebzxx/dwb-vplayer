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
///   stop, volume, shuffle, repeat, quick-queue.
///
/// performLayout() skips space for hidden buttons, so the streamlined default set
/// stays compact without gaps.
final class TransportControlsView: NSView {

    weak var player: VLCMediaPlayer?
    weak var controller: PlayerWindowController?

    // MARK: - Subviews

    private let effectView      = DraggableVisualEffectView()
    private let separator       = NSView()

    // Always-visible left cluster (order matches the on-screen left→right arrangement)
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
    private let queueButton     = NSButton()   // quick-queue popup

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

        effectView.material       = .hudWindow
        effectView.blendingMode   = .withinWindow
        effectView.state          = .active
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

        makeButton(queueButton,     symbol: "list.bullet",                         size: 11, action: #selector(queueTapped))
        queueButton.toolTip = "Show quick queue"

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
            self?.controller?.notifyUserSeek(source: "scrub-begin")
        }
        scrubber.scrubDidEnd = { [weak self] in
            guard let self = self else { return }
            let raw = Float(self.scrubber.doubleValue)
            let pos = self.controller?.clampedUserSeekPosition(raw, source: "scrub-end")
                ?? max(0, min(0.985, raw))
            self.scrubber.doubleValue = Double(pos)
            self.controller?.notifyUserSeek(targetPosition: pos, source: "scrub-end")
            self.player?.position = pos
            self.notifySeek(to: pos)
            self.isScrubbing = false
        }
        addSubview(scrubber)

        // Right cluster: optional volume + always-visible fullscreen
        makeButton(volumeButton,     symbol: "speaker.wave.2.fill",                size: 12, action: #selector(volumeTapped))
        volumeButton.toolTip = "Mute / Unmute"

        makeButton(fullscreenButton, symbol: "arrow.up.left.and.arrow.down.right", size: 11, action: #selector(fullscreenTapped))
        fullscreenButton.toolTip = "Toggle Fullscreen"

        // Apply initial visibility from UserDefaults (all optional controls default hidden)
        applyVisibilitySettings()
        applySkipDurationSettings()

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
    }

    // MARK: - Visibility settings

    /// Apply optional-control visibility from UserDefaults.
    /// Call this on init and whenever transportVisibilityChanged is posted.
    func applyVisibilitySettings() {
        stopButton.isHidden = !SettingsWindowController.isOptionalTransportControlVisible(.stop)
        volumeButton.isHidden = !SettingsWindowController.isOptionalTransportControlVisible(.volume)
        shuffleButton.isHidden = !SettingsWindowController.isOptionalTransportControlVisible(.shuffle)
        repeatButton.isHidden = !SettingsWindowController.isOptionalTransportControlVisible(.repeatOne)
        queueButton.isHidden = !SettingsWindowController.isOptionalTransportControlVisible(.quickQueue)
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

    func setFullscreenStyle(_ fullscreen: Bool) {
        isFullscreenStyle = fullscreen
        separator.isHidden = true
        effectView.alphaValue = fullscreen ? 0.60 : 0.72
        applySymbol(fullscreenButton,
                    fullscreen ? "arrow.down.right.and.arrow.up.left"
                               : "arrow.up.left.and.arrow.down.right",
                    pointSize: fullscreen ? 10 : 11)
        needsLayout = true
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
        let fs = isFullscreenStyle
        let w  = bounds.width
        let h  = bounds.height

        let edgePad: CGFloat = fs ? 18 : 20
        let bottomButtonSize: CGFloat = fs ? 28 : 32
        let smallSize: CGFloat = fs ? 26 : 30
        let playSize: CGFloat = fs ? 36 : 40
        let optionalSize: CGFloat = fs ? 22 : 26
        let gap: CGFloat = fs ? 7 : 8
        let podPadX: CGFloat = fs ? 12 : 16
        let podH: CGFloat = fs ? 48 : 54
        let podY = max(fs ? CGFloat(52) : CGFloat(58), h * (fs ? 0.15 : 0.18))

        func styleRound(_ button: NSButton, size: CGFloat, emphasized: Bool = false) {
            button.layer?.cornerRadius = size / 2
            let fillAlpha: CGFloat = fs ? (emphasized ? 0.15 : 0.08) : (emphasized ? 0.26 : 0.13)
            let borderAlpha: CGFloat = fs ? (emphasized ? 0.12 : 0.08) : (emphasized ? 0.16 : 0.12)
            button.layer?.backgroundColor = NSColor.white.withAlphaComponent(fillAlpha).cgColor
            button.layer?.borderColor = NSColor.white.withAlphaComponent(borderAlpha).cgColor
            button.contentTintColor = NSColor.white.withAlphaComponent(fs ? (emphasized ? 0.88 : 0.78) : 0.90)
        }

        // Bottom-left Queue Page and bottom-right fullscreen are independent affordances.
        let bottomY: CGFloat = fs ? 26 : 22
        queuePageButton.frame = NSRect(x: edgePad, y: bottomY,
                                       width: bottomButtonSize, height: bottomButtonSize)
        styleRound(queuePageButton, size: bottomButtonSize)

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

        // Center transport pod. Default order:
        // 10s rewind, previous, play/pause, next, 10s forward.
        var centerButtons: [(NSButton, CGFloat, Bool)] = [
            (rewindButton, smallSize, false),
            (prevButton, smallSize, false),
            (playPauseButton, playSize, true),
            (nextButton, smallSize, false),
            (forwardButton, smallSize, false)
        ]
        for item in [(stopButton, optionalSize, false),
                     (shuffleButton, optionalSize, false),
                     (repeatButton, optionalSize, false),
                     (queueButton, optionalSize, false)] where !item.0.isHidden {
            centerButtons.append(item)
        }

        let visibleCenter = centerButtons.filter { !$0.0.isHidden }
        let buttonsW = visibleCenter.reduce(CGFloat(0)) { $0 + $1.1 }
        let gapsW = CGFloat(max(0, visibleCenter.count - 1)) * gap
        let podW = min(max(0, w - 2 * edgePad), buttonsW + gapsW + 2 * podPadX)
        let defaultPodX = (w - podW) / 2
        let defaultPodFrame = NSRect(x: defaultPodX, y: podY, width: podW, height: podH)
        let podFrame = boundedPodFrame(defaultPodFrame,
                                       edgePad: edgePad,
                                       mode: currentControlPodPlacementMode())
        let podX = podFrame.minX
        let podYActual = podFrame.minY
        effectView.frame = podFrame
        effectView.layer?.cornerRadius = podH / 2
        effectView.layer?.borderWidth = fs ? 0.8 : 1.0
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(fs ? 0.10 : 0.14).cgColor
        currentPodFrame = podFrame
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
        let minY = max(CGFloat(38), scrubRowH + 22)
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
        let clampedAnchor = CGPoint(x: max(0, min(1, anchor.x)),
                                    y: max(0, min(1, anchor.y)))
        controlPodAnchors[mode] = clampedAnchor
        if persist {
            UserDefaults.standard.set(clampedAnchor.x, forKey: mode.xDefaultsKey)
            UserDefaults.standard.set(clampedAnchor.y, forKey: mode.yDefaultsKey)
        }
    }

    // MARK: - Seek notification

    func notifySeek(to position: Float) {
        pendingSeekPosition = position
        pendingSeekDate     = Date()
    }

    // MARK: - State update

    func update() {
        guard let player = player else {
            // Disable all interactive buttons (visibility unchanged — isHidden governs that)
            [prevButton, nextButton, rewindButton, forwardButton, stopButton,
             shuffleButton, repeatButton, queueButton, queuePageButton].forEach {
                $0.isEnabled  = false
                $0.alphaValue = 0.30
            }
            return
        }

        let hasMedia = player.media != nil

        applySymbol(playPauseButton, player.isPlaying ? "pause.fill" : "play.fill", pointSize: 14)

        // Scrubber: priority — scrubbing > pendingSeekPosition > player.position
        if !isScrubbing {
            if let pending = pendingSeekPosition {
                let current = player.position
                let elapsed = pendingSeekDate.map { Date().timeIntervalSince($0) } ?? pendingSeekTimeout
                if abs(current - pending) < 0.01 || elapsed > pendingSeekTimeout {
                    pendingSeekPosition = nil
                    pendingSeekDate     = nil
                    let pos = Double(current)
                    if pos.isFinite { scrubber.doubleValue = max(0, min(1, pos)) }
                } else {
                    let pos = Double(pending)
                    if pos.isFinite { scrubber.doubleValue = max(0, min(1, pos)) }
                }
            } else {
                let pos = Double(player.position)
                if pos.isFinite { scrubber.doubleValue = max(0, min(1, pos)) }
            }
        }

        let elapsed = player.time.stringValue
        let remaining = player.remainingTime?.stringValue ?? "–:––"
        if controller?.isShowingProvisionalDuration == true {
            elapsedLabel.stringValue = "\(elapsed)  \(MediaFileSupport.durationLoadingText)"
        } else {
            elapsedLabel.stringValue = "\(elapsed)  \(remaining)"
        }
        remainingLabel.stringValue = ""

        if let audio = player.audio {
            applySymbol(volumeButton,
                        audio.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        pointSize: 12)
        }

        rewindButton.isEnabled  = hasMedia
        forwardButton.isEnabled = hasMedia
        stopButton.isEnabled    = hasMedia
        prevButton.isEnabled    = hasMedia && (controller?.hasPrevious ?? false)
        nextButton.isEnabled    = hasMedia && (controller?.hasNext ?? false)
        prevButton.alphaValue   = prevButton.isEnabled  ? 1.0 : 0.35
        nextButton.alphaValue   = nextButton.isEnabled  ? 1.0 : 0.35
        stopButton.alphaValue   = stopButton.isEnabled  ? 1.0 : 0.35

        // Shuffle: enabled when set has 2+ items
        let shuffleEnabled = (controller?.playbackSet.count ?? 0) > 1
        let shuffleActive  = controller?.isShuffleOn ?? false
        shuffleButton.isEnabled  = shuffleEnabled
        shuffleButton.alphaValue = shuffleActive ? 1.0 : (shuffleEnabled ? 0.55 : 0.30)

        // Repeat: symbol changes when active
        repeatButton.isEnabled = hasMedia
        let repeatActive = controller?.isRepeatOne ?? false
        repeatButton.alphaValue = repeatActive ? 1.0 : (hasMedia ? 0.55 : 0.30)
        applySymbol(repeatButton, repeatActive ? "repeat.1" : "repeat", pointSize: 11)

        // Quick queue popup button: enabled when set has items
        let hasSet = !(controller?.playbackSet.isEmpty ?? true)
        queueButton.isEnabled  = hasSet
        queueButton.alphaValue = hasSet ? 0.70 : 0.30

        // Queue page toggle button: highlighted when page is open
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
    @objc private func queueTapped()      { controller?.toggleQueuePanel(relativeTo: self) }
    @objc private func queuePageTapped()  { controller?.toggleQueuePage() }

    @objc private func scrubberMoved(_ sender: NSSlider) {
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
        guard let audio = player?.audio else { return }
        if audio.volume > 0 {
            preMuteVolume = audio.volume
            audio.volume  = 0
        } else {
            audio.volume = max(1, preMuteVolume)
            controller?.showVolumeBar(volume: audio.volume)
        }
        controller?.persistTransportVolume(audio.volume)
        applySymbol(volumeButton,
                    audio.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    pointSize: 12)
    }

    @objc private func fullscreenTapped() {
        window?.toggleFullScreen(nil)
    }

    // MARK: - Helpers

    private func applySymbol(_ button: NSButton,
                             _ name: String,
                             fallbackNames: [String] = [],
                             pointSize: CGFloat,
                             accessibilityDescription: String? = nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
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
private final class ScrubberSlider: NSSlider {
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
        let h: CGFloat  = 2
        let barRect     = NSRect(x: rect.minX,
                                 y: rect.midY - h / 2,
                                 width: rect.width,
                                 height: h)
        // Background track
        NSColor.white.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 1, yRadius: 1).fill()

        // Progress fill — tinted portion from 0 to current position
        let range = maxValue - minValue
        if range > 0 {
            let frac    = CGFloat((doubleValue - minValue) / range)
            let filledW = max(0, barRect.width * frac)
            let filled  = NSRect(x: barRect.minX, y: barRect.minY,
                                 width: filledW,  height: barRect.height)
            NSColor.white.withAlphaComponent(0.65).setFill()
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
