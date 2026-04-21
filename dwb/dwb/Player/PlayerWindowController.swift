import Cocoa
import VLCKitSPM

enum QueueSortMode: Int, CaseIterable {
    case manual = 0
    case filenameAscending
    case filenameDescending
    case fileSizeAscending
    case fileSizeDescending
    case durationAscending
    case durationDescending

    var title: String {
        switch self {
        case .manual:
            return "Manual"
        case .filenameAscending:
            return "Name A-Z"
        case .filenameDescending:
            return "Name Z-A"
        case .fileSizeAscending:
            return "Size Low-High"
        case .fileSizeDescending:
            return "Size High-Low"
        case .durationAscending:
            return "Duration Short-Long"
        case .durationDescending:
            return "Duration Long-Short"
        }
    }
}

class PlayerWindowController: NSWindowController {

    private(set) var player: VLCMediaPlayer!
    private var videoSurface: VideoSurfaceView!
    private var transport: TransportControlsView!
    private var volumeBar: VolumeBarView!
    private var queuePage: QueuePageView!
    private let centeredTitleLabel = NSTextField(labelWithString: "dwb")

    // MARK: - Fullscreen state

    private var isFullscreen         = false
    /// True from windowWillEnterFullScreen until windowDidEnterFullScreen.
    /// Guards windowDidResize from writing styleMask during AppKit's entry animation.
    private var isEnteringFullscreen = false
    /// True from windowWillExitFullScreen until the deferred cleanup block in
    /// windowDidExitFullScreen clears it.  Set EARLY (in windowWillExitFullScreen)
    /// so that exit-animation resize callbacks already see the exiting state.
    private var isExitingFullscreen  = false

    // MARK: - Layout mode (single source of truth)

    private enum LayoutMode { case fullscreen, exitingFullscreenSettling, windowed }

    /// Authoritative layout mode consumed by layoutPlayerViews() and setFullscreenStyle().
    ///
    /// Precedence:
    ///   isExitingFullscreen → .exitingFullscreenSettling  (windowed baseline)
    ///   isFullscreen        → .fullscreen                 (HUD layout)
    ///   otherwise           → .windowed                   (windowed baseline)
    ///
    /// .exitingFullscreenSettling takes priority over .fullscreen so that exit-animation
    /// resize callbacks (which still see isFullscreen=true) choose windowed geometry,
    /// not fullscreen HUD geometry.
    private var layoutMode: LayoutMode {
        if isExitingFullscreen { return .exitingFullscreenSettling }
        if isFullscreen        { return .fullscreen }
        return .windowed
    }

    private var updateTimer:   Timer?
    private var hideHUDTimer:  Timer?
    private var trackingArea:  NSTrackingArea?

    // MARK: - Seek accumulation

    /// Accumulated seek target for rapid arrow-key holds.
    private var seekTargetMs: Int? = nil
    private var seekTargetResetTimer: Timer? = nil

    // MARK: - Scale

    private(set) var scaleMode: ScaleMode = .fit

    // MARK: - Playback set

    /// Current media URL being played.
    private(set) var currentMediaURL: URL?

    /// Master list of URLs for this window's playback set.
    /// Established by open/drop; never reordered.
    private(set) var playbackSet: [URL] = []

    /// Navigation order: indices into `playbackSet`.
    /// Natural order: [0, 1, 2, …, n-1].
    /// Shuffled:      a permutation of the same indices.
    private var displayOrder: [Int] = []

    /// Current position in `displayOrder`. -1 when no set is loaded.
    private var currentDisplayIndex: Int = -1

    /// Index into `playbackSet` for the item currently playing.
    var currentSetIndex: Int {
        guard currentDisplayIndex >= 0, currentDisplayIndex < displayOrder.count else { return -1 }
        return displayOrder[currentDisplayIndex]
    }

    var hasPrevious: Bool { currentDisplayIndex > 0 }
    var hasNext:     Bool { canAdvanceAfterCompletion }

    // MARK: - Shuffle / Repeat

    private(set) var isShuffleOn = false
    private(set) var isRepeatOne = false
    private(set) var isEndlessShuffleOn = false

    // MARK: - Auto-advance

    private enum PlaybackCompletionAction: String {
        case repeatCurrent
        case playNext
        case endlessShuffleNext
        case stopLastItem
        case ignoredUserStop
    }

    private enum PlaybackTransitionStrategy: String {
        case reuseCurrentPlayer = "reuse-current-player"
        case freshPlayer = "fresh-player"
    }

    private struct CompletionSequence {
        let id: Int
        let source: String
        let action: PlaybackCompletionAction
        let sourceURL: URL?
        let sourceSessionID: Int
    }

    private var scheduledPlaybackAction: DispatchWorkItem? = nil
    private var activeCompletionSequence: CompletionSequence? = nil
    private var playbackCompletionSequence = 0
    private var currentPlaybackSessionID = 0

    private typealias PlaybackCommandAction = (@escaping () -> Void) -> Void

    private struct QueuedPlaybackCommand {
        let id: Int
        let name: String
        let action: PlaybackCommandAction
    }

    private var queuedPlaybackCommands: [QueuedPlaybackCommand] = []
    private var isExecutingPlaybackCommand = false
    private var playbackCommandSequence = 0

    /// Set by stopPlayback(), close(), windowWillClose() before calling player.stop()
    /// so the .stopped handler knows it was user-initiated and skips auto-advance.
    private var isUserStop = false

    /// Set by playCurrentItem() whenever player.media != nil at the time of the call.
    /// VLC fires .stopped when media is replaced, regardless of prior player state
    /// (playing, paused, or already stopped from natural EOF). This flag tells the
    /// .stopped handler to ignore that implicit transition event.
    private var suppressNextStopped = false
    private var suppressNextStoppedDate: Date? = nil
    private let replacementStopSuppressionWindow: TimeInterval = 0.75
    private let replacementStartDelay: TimeInterval = 0.05

    /// True when the .ended VLC event was received for the current media.
    /// Combined with lastKnownPosition for a three-signal natural-EOF check.
    private var naturalEOFDetected = false

    /// Last player position sampled by the app-owned progress watchdog while playing.
    /// Preserved across stop/end transitions so autoplay does not depend solely on VLC
    /// events that may arrive late or not at all.
    private var lastKnownPosition: Float = 0
    private var lastKnownTimeMs: Int = 0
    private var lastKnownDurationMs: Int = 0
    private var lastPlayingDate: Date? = nil
    private var lastProgressDate: Date? = nil
    private var lastStoppedDate: Date? = nil
    private var lastStoppedPosition: Float = 0
    private var lastStoppedMediaURL: URL? = nil

    /// Position captured on the VLC callback thread at the moment the .ended event fires.
    /// More reliable than capturedPosition at .stopped time because VLC hasn't reset it yet.
    private var positionAtEndedEvent: Float = 0

    /// Timestamp of the most recent user-initiated seek (scrubber drag/tap, arrow-key skip).
    /// Used by the .stopped handler to reject position-based EOF signals when a seek was
    /// recent: after seeking near the end, lastKnownPosition is near 1.0 but does NOT
    /// represent natural EOF. Require naturalEOFDetected instead.
    private var lastUserSeekDate: Date? = nil
    private let userSeekEOFGuardWindow: TimeInterval = 1.5
    private let maxUserSeekPosition: Float = 0.985
    private let eofPositionThreshold: Float = 0.95
    private let pausedNearEOFPositionThreshold: Float = 0.985
    private let pausedNearEOFRemainingMs = 1_000
    private let watchdogRecentPlaybackWindow: TimeInterval = 1.5
    private let watchdogRecentStopWindow: TimeInterval = 1.2
    private let watchdogDefaultEOFToleranceMs = 1_500
    private let delayedPlaybackActionInterval: TimeInterval = 0.30
    private let playbackStartCheckInterval: TimeInterval = 0.35
    private let maxPlaybackStartRetries = 2
    private let maxPlaybackProgressConfirmationRetries = 2
    private let playbackStartProgressAdvanceMs = 250
    private let playbackStartProgressAdvancePosition: Float = 0.002

    private struct PlaybackStartHandshake {
        let id: Int
        let reason: String
        let expectedURL: URL
        let expectedSessionID: Int
        let transitionStrategy: PlaybackTransitionStrategy
        let baselinePosition: Float
        let baselineTimeMs: Int
        var playRetryCount: Int
        var progressRetryCount: Int
        var sawPlaying: Bool
        var recoveryUsed: Bool
    }

    private var playbackStartHandshake: PlaybackStartHandshake? = nil
    private var playbackStartHandshakeWorkItem: DispatchWorkItem? = nil
    private var playbackStartHandshakeSequence = 0
    private var replacementStartWorkItem: DispatchWorkItem? = nil
    private var replacementStartSequence = 0

    // MARK: - Queue panel (quick popup)

    private let queuePanel = PlaybackQueuePanel()

    // MARK: - Queue page (full in-window panel)

    private(set) var isQueuePageOpen = false

    /// Duration strings keyed by URL, populated lazily via AVFoundation.
    /// Set to "–:––" as a placeholder before the async fetch to prevent re-fetching.
    private var durationCache: [URL: String] = [:]
    private var durationSecondsCache: [URL: Double] = [:]
    private var currentDurationIsProvisional = false
    private var queueSortMode: QueueSortMode = .manual

    var isShowingProvisionalDuration: Bool { currentDurationIsProvisional }

    // MARK: - Layout constants

    private let transportHeight: CGFloat = 48

    private var autoHideTransportEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsWindowController.autoHideKey)
    }

    private var configuredSkipDurationSeconds: Int {
        SettingsWindowController.currentSkipDurationSeconds()
    }

    private var configuredSkipDurationMs: Int {
        configuredSkipDurationSeconds * 1_000
    }

    // MARK: - Init

    init() {
        super.init(window: nil)
        buildWindow()
        buildPlayer()
        startUpdateTimer()
        observeSettings()
        setupQueuePanel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used – UI is programmatic")
    }

    // MARK: - Window construction

    private func buildWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 960, height: 540)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let win = NSWindow(contentRect: contentRect,
                           styleMask: style,
                           backing: .buffered,
                           defer: false)
        win.title = "dwb"
        win.minSize = NSSize(width: 480, height: 180 + transportHeight)
        win.center()
        win.isReleasedWhenClosed = false

        let cv = win.contentView!

        videoSurface = VideoSurfaceView(frame: .zero)
        cv.addSubview(videoSurface)

        transport = TransportControlsView(frame: .zero)
        cv.addSubview(transport)

        volumeBar = VolumeBarView(frame: .zero)
        volumeBar.onVolumeChanged = { [weak self] vol in
            self?.setVolumeFromBar(vol)
        }
        cv.addSubview(volumeBar)

        queuePage = QueuePageView(frame: .zero)
        queuePage.delegate = self
        queuePage.isHidden = true
        cv.addSubview(queuePage)

        self.window = win
        win.delegate = self
        installCenteredTitleLabel(in: win)
        updateWindowTitle("dwb")

        layoutPlayerViews()
        addMouseTracking()
    }

    private func installCenteredTitleLabel(in win: NSWindow) {
        guard let titlebarView = win.standardWindowButton(.closeButton)?.superview else { return }
        win.titleVisibility = .hidden

        centeredTitleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        centeredTitleLabel.textColor = .labelColor
        centeredTitleLabel.alignment = .center
        centeredTitleLabel.lineBreakMode = .byTruncatingMiddle
        centeredTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        centeredTitleLabel.isEditable = false
        centeredTitleLabel.isBordered = false
        centeredTitleLabel.drawsBackground = false
        centeredTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titlebarView.addSubview(centeredTitleLabel)

        let trafficLightWidth: CGFloat = 92
        NSLayoutConstraint.activate([
            centeredTitleLabel.centerXAnchor.constraint(equalTo: titlebarView.centerXAnchor),
            centeredTitleLabel.centerYAnchor.constraint(equalTo: titlebarView.centerYAnchor),
            centeredTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titlebarView.leadingAnchor,
                                                        constant: trafficLightWidth),
            centeredTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: titlebarView.trailingAnchor,
                                                         constant: -trafficLightWidth)
        ])
    }

    private func updateWindowTitle(_ title: String) {
        window?.title = title
        window?.titleVisibility = .hidden
        centeredTitleLabel.stringValue = title
    }

    // MARK: - Player construction

    private func buildPlayer() {
        player = VLCMediaPlayer()
        player.delegate = self
        player.drawable = videoSurface
        player.audio?.volume = persistedVolume
        transport.controller = self
        transport.player = player
        applyScaleMode()
    }

    // MARK: - Queue panel setup (quick popup)

    private func setupQueuePanel() {
        queuePanel.onSelectIndex = { [weak self] displayIdx in
            guard let self = self else { return }
            self.currentDisplayIndex = displayIdx
            self.playCurrentItem(startReason: "quick-queue-select")
        }
        queuePanel.onRenameIndex = { [weak self] displayIdx in
            self?.showRenameSheet(forDisplayIndex: displayIdx)
        }
        queuePanel.onRevealIndex = { [weak self] displayIdx in
            self?.revealInFinder(displayIndex: displayIdx)
        }
        queuePanel.onDeleteIndex = { [weak self] displayIdx in
            self?.removeQueueItem(displayIndex: displayIdx)
        }
    }

    // MARK: - Settings observation

    private func observeSettings() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(autoHideSettingDidChange),
            name: .autoHideSettingChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(transportVisibilityDidChange),
            name: .transportVisibilityChanged,
            object: nil
        )
    }

    @objc private func autoHideSettingDidChange() {
        guard !isFullscreen else { return }
        if autoHideTransportEnabled {
            scheduleHide()
        } else {
            hideHUDTimer?.invalidate()
            transport.alphaValue = 1.0
        }
    }

    @objc private func transportVisibilityDidChange() {
        if !SettingsWindowController.isOptionalTransportControlVisible(.quickQueue) {
            queuePanel.close()
        }
        transport.applyVisibilitySettings()
        layoutPlayerViews()
        transport.update()
    }

    // MARK: - Layout

    private func layoutPlayerViews() {
        guard let cv = window?.contentView else { return }
        let b    = cv.bounds
        let mode = layoutMode   // single source of truth — do not branch on isFullscreen directly
        logLayoutSnapshot("layoutPlayerViews")

        if mode == .fullscreen {
            // Stable fullscreen: full-bleed video with cinematic overlay controls.
            queuePage.isHidden = true

            videoSurface.frame = b
            videoSurface.layer?.frame = b

            transport.frame = b
            transport.layer?.cornerRadius  = 0
            transport.layer?.masksToBounds = false
            transport.setFullscreenStyle(true)

        } else {
            // Windowed baseline — covers both .windowed and .exitingFullscreenSettling.
            // Geometry is derived ONLY from current contentView bounds; no cached
            // fullscreen frames, no screen bounds, no prior transport frames.
            let queueW: CGFloat = isQueuePageOpen
                ? max(260, b.width * 0.45)
                : 0
            let videoW = max(0, b.width - queueW)

            // Do NOT set videoSurface.layer?.frame here.
            // Setting layer.frame = videoSurface.bounds (origin {0,0}) would override
            // AppKit's view-backed layer placement during live resize/fullscreen
            // transitions. The view's own frame is the source of truth; AppKit keeps
            // the backing layer in sync automatically.  (Apr 21 carry-forward fix.)
            videoSurface.frame = NSRect(x: 0, y: 0, width: videoW, height: b.height)

            transport.frame = NSRect(x: 0, y: 0, width: videoW, height: b.height)
            transport.layer?.cornerRadius  = 0
            transport.layer?.masksToBounds = false
            transport.setFullscreenStyle(false)

            if isQueuePageOpen {
                queuePage.isHidden = false
                queuePage.frame = NSRect(x: videoW, y: 0, width: queueW, height: b.height)
            } else {
                queuePage.isHidden = true
            }
        }

        // Volume bar: right side, vertically centred in the video area.
        let barW: CGFloat = 52
        let barH: CGFloat = 186
        let barX = transport.frame.maxX - barW - 12
        let videoAreaBottom: CGFloat = 0
        let videoAreaH = b.height
        let barY = (videoAreaH - barH) / 2
        volumeBar.frame = NSRect(x: barX,
                                 y: max(videoAreaBottom, barY),
                                 width: barW,
                                 height: barH)

        applyScaleMode()
    }

    // MARK: - File open

    func openFile() {
        let panel = NSOpenPanel()
        panel.title = "Open Media"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        handleDroppedURLs(panel.urls, appendingExplicitFiles: false)
    }

    // MARK: - Playback set management

    /// Replace this window's playback set and immediately play the first item.
    private func openAndPlay(set: [URL]) {
        guard !set.isEmpty else { return }
        playbackSet     = set
        displayOrder    = Array(0..<set.count)
        currentDisplayIndex = 0
        if isShuffleOn {
            applyShuffleKeepingCurrent()
        } else {
            applyQueueSortIfNeeded(reason: "open-replace", refreshUI: false)
        }
        playCurrentItem(startReason: "open-replace")
    }

    /// Insert explicit dropped files at the top of this window's existing queue
    /// without replacing the queue. The first inserted item becomes active immediately.
    private func appendToQueue(files: [URL]) {
        guard !files.isEmpty else { return }
        let wasEmpty = playbackSet.isEmpty || displayOrder.isEmpty || currentDisplayIndex < 0
        let start = playbackSet.count
        playbackSet.append(contentsOf: files)

        let newIndices = Array(start..<playbackSet.count)
        displayOrder.insert(contentsOf: newIndices, at: 0)

        NSLog("[dwb-playback] queueInsertTop: count=%d wasEmpty=%d shuffle=%d endless=%d insertedDisplayIdx=%d files=%@",
              files.count,
              wasEmpty ? 1 : 0,
              isShuffleOn ? 1 : 0,
              isEndlessShuffleOn ? 1 : 0,
              0,
              files.map(\.lastPathComponent).joined(separator: ","))

        currentDisplayIndex = 0
        if !isShuffleOn {
            applyQueueSortIfNeeded(reason: "queue-top-insert", refreshUI: false)
        }
        if wasEmpty {
            playCurrentItem(startReason: "queue-top-insert-empty", expectPlaybackHandshake: true)
        } else {
            playCurrentItem(startReason: "queue-top-insert-start", expectPlaybackHandshake: true)
        }
    }

    /// Play the item at `currentDisplayIndex` within `displayOrder`.
    private func playCurrentItem(startReason: String = "direct",
                                 expectPlaybackHandshake: Bool = false,
                                 preserveCompletionSequence: Bool = false,
                                 transitionStrategy: PlaybackTransitionStrategy = .reuseCurrentPlayer) {
        enqueuePlaybackCommand(named: "playCurrentItem-\(startReason)") { [weak self] finish in
            self?.executePlayCurrentItem(startReason: startReason,
                                         expectPlaybackHandshake: expectPlaybackHandshake,
                                         preserveCompletionSequence: preserveCompletionSequence,
                                         transitionStrategy: transitionStrategy)
            finish()
        }
    }

    /// Convenience: sets a one-item playback set.
    func play(url: URL) {
        openAndPlay(set: [url])
    }

    // MARK: - Navigation

    func playPrevious() {
        guard currentDisplayIndex > 0 else { return }
        currentDisplayIndex -= 1
        playCurrentItem(startReason: "manual-previous")
    }

    func playNext() {
        advanceToNextItem(reason: "manual-next")
    }

    // MARK: - Shuffle

    func toggleShuffle() {
        isShuffleOn.toggle()
        if !isShuffleOn {
            isEndlessShuffleOn = false
        }
        if isShuffleOn {
            queueSortMode = .manual
            applyShuffleKeepingCurrent()
        } else {
            restoreNaturalOrder()
        }
        refreshQueueDisplays()
        logPlaybackQueueSnapshot("toggleShuffle")
    }

    /// Shuffle the playback set, keeping the currently playing item at position 0
    /// of the new traversal (already-played context is lost intentionally).
    private func applyShuffleKeepingCurrent() {
        let curPBIdx = currentSetIndex
        var indices = Array(0..<playbackSet.count)
        indices.shuffle()
        if curPBIdx >= 0, let pos = indices.firstIndex(of: curPBIdx) {
            indices.remove(at: pos)
            indices.insert(curPBIdx, at: 0)
        }
        displayOrder = indices
        currentDisplayIndex = 0
    }

    /// Restore natural (non-shuffled) order, keeping the current item at its natural index.
    private func restoreNaturalOrder() {
        let curPBIdx = currentSetIndex
        displayOrder = Array(0..<playbackSet.count)
        currentDisplayIndex = curPBIdx >= 0 ? curPBIdx : 0
        applyQueueSortIfNeeded(reason: "restore-natural-order", refreshUI: false)
    }

    func toggleEndlessShuffle() {
        isEndlessShuffleOn.toggle()
        if isEndlessShuffleOn {
            if isRepeatOne { isRepeatOne = false }
            if !isShuffleOn { isShuffleOn = true }
            queueSortMode = .manual
            applyShuffleKeepingCurrent()
        }
        refreshQueueDisplays()
        logPlaybackQueueSnapshot("toggleEndlessShuffle")
    }

    // MARK: - Repeat

    func toggleRepeat() {
        isRepeatOne.toggle()
        if isRepeatOne {
            isEndlessShuffleOn = false
        }
        transport.update()
        logPlaybackQueueSnapshot("toggleRepeat")
    }

    private var canAdvanceAfterCompletion: Bool {
        guard currentDisplayIndex >= 0, !displayOrder.isEmpty else { return false }
        if currentDisplayIndex < displayOrder.count - 1 { return true }
        return isEndlessShuffleOn && !playbackSet.isEmpty
    }

    @discardableResult
    private func advanceToNextItem(reason: String,
                                   expectPlaybackHandshake: Bool = false,
                                   preserveCompletionSequence: Bool = false,
                                   transitionStrategy: PlaybackTransitionStrategy = .reuseCurrentPlayer) -> Bool {
        guard canAdvanceAfterCompletion else {
            NSLog("[dwb-playback] %@: no next item", reason)
            return false
        }

        if currentDisplayIndex < displayOrder.count - 1 {
            currentDisplayIndex += 1
        } else if isEndlessShuffleOn {
            beginNextEndlessShuffleCycle()
        }

        NSLog("[dwb-playback] %@: advancing to displayIdx=%d endless=%d",
              reason, currentDisplayIndex, isEndlessShuffleOn ? 1 : 0)
        playCurrentItem(startReason: reason,
                        expectPlaybackHandshake: expectPlaybackHandshake,
                        preserveCompletionSequence: preserveCompletionSequence,
                        transitionStrategy: transitionStrategy)
        return true
    }

    private func beginNextEndlessShuffleCycle() {
        let priorSetIndex = currentSetIndex
        var indices = Array(0..<playbackSet.count)
        indices.shuffle()
        if indices.count > 1, indices.first == priorSetIndex,
           let swapIndex = indices.indices.dropFirst().randomElement() {
            indices.swapAt(0, swapIndex)
        }
        displayOrder = indices
        currentDisplayIndex = 0
        NSLog("[dwb-playback] endlessShuffleCycle: priorSetIdx=%d newOrder=[%@]",
              priorSetIndex,
              indices.map(String.init).joined(separator: ","))
    }

    private func applyQueueSortIfNeeded(reason: String,
                                        refreshUI: Bool = true,
                                        preserveCurrentItem: Bool = true) {
        guard queueSortMode != .manual, !displayOrder.isEmpty else {
            if preserveCurrentItem {
                remapCurrentDisplayIndex(toSetIndex: currentSetIndex)
            }
            if refreshUI { refreshQueueDisplays() }
            return
        }

        let currentSetIndex = preserveCurrentItem ? self.currentSetIndex : -1
        displayOrder = stableSortedDisplayOrder(from: displayOrder, mode: queueSortMode)
        if currentSetIndex >= 0 {
            remapCurrentDisplayIndex(toSetIndex: currentSetIndex)
        } else if currentDisplayIndex >= displayOrder.count {
            currentDisplayIndex = max(0, displayOrder.count - 1)
        }

        NSLog("[dwb-playback] queueSortApply: mode=%@ reason=%@ displayIdx=%d order=[%@]",
              queueSortMode.title,
              reason,
              currentDisplayIndex,
              displayOrder.map(String.init).joined(separator: ","))

        if refreshUI { refreshQueueDisplays() }
    }

    private func stableSortedDisplayOrder(from order: [Int], mode: QueueSortMode) -> [Int] {
        let indexedOrder = Array(order.enumerated())
        return indexedOrder.sorted { lhs, rhs in
            let result = compareQueueSort(lhs.element, rhs.element, mode: mode)
            if result != 0 { return result < 0 }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func compareQueueSort(_ lhsSetIndex: Int, _ rhsSetIndex: Int, mode: QueueSortMode) -> Int {
        let lhsURL = playbackURL(forSetIndex: lhsSetIndex)
        let rhsURL = playbackURL(forSetIndex: rhsSetIndex)

        switch mode {
        case .manual:
            return 0
        case .filenameAscending:
            return compareStrings(queueFilenameSortKey(for: lhsURL), queueFilenameSortKey(for: rhsURL))
        case .filenameDescending:
            return compareStrings(queueFilenameSortKey(for: rhsURL), queueFilenameSortKey(for: lhsURL))
        case .fileSizeAscending:
            return compareIntegers(queueFileSizeSortKey(for: lhsURL), queueFileSizeSortKey(for: rhsURL))
        case .fileSizeDescending:
            return compareIntegers(queueFileSizeSortKey(for: rhsURL), queueFileSizeSortKey(for: lhsURL))
        case .durationAscending:
            return compareDurationKeys(lhsURL, rhsURL, ascending: true)
        case .durationDescending:
            return compareDurationKeys(lhsURL, rhsURL, ascending: false)
        }
    }

    private func compareDurationKeys(_ lhsURL: URL?, _ rhsURL: URL?, ascending: Bool) -> Int {
        let lhs = lhsURL.flatMap { durationSecondsCache[$0] }
        let rhs = rhsURL.flatMap { durationSecondsCache[$0] }

        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            if lhs < rhs { return ascending ? -1 : 1 }
            if lhs > rhs { return ascending ? 1 : -1 }
            return 0
        case (nil, nil):
            return 0
        case (nil, _?):
            return ascending ? 1 : -1
        case (_?, nil):
            return ascending ? -1 : 1
        }
    }

    private func compareStrings(_ lhs: String, _ rhs: String) -> Int {
        if lhs < rhs { return -1 }
        if lhs > rhs { return 1 }
        return 0
    }

    private func compareIntegers(_ lhs: Int64, _ rhs: Int64) -> Int {
        if lhs < rhs { return -1 }
        if lhs > rhs { return 1 }
        return 0
    }

    private func queueFilenameSortKey(for url: URL?) -> String {
        url?.lastPathComponent.lowercased() ?? ""
    }

    private func queueFileSizeSortKey(for url: URL?) -> Int64 {
        guard let url else { return 0 }
        return MediaFileSupport.fileSizeBytes(for: url) ?? 0
    }

    private func playbackURL(forSetIndex setIndex: Int) -> URL? {
        guard setIndex >= 0, setIndex < playbackSet.count else { return nil }
        return playbackSet[setIndex]
    }

    private func remapCurrentDisplayIndex(toSetIndex setIndex: Int) {
        guard setIndex >= 0 else {
            currentDisplayIndex = displayOrder.isEmpty ? -1 : min(max(0, currentDisplayIndex), displayOrder.count - 1)
            return
        }
        guard let remappedIndex = displayOrder.firstIndex(of: setIndex) else {
            currentDisplayIndex = displayOrder.isEmpty ? -1 : min(max(0, currentDisplayIndex), displayOrder.count - 1)
            return
        }
        currentDisplayIndex = remappedIndex
    }

    private func refreshQueueDisplays() {
        transport.update()
        refreshQueuePanel()
        if isQueuePageOpen { refreshQueuePage() }
    }

    private func queueTotalDurationText(for urls: [URL]) -> String {
        guard !urls.isEmpty else { return MediaFileSupport.formatClockDuration(0) }

        var knownTotalSeconds = 0
        var knownCount = 0
        var unknownCount = 0

        for url in urls {
            if let seconds = durationSecondsCache[url], seconds > 0 {
                knownTotalSeconds += Int(seconds.rounded(.down))
                knownCount += 1
            } else {
                unknownCount += 1
            }
        }

        guard knownCount > 0 else { return "Unknown" }
        let formatted = MediaFileSupport.formatClockDuration(knownTotalSeconds)
        return unknownCount > 0 ? "\(formatted) +" : formatted
    }

    private func updateDurationCache(for url: URL, metadata: MediaFileSupport.DurationMetadata) {
        durationCache[url] = metadata.displayString
        if let seconds = metadata.seconds, seconds > 0 {
            durationSecondsCache[url] = seconds
        } else {
            durationSecondsCache.removeValue(forKey: url)
        }
    }

    // MARK: - Quick queue popup

    func toggleQueuePanel(relativeTo view: NSView) {
        refreshQueuePanel()
        queuePanel.show(relativeTo: view)
    }

    private func refreshQueuePanel() {
        queuePanel.items = displayOrder.map { playbackSet[$0] }
        queuePanel.currentDisplayIndex = currentDisplayIndex
        if queuePanel.isShown {
            queuePanel.reloadData()
        }
    }

    // MARK: - Queue page (full in-window panel)

    func toggleQueuePage() {
        isQueuePageOpen.toggle()
        if isQueuePageOpen {
            refreshQueuePage()
        }
        layoutPlayerViews()
        transport.update()
    }

    private func refreshQueuePage() {
        let urls = displayOrder.map { playbackSet[$0] }
        var qItems: [QueuePageView.Item] = []

        for url in urls {
            let size = MediaFileSupport.fileSizeString(for: url)
            let dur: String
            if let cached = durationCache[url] {
                dur = cached
            } else {
                // Set placeholder to prevent re-triggering; kick off async fetch.
                let placeholder = MediaFileSupport.needsStableDuration(url)
                    ? MediaFileSupport.durationLoadingText
                    : "–:––"
                durationCache[url] = placeholder
                let capturedURL = url
                MediaFileSupport.loadDurationMetadata(for: url) { [weak self] metadata in
                    guard let self = self else { return }
                    self.updateDurationCache(for: capturedURL, metadata: metadata)
                    if self.queueSortMode == .durationAscending || self.queueSortMode == .durationDescending {
                        self.applyQueueSortIfNeeded(reason: "duration-metadata-update")
                    } else if self.isQueuePageOpen {
                        self.refreshQueuePage()
                    }
                }
                dur = placeholder
            }
            qItems.append(QueuePageView.Item(
                url: url,
                displayName: url.lastPathComponent,
                duration: dur,
                fileSize: size
            ))
        }

        queuePage.update(items: qItems,
                         currentIndex: currentDisplayIndex,
                         sortMode: queueSortMode,
                         totalDurationText: queueTotalDurationText(for: urls))
    }

    // MARK: - Reveal in Finder

    func revealInFinder() {
        guard let url = currentMediaURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealInFinder(displayIndex: Int) {
        guard let url = urlForDisplayIndex(displayIndex) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func urlForDisplayIndex(_ displayIndex: Int) -> URL? {
        guard displayIndex >= 0, displayIndex < displayOrder.count else { return nil }
        let pbIdx = displayOrder[displayIndex]
        guard pbIdx >= 0, pbIdx < playbackSet.count else { return nil }
        return playbackSet[pbIdx]
    }

    // MARK: - Rename (menu entry point — renames current item)

    func showRenameSheet() {
        showRenameSheet(forDisplayIndex: currentDisplayIndex)
    }

    /// Shows the rename sheet for the item at the given display-order index.
    func showRenameSheet(forDisplayIndex displayIndex: Int) {
        guard displayIndex >= 0, displayIndex < displayOrder.count else { return }
        let pbIdx = displayOrder[displayIndex]
        guard pbIdx >= 0, pbIdx < playbackSet.count, let win = window else { return }

        let url  = playbackSet[pbIdx]
        let ext  = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent

        let alert = NSAlert()
        alert.messageText     = "Rename File"
        alert.informativeText = "New name for \"\(url.lastPathComponent)\":"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue       = stem
        field.placeholderString = ext.isEmpty ? "filename" : "filename.\(ext)"
        alert.accessoryView     = field

        alert.beginSheetModal(for: win) { [weak self, weak field] response in
            guard response == .alertFirstButtonReturn,
                  let self = self,
                  let field = field else { return }
            let newStem = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newStem.isEmpty else { return }
            let newName = ext.isEmpty ? newStem : "\(newStem).\(ext)"
            self.renameFile(at: pbIdx, to: newName)
        }

        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
    }

    func removeCurrentQueueItem() {
        removeQueueItem(displayIndex: currentDisplayIndex)
    }

    func removeQueueItem(displayIndex: Int) {
        guard displayIndex >= 0, displayIndex < displayOrder.count else { return }
        let removedSetIndex = displayOrder[displayIndex]
        guard removedSetIndex >= 0, removedSetIndex < playbackSet.count else { return }

        let removingCurrent = displayIndex == currentDisplayIndex
        let removedURL = playbackSet[removedSetIndex]
        NSLog("[dwb-playback] queueDelete: displayIdx=%d setIdx=%d current=%d file=%@",
              displayIndex, removedSetIndex, removingCurrent ? 1 : 0, removedURL.lastPathComponent)

        displayOrder.remove(at: displayIndex)
        playbackSet.remove(at: removedSetIndex)
        durationCache.removeValue(forKey: removedURL)
        durationSecondsCache.removeValue(forKey: removedURL)
        displayOrder = displayOrder.map { $0 > removedSetIndex ? $0 - 1 : $0 }

        if playbackSet.isEmpty || displayOrder.isEmpty {
            if removingCurrent, player.media != nil {
                enqueueStopPlaybackCommand(reason: "queue-delete-empty")
            }
            currentDisplayIndex = -1
            currentMediaURL = nil
            currentDurationIsProvisional = false
            updateWindowTitle("dwb")
            transport.update()
            refreshQueuePanel()
            if isQueuePageOpen { refreshQueuePage() }
            logPlaybackQueueSnapshot("queueDelete-empty")
            return
        }

        if removingCurrent {
            currentDisplayIndex = min(displayIndex, displayOrder.count - 1)
            playCurrentItem(startReason: "queue-delete-current")
        } else {
            if displayIndex < currentDisplayIndex {
                currentDisplayIndex -= 1
            } else if currentDisplayIndex >= displayOrder.count {
                currentDisplayIndex = displayOrder.count - 1
            }
            transport.update()
            refreshQueuePanel()
            if isQueuePageOpen { refreshQueuePage() }
            logPlaybackQueueSnapshot("queueDelete")
        }
    }

    /// Core rename logic: moves the file on disk and updates all in-memory references.
    private func renameFile(at playbackSetIndex: Int, to newName: String) {
        guard playbackSetIndex >= 0, playbackSetIndex < playbackSet.count,
              let win = window else { return }

        let url    = playbackSet[playbackSetIndex]
        let dir    = url.deletingLastPathComponent()
        let newURL = dir.appendingPathComponent(newName)

        if FileManager.default.fileExists(atPath: newURL.path) {
            let alert = NSAlert()
            alert.messageText     = "Cannot Rename"
            alert.informativeText = "A file named \"\(newName)\" already exists in this folder."
            alert.alertStyle      = .warning
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: win)
            return
        }

        do {
            try FileManager.default.moveItem(at: url, to: newURL)
        } catch {
            let alert = NSAlert()
            alert.messageText     = "Rename Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle      = .warning
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: win)
            return
        }

        // Update master list and caches
        playbackSet[playbackSetIndex] = newURL
        durationCache.removeValue(forKey: url)   // clear old key; new one fetched on demand
        durationSecondsCache.removeValue(forKey: url)

        if playbackSetIndex == currentSetIndex {
            currentMediaURL = newURL
            updateWindowTitle(newURL.lastPathComponent)
        }

        applyQueueSortIfNeeded(reason: "rename")
        // Note: VLC continues playing from the already-open file descriptor;
        // the new path takes effect the next time playCurrentItem() is called.
    }

    // MARK: - Fullscreen toggle

    func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    // MARK: - Drop / open URL handling

    func handleDroppedURLs(_ urls: [URL], appendingExplicitFiles: Bool = true) {
        var dirs:  [URL] = []
        var files: [URL] = []

        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue { dirs.append(url) } else { files.append(url) }
        }

        if !dirs.isEmpty && !files.isEmpty {
            showDropError(
                "Mixed files and folder drops are not supported.\nDrop media files only, or drop a single folder.",
                title: "Mixed Drop Not Supported")
            return
        }

        if dirs.count > 1 {
            showDropError("Drop a single folder to play its contents.",
                          title: "Multiple Folders Not Supported")
            return
        }

        if dirs.count == 1 {
            let folder = dirs[0]
            let folderFiles = MediaFileSupport.sortedSupportedFiles(inFolder: folder)
            guard !folderFiles.isEmpty else {
                showDropError(
                    "No supported media files found in \"\(folder.lastPathComponent)\".",
                    title: "Nothing to Play")
                return
            }
            openAndPlay(set: folderFiles)
            return
        }

        let supported = files.filter { MediaFileSupport.isSupported($0) }
        guard !supported.isEmpty else {
            let ext = MediaFileSupport.supportedExtensions.sorted().joined(separator: ", ")
            showDropError(
                "None of the dropped files are supported media.\n\nSupported: \(ext)",
                title: "Unsupported Files")
            return
        }
        if appendingExplicitFiles {
            appendToQueue(files: supported)
        } else {
            openAndPlay(set: supported)
        }
    }

    func handleDroppedURL(_ url: URL) {
        handleDroppedURLs([url], appendingExplicitFiles: true)
    }

    private func showDropError(_ message: String, title: String) {
        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.messageText    = title
            alert.informativeText = message
            alert.alertStyle     = .warning
            alert.addButton(withTitle: "OK")
            if let window = self?.window { alert.beginSheetModal(for: window) }
        }
    }

    // MARK: - Playback controls

    func togglePlayPause() {
        enqueuePlaybackCommand(named: "togglePlayPause") { [weak self] finish in
            guard let self = self else {
                finish()
                return
            }
            guard self.player.media != nil else {
                finish()
                return
            }
            if self.player.isPlaying {
                self.player.pause()
            } else {
                self.player.play()
            }
            finish()
        }
    }

    func stopPlayback() {
        enqueueStopPlaybackCommand(reason: "user-stop")
    }

    /// Called by TransportControlsView and internal seek methods whenever a user-initiated
    /// seek is committed. Resets lastKnownPosition so a stale near-end position captured
    /// before the seek doesn't falsely qualify as natural-EOF position evidence.
    /// Sets lastUserSeekDate so the .stopped handler knows to distrust position heuristics
    /// for the next 1.5 s (require naturalEOFDetected instead).
    func notifyUserSeek(targetPosition: Float? = nil, source: String) {
        lastUserSeekDate  = Date()
        lastKnownPosition = 0
        let target = targetPosition ?? -1
        NSLog("[dwb-playback] notifyUserSeek: source=%@ current=%.3f target=%.3f — lastKnownPosition reset, seek guard active",
              source, player?.position ?? 0, target)
    }

    func clampedUserSeekPosition(_ rawPosition: Float, source: String) -> Float {
        guard rawPosition.isFinite else { return 0 }
        let bounded = max(0, min(1, rawPosition))
        let clamped = min(bounded, maxUserSeekPosition)
        if clamped != bounded {
            NSLog("[dwb-playback] seekClamp: source=%@ requested=%.3f clamped=%.3f maxUserSeek=%.3f",
                  source, bounded, clamped, maxUserSeekPosition)
        }
        return clamped
    }

    func skipBackward10() {
        skipByConfiguredDuration(isForward: false)
    }

    func skipForward10() {
        skipByConfiguredDuration(isForward: true)
    }

    private func skipByConfiguredDuration(isForward: Bool) {
        guard let media = player.media else { return }
        let durationMs = max(Int(media.length.intValue), lastKnownDurationMs)
        guard durationMs > 0 else { return }

        let baseMs = currentSeekBaseTimeMs(durationMs: durationMs)
        let stepMs = configuredSkipDurationMs
        let source = isForward ? "skipForward" : "skipBackward"

        let targetMs: Int
        let rule: String
        if isForward {
            let remainingMs = max(0, durationMs - baseMs)
            if remainingMs > stepMs {
                targetMs = min(durationMs, baseMs + stepMs)
                rule = "exact-forward"
            } else {
                targetMs = safePreEOFTargetTimeMs(durationMs: durationMs, baseMs: baseMs)
                rule = targetMs > baseMs ? "clamp-safe-pre-eof" : "already-near-eof"
            }
        } else {
            targetMs = max(0, baseMs - stepMs)
            rule = "exact-backward"
        }

        seekPlayer(toTimeMs: targetMs,
                   durationMs: durationMs,
                   baseTimeMs: baseMs,
                   source: source,
                   requestedSkipMs: stepMs,
                   rule: rule)
        resetSeekTargetAfterDelay()
    }

    private func currentSeekBaseTimeMs(durationMs: Int) -> Int {
        if let pending = seekTargetMs {
            return max(0, min(durationMs, pending))
        }

        let timeMs = Int(player.time.intValue)
        if timeMs > 0 {
            return max(0, min(durationMs, timeMs))
        }

        let position = player.position
        if position.isFinite, position > 0 {
            let estimatedMs = Int((Double(position) * Double(durationMs)).rounded())
            return max(0, min(durationMs, estimatedMs))
        }

        return 0
    }

    private func safePreEOFTargetTimeMs(durationMs: Int, baseMs: Int) -> Int {
        let safePositionMs = Int((Double(durationMs) * Double(maxUserSeekPosition)).rounded(.down))
        return max(baseMs, min(durationMs, safePositionMs))
    }

    private func seekPlayer(toTimeMs targetMs: Int,
                            durationMs: Int,
                            baseTimeMs: Int,
                            source: String,
                            requestedSkipMs: Int,
                            rule: String) {
        let safeTargetMs = max(0, min(durationMs, targetMs))
        let targetPosition = durationMs > 0
            ? max(0, min(1, Float(safeTargetMs) / Float(durationMs)))
            : 0
        let targetTime = VLCTime(int: Int32(min(safeTargetMs, Int(Int32.max))))
        seekTargetMs = safeTargetMs
        NSLog("[dwb-playback] %@: base=%dms target=%dms pos=%.3f dur=%dms step=%dms rule=%@",
              source,
              baseTimeMs,
              safeTargetMs,
              targetPosition,
              durationMs,
              requestedSkipMs,
              rule)
        notifyUserSeek(targetPosition: targetPosition, source: source)
        player.time = targetTime
        transport.notifySeek(to: targetPosition)
    }

    private func resetSeekTargetAfterDelay() {
        seekTargetResetTimer?.invalidate()
        seekTargetResetTimer = Timer.scheduledTimer(withTimeInterval: 0.5,
                                                    repeats: false) { [weak self] _ in
            self?.seekTargetMs = nil
        }
    }

    private func clearPlaybackCompletionEvidence() {
        naturalEOFDetected = false
        lastKnownPosition = 0
        lastKnownTimeMs = 0
        lastKnownDurationMs = 0
        positionAtEndedEvent = 0
        lastUserSeekDate = nil
        lastPlayingDate = nil
        lastProgressDate = nil
        lastStoppedDate = nil
        lastStoppedPosition = 0
        lastStoppedMediaURL = nil
    }

    private func clearStoppedSuppression() {
        suppressNextStopped = false
        suppressNextStoppedDate = nil
    }

    private func clearCompletionSequence(reason: String, suppressLog: Bool = false) {
        guard let sequence = activeCompletionSequence else { return }
        if !suppressLog {
            NSLog("[dwb-playback] completionSequenceClear: seq=%d action=%@ reason=%@",
                  sequence.id, sequence.action.rawValue, reason)
        }
        activeCompletionSequence = nil
    }

    private func resetPlaybackCompletionSignals(reason: String,
                                               preserveCompletionSequence: Bool = false) {
        cancelScheduledPlaybackAction(reason: reason)
        clearPlaybackCompletionEvidence()
        clearStoppedSuppression()
        cancelReplacementStart(reason: reason)
        cancelPlaybackStartHandshake(reason: reason)
        if !preserveCompletionSequence {
            clearCompletionSequence(reason: reason, suppressLog: true)
        }
    }

    private func enqueuePlaybackCommand(named name: String,
                                        action: @escaping PlaybackCommandAction) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.enqueuePlaybackCommand(named: name, action: action)
            }
            return
        }

        playbackCommandSequence += 1
        let command = QueuedPlaybackCommand(id: playbackCommandSequence,
                                            name: name,
                                            action: action)
        queuedPlaybackCommands.append(command)
        NSLog("[dwb-playback] commandEnqueue: id=%d name=%@ queued=%d",
              command.id,
              command.name,
              queuedPlaybackCommands.count)
        runNextPlaybackCommandIfNeeded()
    }

    private func runNextPlaybackCommandIfNeeded() {
        guard !isExecutingPlaybackCommand, !queuedPlaybackCommands.isEmpty else { return }
        let command = queuedPlaybackCommands.removeFirst()
        isExecutingPlaybackCommand = true
        NSLog("[dwb-playback] commandStart: id=%d name=%@ remaining=%d",
              command.id,
              command.name,
              queuedPlaybackCommands.count)
        command.action { [weak self] in
            guard let self = self else { return }
            self.isExecutingPlaybackCommand = false
            NSLog("[dwb-playback] commandFinish: id=%d name=%@ pending=%d",
                  command.id,
                  command.name,
                  self.queuedPlaybackCommands.count)
            self.runNextPlaybackCommandIfNeeded()
        }
    }

    private func enqueueStopPlaybackCommand(reason: String) {
        enqueuePlaybackCommand(named: "stop-\(reason)") { [weak self] finish in
            self?.executeStopPlayback(reason: reason)
            finish()
        }
    }

    private func executeStopPlayback(reason: String) {
        resetPlaybackCompletionSignals(reason: reason)
        queuedPlaybackCommands.removeAll()
        isUserStop = true
        seekTargetMs = nil
        seekTargetResetTimer?.invalidate()
        NSLog("[dwb-playback] stopPlayback: reason=%@ userStop=1 cancelPendingAutoplay=1", reason)
        player.stop()
        if reason == "user-stop" {
            openQueuePageAfterUserStop()
        } else {
            transport.update()
        }
    }

    private func openQueuePageAfterUserStop() {
        isQueuePageOpen = true
        refreshQueuePage()
        layoutPlayerViews()
        transport.update()
    }

    private func executePlayCurrentItem(startReason: String,
                                        expectPlaybackHandshake: Bool,
                                        preserveCompletionSequence: Bool,
                                        transitionStrategy: PlaybackTransitionStrategy) {
        let idx = currentSetIndex
        guard idx >= 0, idx < playbackSet.count else {
            NSLog("[dwb-playback] playCurrentItem: reason=%@ ignored-invalid-index displayIdx=%d/%d",
                  startReason,
                  currentDisplayIndex,
                  displayOrder.count)
            return
        }

        let url = playbackSet[idx]
        let hadExistingMedia = player.media != nil
        seekTargetMs = nil
        seekTargetResetTimer?.invalidate()
        currentPlaybackSessionID += 1
        resetPlaybackCompletionSignals(reason: "playCurrentItem-\(startReason)",
                                       preserveCompletionSequence: preserveCompletionSequence)

        NSLog("[dwb-playback] playCurrentItem: reason=%@ displayIdx=%d/%d url=%@ mediaWasNonNil=%d expectHandshake=%d preserveCompletion=%d session=%d transition=%@",
              startReason,
              currentDisplayIndex,
              displayOrder.count,
              url.lastPathComponent,
              hadExistingMedia ? 1 : 0,
              expectPlaybackHandshake ? 1 : 0,
              preserveCompletionSequence ? 1 : 0,
              currentPlaybackSessionID,
              transitionStrategy.rawValue)

        currentMediaURL = url
        let cachedDuration = durationCache[url]
        currentDurationIsProvisional = MediaFileSupport.needsStableDuration(url) &&
            (cachedDuration == nil || cachedDuration == MediaFileSupport.durationLoadingText)
        if currentDurationIsProvisional {
            durationCache[url] = MediaFileSupport.durationLoadingText
            MediaFileSupport.loadDurationMetadata(for: url) { [weak self] metadata in
                guard let self = self else { return }
                self.updateDurationCache(for: url, metadata: metadata)
                if self.currentMediaURL == url {
                    self.currentDurationIsProvisional = false
                    self.transport.update()
                }
                if self.queueSortMode == .durationAscending || self.queueSortMode == .durationDescending {
                    self.applyQueueSortIfNeeded(reason: "current-duration-update")
                } else if self.isQueuePageOpen {
                    self.refreshQueuePage()
                }
            }
        }

        logPlaybackQueueSnapshot("playCurrentItem")
        updateWindowTitle(url.lastPathComponent)
        transport.update()
        refreshQueuePanel()
        if isQueuePageOpen { refreshQueuePage() }

        switch transitionStrategy {
        case .freshPlayer:
            startPlaybackWithFreshPlayer(url: url,
                                         startReason: startReason,
                                         sessionID: currentPlaybackSessionID,
                                         expectPlaybackHandshake: expectPlaybackHandshake)
        case .reuseCurrentPlayer:
            scheduleReplacementStart(url: url,
                                     startReason: startReason,
                                     sessionID: currentPlaybackSessionID,
                                     expectPlaybackHandshake: expectPlaybackHandshake,
                                     transitionStrategy: transitionStrategy,
                                     after: hadExistingMedia ? replacementStartDelay : 0)
        }
    }

    private func cancelScheduledPlaybackAction(reason: String) {
        guard scheduledPlaybackAction != nil else { return }
        NSLog("[dwb-playback] autoplayCancel: reason=%@", reason)
        scheduledPlaybackAction?.cancel()
        scheduledPlaybackAction = nil
    }

    private func schedulePlaybackAction(named name: String,
                                        after delay: TimeInterval,
                                        action: @escaping () -> Void) {
        cancelScheduledPlaybackAction(reason: "reschedule-\(name)")
        NSLog("[dwb-playback] autoplaySchedule: action=%@ delay=%.2fs", name, delay)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.scheduledPlaybackAction = nil
            NSLog("[dwb-playback] autoplayExecute: action=%@", name)
            action()
        }
        scheduledPlaybackAction = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelReplacementStart(reason: String, suppressLog: Bool = false) {
        let hadPending = replacementStartWorkItem != nil
        replacementStartWorkItem?.cancel()
        replacementStartWorkItem = nil
        if hadPending && !suppressLog {
            NSLog("[dwb-playback] replacementStartCancel: reason=%@", reason)
        }
    }

    private func scheduleReplacementStart(url: URL,
                                          startReason: String,
                                          sessionID: Int,
                                          expectPlaybackHandshake: Bool,
                                          transitionStrategy: PlaybackTransitionStrategy,
                                          after delay: TimeInterval) {
        cancelReplacementStart(reason: "reschedule-\(startReason)", suppressLog: true)
        replacementStartSequence += 1
        let sequence = replacementStartSequence
        if player.media != nil {
            suppressNextStopped = true
            suppressNextStoppedDate = Date()
            NSLog("[dwb-playback] playCurrentItem: suppressNextStopped=1 (replacing existing media)")
            NSLog("[dwb-playback] playCurrentItem: replacementTeardown explicitStop=1 oldMedia=%@ oldState=%d delay=%.2fs",
                  player.media?.url?.lastPathComponent ?? "—",
                  player.state.rawValue,
                  delay)
            player.stop()
        } else {
            NSLog("[dwb-playback] playCurrentItem: replacementTeardown explicitStop=0 oldMedia=%@ oldState=%d delay=0.00s",
                  "—",
                  player.state.rawValue)
        }
        NSLog("[dwb-playback] replacementStartSchedule: id=%d reason=%@ delay=%.2fs targetMedia=%@ transition=%@",
              sequence,
              startReason,
              delay,
              url.lastPathComponent,
              transitionStrategy.rawValue)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.replacementStartSequence == sequence else { return }
            self.replacementStartWorkItem = nil
            NSLog("[dwb-playback] playCurrentItem: replacementStartExecute id=%d reason=%@ media=%@ transition=%@",
                  sequence,
                  startReason,
                  url.lastPathComponent,
                  transitionStrategy.rawValue)
            NSLog("[dwb-playback] playCurrentItem: before player.media = %@ reason=%@ currentState=%d oldMedia=%@",
                  url.lastPathComponent,
                  startReason,
                  self.player.state.rawValue,
                  self.player.media?.url?.lastPathComponent ?? "—")
            let media = VLCMedia(url: url)
            self.player.media = media
            NSLog("[dwb-playback] playCurrentItem: assignedMedia=%@ reason=%@",
                  url.lastPathComponent,
                  startReason)
            if expectPlaybackHandshake {
                self.armPlaybackStartHandshake(reason: startReason,
                                               expectedURL: url,
                                               expectedSessionID: sessionID,
                                               transitionStrategy: transitionStrategy)
            } else {
                self.cancelPlaybackStartHandshake(reason: "playCurrentItem-\(startReason)-no-handshake")
            }
            NSLog("[dwb-playback] playCurrentItem: before player.play() reason=%@ state=%d media=%@",
                  startReason,
                  self.player.state.rawValue,
                  self.player.media?.url?.lastPathComponent ?? "—")
            self.player.play()
            NSLog("[dwb-playback] playCurrentItem: after player.play() reason=%@ state=%d isPlaying=%d media=%@",
                  startReason,
                  self.player.state.rawValue,
                  self.player.isPlaying ? 1 : 0,
                  self.player.media?.url?.lastPathComponent ?? "—")
        }

        replacementStartWorkItem = workItem
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else {
            workItem.perform()
        }
    }

    private func armPlaybackStartHandshake(reason: String,
                                           expectedURL: URL,
                                           expectedSessionID: Int,
                                           transitionStrategy: PlaybackTransitionStrategy) {
        cancelPlaybackStartHandshake(reason: "rearm-\(reason)")
        playbackStartHandshakeSequence += 1
        let handshake = PlaybackStartHandshake(id: playbackStartHandshakeSequence,
                                               reason: reason,
                                               expectedURL: expectedURL,
                                               expectedSessionID: expectedSessionID,
                                               transitionStrategy: transitionStrategy,
                                               baselinePosition: player.position,
                                               baselineTimeMs: Int(player.time.intValue),
                                               playRetryCount: 0,
                                               progressRetryCount: 0,
                                               sawPlaying: false,
                                               recoveryUsed: false)
        playbackStartHandshake = handshake
        NSLog("[dwb-playback] handshakeArm: id=%d reason=%@ expectedMedia=%@ session=%d transition=%@ baselineTimeMs=%d baselinePos=%.3f",
              handshake.id,
              reason,
              expectedURL.lastPathComponent,
              expectedSessionID,
              transitionStrategy.rawValue,
              handshake.baselineTimeMs,
              handshake.baselinePosition)
        schedulePlaybackStartHandshakeCheck(for: handshake.id)
    }

    private func cancelPlaybackStartHandshake(reason: String, suppressLog: Bool = false) {
        let hadHandshake = playbackStartHandshake != nil || playbackStartHandshakeWorkItem != nil
        playbackStartHandshakeWorkItem?.cancel()
        playbackStartHandshakeWorkItem = nil
        playbackStartHandshake = nil
        if hadHandshake && !suppressLog {
            NSLog("[dwb-playback] handshakeCancel: reason=%@", reason)
        }
    }

    private func schedulePlaybackStartHandshakeCheck(for id: Int) {
        playbackStartHandshakeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.verifyPlaybackStartHandshake(id: id)
        }
        playbackStartHandshakeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + playbackStartCheckInterval, execute: workItem)
    }

    private func verifyPlaybackStartHandshake(id: Int) {
        guard var handshake = playbackStartHandshake, handshake.id == id else { return }
        playbackStartHandshakeWorkItem = nil

        let currentMediaURL = player.media?.url
        let mediaAssigned = currentMediaURL?.path == handshake.expectedURL.path
        let currentMediaName = currentMediaURL?.lastPathComponent ?? "—"
        let stateRaw = player.state.rawValue
        let started = player.isPlaying || player.state == .playing
        let timeMs = Int(player.time.intValue)
        let position = player.position
        let progressConfirmed = playbackProgressConfirmed(for: handshake,
                                                          currentTimeMs: timeMs,
                                                          currentPosition: position)

        NSLog("[dwb-playback] handshakeCheck: id=%d reason=%@ mediaAssigned=%d state=%d isPlaying=%d sawPlaying=%d playRetry=%d progressRetry=%d recovery=%d currentMedia=%@ timeMs=%d pos=%.3f progress=%d session=%d/%d transition=%@",
              handshake.id,
              handshake.reason,
              mediaAssigned ? 1 : 0,
              stateRaw,
              started ? 1 : 0,
              handshake.sawPlaying ? 1 : 0,
              handshake.playRetryCount,
              handshake.progressRetryCount,
              handshake.recoveryUsed ? 1 : 0,
              currentMediaName,
              timeMs,
              position,
              progressConfirmed ? 1 : 0,
              currentPlaybackSessionID,
              handshake.expectedSessionID,
              handshake.transitionStrategy.rawValue)

        guard currentPlaybackSessionID == handshake.expectedSessionID else {
            NSLog("[dwb-playback] handshakeCheck: id=%d reason=%@ session moved on — abandoning",
                  handshake.id, handshake.reason)
            cancelPlaybackStartHandshake(reason: "session-moved", suppressLog: true)
            clearCompletionSequence(reason: "handshake-session-moved", suppressLog: true)
            return
        }

        guard mediaAssigned else {
            NSLog("[dwb-playback] handshakeCheck: id=%d reason=%@ media changed before start — abandoning",
                  handshake.id, handshake.reason)
            cancelPlaybackStartHandshake(reason: "media-changed", suppressLog: true)
            clearCompletionSequence(reason: "handshake-media-changed", suppressLog: true)
            return
        }

        if started && !handshake.sawPlaying {
            handshake.sawPlaying = true
            playbackStartHandshake = handshake
            NSLog("[dwb-playback] handshakeFirstPlaying: id=%d reason=%@ media=%@ transition=%@",
                  handshake.id,
                  handshake.reason,
                  handshake.expectedURL.lastPathComponent,
                  handshake.transitionStrategy.rawValue)
        }

        if progressConfirmed && (handshake.sawPlaying || started) {
            NSLog("[dwb-playback] handshakeCheck: id=%d reason=%@ final=success progressConfirmed=1 timeMs=%d pos=%.3f",
                  handshake.id,
                  handshake.reason,
                  timeMs,
                  position)
            cancelPlaybackStartHandshake(reason: "progress-confirmed", suppressLog: true)
            clearCompletionSequence(reason: "handshake-success", suppressLog: true)
            return
        }

        if handshake.sawPlaying || started {
            if handshake.progressRetryCount < maxPlaybackProgressConfirmationRetries {
                handshake.progressRetryCount += 1
                handshake.sawPlaying = true
                playbackStartHandshake = handshake
                NSLog("[dwb-playback] handshakeTransientPlayingNoProgress: id=%d reason=%@ retry=%d target=%@ timeMs=%d pos=%.3f",
                      handshake.id,
                      handshake.reason,
                      handshake.progressRetryCount,
                      handshake.expectedURL.lastPathComponent,
                      timeMs,
                      position)
                player.play()
                schedulePlaybackStartHandshakeCheck(for: handshake.id)
                return
            }

            if handshake.transitionStrategy == .reuseCurrentPlayer && !handshake.recoveryUsed {
                handshake.recoveryUsed = true
                handshake.playRetryCount = 0
                handshake.progressRetryCount = 0
                handshake.sawPlaying = false
                playbackStartHandshake = handshake
                NSLog("[dwb-playback] handshakeRecovery: id=%d reason=%@ recovery=fresh-player target=%@",
                      handshake.id,
                      handshake.reason,
                      handshake.expectedURL.lastPathComponent)
                rebuildPlayerAfterFailedStart(for: handshake)
                schedulePlaybackStartHandshakeCheck(for: handshake.id)
                return
            }

            NSLog("[dwb-playback] handshakeCheck: id=%d reason=%@ final=failure target=%@ failure=no-progress",
                  handshake.id,
                  handshake.reason,
                  handshake.expectedURL.lastPathComponent)
            cancelPlaybackStartHandshake(reason: "progress-retry-exhausted", suppressLog: true)
            clearCompletionSequence(reason: "handshake-no-progress")
            return
        }

        if handshake.playRetryCount < maxPlaybackStartRetries {
            handshake.playRetryCount += 1
            playbackStartHandshake = handshake
            NSLog("[dwb-playback] handshakeRetry: id=%d reason=%@ player.play() retry=%d target=%@",
                  handshake.id,
                  handshake.reason,
                  handshake.playRetryCount,
                  handshake.expectedURL.lastPathComponent)
            player.play()
            schedulePlaybackStartHandshakeCheck(for: handshake.id)
            return
        }

        if handshake.transitionStrategy == .reuseCurrentPlayer && !handshake.recoveryUsed {
            handshake.recoveryUsed = true
            handshake.playRetryCount = 0
            handshake.progressRetryCount = 0
            playbackStartHandshake = handshake
            NSLog("[dwb-playback] handshakeRecovery: id=%d reason=%@ rebuilding player for target=%@",
                  handshake.id,
                  handshake.reason,
                  handshake.expectedURL.lastPathComponent)
            rebuildPlayerAfterFailedStart(for: handshake)
            schedulePlaybackStartHandshakeCheck(for: handshake.id)
            return
        }

        NSLog("[dwb-playback] handshakeCheck: id=%d reason=%@ final=failure target=%@ failure=no-playing",
              handshake.id,
              handshake.reason,
              handshake.expectedURL.lastPathComponent)
        cancelPlaybackStartHandshake(reason: "retry-exhausted", suppressLog: true)
        clearCompletionSequence(reason: "handshake-failure")
    }

    private func rebuildPlayerAfterFailedStart(for handshake: PlaybackStartHandshake) {
        let rebuiltPlayer = installFreshPlayer(reason: "handshake-recovery",
                                               targetURL: handshake.expectedURL,
                                               stopOldPlayer: true)

        rebuiltPlayer.media = VLCMedia(url: handshake.expectedURL)
        NSLog("[dwb-playback] handshakeRecovery: id=%d assignedMedia=%@ session=%d volume=%d",
              handshake.id,
              handshake.expectedURL.lastPathComponent,
              handshake.expectedSessionID,
              rebuiltPlayer.audio?.volume ?? persistedVolume)
        rebuiltPlayer.play()
        transport.update()
    }

    private func startPlaybackWithFreshPlayer(url: URL,
                                              startReason: String,
                                              sessionID: Int,
                                              expectPlaybackHandshake: Bool) {
        clearStoppedSuppression()
        let freshPlayer = installFreshPlayer(reason: startReason,
                                             targetURL: url,
                                             stopOldPlayer: true)
        freshPlayer.media = VLCMedia(url: url)
        NSLog("[dwb-playback] autoplayTransition: target=%@ assignedMedia=1 reason=%@",
              url.lastPathComponent,
              startReason)
        if expectPlaybackHandshake {
            armPlaybackStartHandshake(reason: startReason,
                                      expectedURL: url,
                                      expectedSessionID: sessionID,
                                      transitionStrategy: .freshPlayer)
        } else {
            cancelPlaybackStartHandshake(reason: "playCurrentItem-\(startReason)-no-handshake")
        }
        NSLog("[dwb-playback] autoplayTransition: target=%@ playCall=1 reason=%@",
              url.lastPathComponent,
              startReason)
        freshPlayer.play()
    }

    @discardableResult
    private func installFreshPlayer(reason: String,
                                    targetURL: URL,
                                    stopOldPlayer: Bool) -> VLCMediaPlayer {
        let oldPlayer = player
        let volume = oldPlayer?.audio?.volume ?? persistedVolume
        let oldMedia = oldPlayer?.media?.url?.lastPathComponent ?? "—"
        let oldState = oldPlayer?.state.rawValue ?? -1
        if stopOldPlayer, oldPlayer != nil {
            NSLog("[dwb-playback] autoplayTransition: reason=%@ target=%@ oldPlayerDetach=1 oldPlayerStop=1 oldMedia=%@ oldState=%d",
                  reason,
                  targetURL.lastPathComponent,
                  oldMedia,
                  oldState)
            oldPlayer?.delegate = nil
            oldPlayer?.drawable = nil
            oldPlayer?.stop()
        }

        let freshPlayer = VLCMediaPlayer()
        freshPlayer.delegate = self
        freshPlayer.drawable = videoSurface
        player = freshPlayer
        transport.controller = self
        transport.player = freshPlayer
        freshPlayer.audio?.volume = volume
        applyScaleMode()
        NSLog("[dwb-playback] autoplayTransition: reason=%@ target=%@ newPlayerCreate=1 delegate=1 drawable=1 transport=1 volume=%d scale=%@",
              reason,
              targetURL.lastPathComponent,
              volume,
              scaleModeLogName())
        return freshPlayer
    }

    private func playbackProgressConfirmed(for handshake: PlaybackStartHandshake,
                                           currentTimeMs: Int,
                                           currentPosition: Float) -> Bool {
        let timeAdvanced = currentTimeMs >= (handshake.baselineTimeMs + playbackStartProgressAdvanceMs)
        let positionAdvanced = currentPosition.isFinite &&
            currentPosition >= (handshake.baselinePosition + playbackStartProgressAdvancePosition)
        return timeAdvanced || positionAdvanced
    }

    private func scaleModeLogName() -> String {
        switch scaleMode {
        case .fit:
            return "fit"
        case .fill:
            return "fill"
        case .stretch:
            return "stretch"
        }
    }

    private func completionActionForCurrentState() -> PlaybackCompletionAction {
        if isRepeatOne { return .repeatCurrent }
        if currentDisplayIndex < displayOrder.count - 1 { return .playNext }
        if isEndlessShuffleOn && !playbackSet.isEmpty { return .endlessShuffleNext }
        return .stopLastItem
    }

    private func updatePlaybackProgressSnapshot(position: Float? = nil) {
        let now = Date()
        let sampledPosition = position ?? player.position
        let sampledTimeMs = Int(player.time.intValue)
        let sampledDurationMs = Int(player.media?.length.intValue ?? 0)

        if sampledPosition.isFinite && sampledPosition >= 0 {
            lastKnownPosition = max(lastKnownPosition, sampledPosition)
        }
        if sampledTimeMs > 0 {
            lastKnownTimeMs = max(lastKnownTimeMs, sampledTimeMs)
        }
        if sampledDurationMs > 0 {
            lastKnownDurationMs = max(lastKnownDurationMs, sampledDurationMs)
        }

        lastPlayingDate = now
        if (sampledPosition.isFinite && sampledPosition > 0) || sampledTimeMs > 0 {
            lastProgressDate = now
        }
    }

    private func eofTimeToleranceMs(for durationMs: Int) -> Int {
        guard durationMs > 0 else { return watchdogDefaultEOFToleranceMs }
        let scaled = Int(Double(durationMs) * 0.03)
        return max(1_200, min(2_500, max(watchdogDefaultEOFToleranceMs, scaled)))
    }

    private func scheduleCompletionSequence(action: PlaybackCompletionAction,
                                            source: String,
                                            sourceURL: URL?,
                                            eofDecision: String) {
        guard activeCompletionSequence == nil else { return }

        playbackCompletionSequence += 1
        let sequence = CompletionSequence(id: playbackCompletionSequence,
                                          source: source,
                                          action: action,
                                          sourceURL: sourceURL,
                                          sourceSessionID: currentPlaybackSessionID)
        activeCompletionSequence = sequence

        NSLog("[dwb-playback] completionDecision: source=%@ action=%@ seq=%d media=%@ session=%d eof=%@",
              source,
              action.rawValue,
              sequence.id,
              sourceURL?.lastPathComponent ?? currentMediaURL?.lastPathComponent ?? "—",
              currentPlaybackSessionID,
              eofDecision)

        switch action {
        case .repeatCurrent:
            schedulePlaybackAction(named: "completion-\(action.rawValue)-seq\(sequence.id)",
                                   after: delayedPlaybackActionInterval) { [weak self] in
                self?.playCurrentItem(startReason: "autoplay-repeat",
                                      expectPlaybackHandshake: true,
                                      preserveCompletionSequence: true,
                                      transitionStrategy: .freshPlayer)
            }
        case .playNext, .endlessShuffleNext:
            let nextReason: String
            switch action {
            case .endlessShuffleNext:
                nextReason = "autoplay-endless-shuffle"
            default:
                nextReason = "autoplay-next"
            }
            schedulePlaybackAction(named: "completion-\(action.rawValue)-seq\(sequence.id)",
                                   after: delayedPlaybackActionInterval) { [weak self] in
                guard let self = self else { return }
                let advanced = self.advanceToNextItem(reason: nextReason,
                                                      expectPlaybackHandshake: true,
                                                      preserveCompletionSequence: true,
                                                      transitionStrategy: .freshPlayer)
                if !advanced {
                    self.clearCompletionSequence(reason: "completion-no-next")
                }
            }
        case .stopLastItem:
            break
        case .ignoredUserStop:
            clearCompletionSequence(reason: "ignored-user-stop", suppressLog: true)
        }
    }

    private func evaluateCompletionWatchdog(source: String,
                                            capturedMediaURL: URL? = nil,
                                            capturedStoppedPosition: Float? = nil) {
        let now = Date()
        let currentState = player.state
        let recentSeekAge = lastUserSeekDate.map { now.timeIntervalSince($0) } ?? -1
        let recentSeek = recentSeekAge >= 0 && recentSeekAge < userSeekEOFGuardWindow
        let recentPlayingAge = lastPlayingDate.map { now.timeIntervalSince($0) } ?? -1
        let recentProgressAge = lastProgressDate.map { now.timeIntervalSince($0) } ?? -1
        let recentStopAge = lastStoppedDate.map { now.timeIntervalSince($0) } ?? -1
        let playbackRecentlyActive = (recentPlayingAge >= 0 && recentPlayingAge < watchdogRecentPlaybackWindow)
            || (recentProgressAge >= 0 && recentProgressAge < watchdogRecentPlaybackWindow)
            || naturalEOFDetected
        let stoppedRecently = (recentStopAge >= 0 && recentStopAge < watchdogRecentStopWindow)
            || currentState == .stopped
            || currentState == .ended
        let sampledPosition = max(lastKnownPosition,
                                  max(positionAtEndedEvent,
                                      capturedStoppedPosition ?? lastStoppedPosition))
        let remainingMs = {
            guard lastKnownDurationMs > 0, lastKnownTimeMs > 0 else { return Int.max }
            return max(0, lastKnownDurationMs - lastKnownTimeMs)
        }()
        let pausedNearEOF = !isUserStop
            && !recentSeek
            && currentState == .paused
            && (sampledPosition >= pausedNearEOFPositionThreshold
                || remainingMs <= pausedNearEOFRemainingMs)
        let rendererInactive = !player.isPlaying
            && currentState != .playing
            && currentState != .opening
            && currentState != .buffering
            && !pausedNearEOF
        let nearEOFByPosition = sampledPosition >= eofPositionThreshold
        let nearEOFByTime: Bool = {
            guard lastKnownDurationMs > 0, lastKnownTimeMs > 0 else { return false }
            return (lastKnownDurationMs - lastKnownTimeMs) <= eofTimeToleranceMs(for: lastKnownDurationMs)
        }()
        let strongEOF = naturalEOFDetected || positionAtEndedEvent >= eofPositionThreshold
        let eofDetected = pausedNearEOF || strongEOF || ((nearEOFByTime || nearEOFByPosition) && stoppedRecently)
        let targetURL = capturedMediaURL ?? currentMediaURL ?? lastStoppedMediaURL
        let targetURLName = targetURL?.lastPathComponent ?? currentMediaURL?.lastPathComponent ?? "—"
        let completionSource = pausedNearEOF ? "paused-near-eof" : source
        let staleEvent = {
            guard let capturedPath = capturedMediaURL?.path,
                  let currentPath = currentMediaURL?.path else { return false }
            return capturedPath != currentPath
        }()
        let action = completionActionForCurrentState()
        let completionSeqID = activeCompletionSequence?.id ?? 0
        let eofDecision = eofDetected
            ? (pausedNearEOF ? "paused-near-eof" : (strongEOF ? "strong-eof" : "watchdog-near-eof"))
            : (recentSeek ? "seek-guarded" : "no-eof")

        NSLog("[dwb-autoplay-trace] watchdog: source=%@ media=%@ displayIdx=%d/%d queueCount=%d displayOrderCount=%d pos=%.3f timeMs=%d durationMs=%d userStop=%d recentSeek=%d suppressNextStopped=%d completionSeq=%d playingAge=%.2f progressAge=%.2f stopAge=%.2f eof=%@",
              completionSource,
              targetURLName,
              currentDisplayIndex,
              displayOrder.count,
              playbackSet.count,
              displayOrder.count,
              sampledPosition,
              lastKnownTimeMs,
              lastKnownDurationMs,
              isUserStop ? 1 : 0,
              recentSeek ? 1 : 0,
              suppressNextStopped ? 1 : 0,
              completionSeqID,
              max(0, recentPlayingAge),
              max(0, recentProgressAge),
              max(0, recentStopAge),
              eofDecision)

        guard !staleEvent else {
            NSLog("[dwb-playback] completionDecision: source=%@ action=ignored-stale-event media=%@", source, targetURLName)
            return
        }

        guard (rendererInactive && playbackRecentlyActive) || pausedNearEOF else { return }
        guard !recentSeek, eofDetected else { return }
        guard currentMediaURL != nil, currentDisplayIndex >= 0, !displayOrder.isEmpty else { return }

        scheduleCompletionSequence(action: action,
                                   source: completionSource,
                                   sourceURL: targetURL,
                                   eofDecision: eofDecision)
    }

    // MARK: - Volume

    private var persistedVolume: Int32 {
        let key = SettingsWindowController.persistedVolumeKey
        guard UserDefaults.standard.object(forKey: key) != nil else { return 100 }
        return Int32(max(0, min(150, UserDefaults.standard.integer(forKey: key))))
    }

    private func applyPersistedVolume() {
        player.audio?.volume = persistedVolume
    }

    private func persistVolume(_ volume: Int32) {
        UserDefaults.standard.set(Int(max(0, min(150, volume))), forKey: SettingsWindowController.persistedVolumeKey)
    }

    func adjustVolume(by delta: Int) {
        guard let audio = player?.audio else { return }
        let newVol = Int32(max(0, min(150, Int(audio.volume) + delta)))
        audio.volume = newVol
        persistVolume(newVol)
        volumeBar.show(volume: newVol)
    }

    func setVolumeFromBar(_ vol: Int32) {
        guard let audio = player?.audio else { return }
        audio.volume = max(0, min(150, vol))
        persistVolume(audio.volume)
        volumeBar.show(volume: audio.volume)
    }

    func showVolumeBar(volume: Int32) {
        volumeBar.show(volume: volume)
    }

    func persistTransportVolume(_ volume: Int32) {
        persistVolume(volume)
    }

    func volumeUp()   { adjustVolume(by: 10)  }
    func volumeDown() { adjustVolume(by: -10) }

    // MARK: - Scale mode

    func setScaleMode(_ mode: ScaleMode) {
        scaleMode = mode
        applyScaleMode()
    }

    private func applyScaleMode() {
        guard player != nil else { return }
        let size = videoSurface.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let ratio = "\(Int(size.width)):\(Int(size.height))"
        switch scaleMode {
        case .fit:
            player.videoAspectRatio  = nil
            player.videoCropGeometry = nil
        case .fill:
            player.videoAspectRatio  = nil
            ratio.withCString { player.videoCropGeometry = UnsafeMutablePointer(mutating: $0) }
        case .stretch:
            ratio.withCString { player.videoAspectRatio = UnsafeMutablePointer(mutating: $0) }
            player.videoCropGeometry = nil
        }
    }

    // MARK: - Update timer

    private func startUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.player?.isPlaying == true {
                self.updatePlaybackProgressSnapshot()
            }
            self.evaluateCompletionWatchdog(source: "watchdog")
            self.transport.update()
        }
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    // MARK: - HUD / transport visibility

    private func showHUD() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            transport.animator().alphaValue = 1.0
        }
    }

    private func hideHUD() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            transport.animator().alphaValue = 0.0
        }
    }

    private func scheduleHide() {
        hideHUDTimer?.invalidate()
        hideHUDTimer = Timer.scheduledTimer(withTimeInterval: 2.7, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.isFullscreen || self.autoHideTransportEnabled { self.hideHUD() }
        }
    }

    // MARK: - Mouse tracking

    private func addMouseTracking() {
        guard let cv = window?.contentView else { return }
        removeMouseTracking()
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        cv.addTrackingArea(area)
        trackingArea = area
    }

    private func removeMouseTracking() {
        if let area = trackingArea {
            window?.contentView?.removeTrackingArea(area)
            trackingArea = nil
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if isFullscreen || autoHideTransportEnabled {
            showHUD()
            scheduleHide()
        }
    }

    // MARK: - Window close

    override func close() {
        resetPlaybackCompletionSignals(reason: "window-close")
        if player.isPlaying {
            isUserStop = true
            player.stop()
        }
        super.close()
    }
}

// MARK: - NSWindowDelegate

extension PlayerWindowController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        resetPlaybackCompletionSignals(reason: "window-will-close")
        stopUpdateTimer()
        hideHUDTimer?.invalidate()
        seekTargetResetTimer?.invalidate()
        removeMouseTracking()
        NotificationCenter.default.removeObserver(self)
        if player.isPlaying {
            isUserStop = true
            player.stop()
        }
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.windowControllers.removeAll { $0 === self }
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        isEnteringFullscreen = true
        logChromeState("windowWillEnterFullScreen")
        logLayoutSnapshot("windowWillEnterFullScreen")
    }

    func windowDidResize(_ notification: Notification) {
        logChromeState("windowDidResize [no chrome write]")
        logLayoutSnapshot("windowDidResize")
        // Chrome normalization is intentionally absent from this path.
        //
        // Writing titlebar/chrome properties during live resize (even idempotent
        // same-value writes) forces AppKit to re-evaluate titlebar geometry on every
        // resize event, causing cumulative titlebar height drift — the root cause of
        // the large-titlebar bug after fullscreen exit and free resize.
        //
        // Authoritative chrome restoration happens exactly once: in the deferred block
        // inside windowDidExitFullScreen, after the window system has fully settled.
        // The window is built with correct chrome in buildWindow() and the deferred
        // block restores it after each fullscreen cycle — no per-resize correction needed.
        layoutPlayerViews()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isEnteringFullscreen = false
        isFullscreen         = true
        logChromeState("windowDidEnterFullScreen")
        logLayoutSnapshot("windowDidEnterFullScreen")
        layoutPlayerViews()
        addMouseTracking()
        transport.alphaValue = 1.0
        showHUD()
        scheduleHide()
        window?.makeFirstResponder(videoSurface)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        // Set isExitingFullscreen HERE — before AppKit delivers exit-animation
        // windowDidResize callbacks.  Those callbacks still see isFullscreen=true,
        // but layoutMode now returns .exitingFullscreenSettling, so layoutPlayerViews()
        // applies windowed-baseline geometry instead of fullscreen HUD geometry.
        isExitingFullscreen = true
        logChromeState("windowWillExitFullScreen")
        logLayoutSnapshot("windowWillExitFullScreen")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullscreen        = false
        // isExitingFullscreen is already true (set in windowWillExitFullScreen);
        // re-assert defensively in case the Will callback was skipped.
        isExitingFullscreen = true
        logChromeState("windowDidExitFullScreen")
        logLayoutSnapshot("windowDidExitFullScreen")
        hideHUDTimer?.invalidate()

        // Immediate pass: snap chrome back so the window doesn't look wrong on screen.
        // Because windowDidResize no longer performs chrome writes, the resize callback
        // triggered by this styleMask removal is safe and creates no cascade.
        cleanupFullscreenWindowState()

        transport.alphaValue = 1.0
        addMouseTracking()
        if autoHideTransportEnabled { scheduleHide() }
        layoutPlayerViews()

        // Deferred authoritative pass: after the window system has fully settled,
        // perform the final chrome restore + layout and clear the exiting flag.
        // This is the ONE place that clears isExitingFullscreen; after this point
        // layoutMode returns .windowed and later resizes do not touch chrome.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.cleanupFullscreenWindowState()
            self.isExitingFullscreen = false
            self.logChromeState("windowDidExitFullScreen [deferred settle]")
            self.layoutPlayerViews()
        }
    }

    /// Restore all window-chrome properties that macOS modifies during fullscreen.
    /// Idempotent: safe to call multiple times.
    ///
    /// Uses targeted property restoration rather than full styleMask replacement.
    /// Atomic mask replacement (win.styleMask = saved) triggers additional AppKit
    /// layout passes and is the source of cascading resize events — we avoid it.
    private func cleanupFullscreenWindowState() {
        guard let win = window else { return }
        NSLog("[dwb-chrome] cleanupFullscreenWindowState: targeted restore — fscv=%d tbTrans=%d",
              win.styleMask.contains(.fullSizeContentView) ? 1 : 0,
              win.titlebarAppearsTransparent ? 1 : 0)
        win.styleMask.remove(.fullSizeContentView)
        win.titlebarAppearsTransparent = false
        win.titleVisibility            = .hidden
        win.titlebarSeparatorStyle     = .automatic
    }

    // MARK: - Layout debug logging
    // Temporary verification helper — logs layout-mode decisions around fullscreen
    // transitions so the real branch chosen by layoutPlayerViews() can be confirmed
    // in the console without requiring interactive visual inspection.

    private func logLayoutSnapshot(_ event: String) {
        guard let win = window, let cv = win.contentView else {
            NSLog("[dwb-layout] %@ | no-window", event)
            return
        }
        let styleMaskFS = win.styleMask.contains(.fullScreen)
        let modeStr: String
        switch layoutMode {
        case .fullscreen:                modeStr = "fullscreen"
        case .exitingFullscreenSettling: modeStr = "exiting-settling"
        case .windowed:                  modeStr = "windowed"
        }
        NSLog("[dwb-layout] %@ | styleFS=%d flags(enter=%d,exit=%d,fs=%d) mode=%@ bounds=%@ clr=%@ transport=%@ video=%@ tFS=%d",
              event,
              styleMaskFS ? 1 : 0,
              isEnteringFullscreen ? 1 : 0,
              isExitingFullscreen  ? 1 : 0,
              isFullscreen         ? 1 : 0,
              modeStr,
              NSStringFromRect(cv.bounds),
              NSStringFromRect(win.contentLayoutRect),
              NSStringFromRect(transport?.frame ?? .zero),
              NSStringFromRect(videoSurface?.frame ?? .zero),
              (transport?.isFullscreenStyle ?? false) ? 1 : 0)
    }

    // MARK: - Chrome state debug logging
    // Captures actual NSWindow titlebar/chrome property values at key mutation points.
    // Prefixed [dwb-chrome] to distinguish from [dwb-layout] transport geometry logs.

    private func logChromeState(_ event: String) {
        guard let win = window else {
            NSLog("[dwb-chrome] %@ | no-window", event)
            return
        }
        let fsFlag  = win.styleMask.contains(.fullScreen)
        let fscv    = win.styleMask.contains(.fullSizeContentView)
        let tbTrans = win.titlebarAppearsTransparent
        let tbVisStr: String
        switch win.titleVisibility {
        case .visible:     tbVisStr = "visible"
        case .hidden:      tbVisStr = "hidden"
        @unknown default:  tbVisStr = "unknown(\(win.titleVisibility.rawValue))"
        }
        let tbSepStr: String
        switch win.titlebarSeparatorStyle {
        case .automatic:   tbSepStr = "auto"
        case .none:        tbSepStr = "none"
        case .line:        tbSepStr = "line"
        case .shadow:      tbSepStr = "shadow"
        @unknown default:  tbSepStr = "unknown"
        }
        NSLog("[dwb-chrome] %@ | styleFS=%d fscv=%d tbTrans=%d tbVis=%@ tbSep=%@ flags(enter=%d,exit=%d,fs=%d)",
              event,
              fsFlag  ? 1 : 0,
              fscv    ? 1 : 0,
              tbTrans ? 1 : 0,
              tbVisStr,
              tbSepStr,
              isEnteringFullscreen ? 1 : 0,
              isExitingFullscreen  ? 1 : 0,
              isFullscreen         ? 1 : 0)
    }

    private func logPlaybackQueueSnapshot(_ event: String) {
        let order = displayOrder.map(String.init).joined(separator: ",")
        let currentURL = currentMediaURL?.lastPathComponent ?? "—"
        NSLog("[dwb-playback] %@: displayIdx=%d/%d currentSetIdx=%d queueCount=%d displayOrder=[%@] shuffle=%d endless=%d repeat=%d current=%@",
              event,
              currentDisplayIndex,
              displayOrder.count,
              currentSetIndex,
              playbackSet.count,
              order,
              isShuffleOn ? 1 : 0,
              isEndlessShuffleOn ? 1 : 0,
              isRepeatOne ? 1 : 0,
              currentURL)
    }
}

// MARK: - VLCMediaPlayerDelegate

extension PlayerWindowController: VLCMediaPlayerDelegate {

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        guard player === self.player else {
            NSLog("[dwb-playback] state=ignored-stale-player state=%d media=%@",
                  player.state.rawValue,
                  player.media?.url?.lastPathComponent ?? "—")
            return
        }

        // Capture state, position, and media identity on the VLC callback thread.
        // player.state may transition again before main-queue blocks run.
        // player.position may already be reset to 0 by the time .stopped blocks run.
        let capturedState     = player.state
        let capturedPosition  = player.position
        let capturedMediaURL  = player.media?.url
        let capturedMediaName = capturedMediaURL?.lastPathComponent ?? "—"

        // Always keep transport current regardless of which state fired.
        DispatchQueue.main.async { [weak self] in
            self?.transport.update()
        }

        switch capturedState {

        // ── Informational state transitions (logged for tracing; no action needed) ──

        case .opening:
            NSLog("[dwb-playback] state=opening  media=%@", capturedMediaName)

        case .buffering:
            // .buffering can fire many times during a clip; log briefly.
            NSLog("[dwb-playback] state=buffering pos=%.3f media=%@", capturedPosition, capturedMediaName)

        case .playing:
            NSLog("[dwb-playback] state=playing   pos=%.3f media=%@", capturedPosition, capturedMediaName)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.updatePlaybackProgressSnapshot(position: capturedPosition)
                guard let handshake = self.playbackStartHandshake else {
                    self.clearCompletionSequence(reason: "state-playing", suppressLog: true)
                    return
                }
                guard handshake.expectedURL.path == capturedMediaURL?.path else { return }
                if !handshake.sawPlaying {
                    var updated = handshake
                    updated.sawPlaying = true
                    self.playbackStartHandshake = updated
                    NSLog("[dwb-playback] handshakeFirstPlaying: id=%d reason=%@ media=%@ transition=%@",
                          updated.id,
                          updated.reason,
                          capturedMediaName,
                          updated.transitionStrategy.rawValue)
                }
                self.schedulePlaybackStartHandshakeCheck(for: handshake.id)
            }

        case .paused:
            NSLog("[dwb-playback] state=paused     pos=%.3f media=%@", capturedPosition, capturedMediaName)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.updatePlaybackProgressSnapshot(position: capturedPosition)
                self.evaluateCompletionWatchdog(source: "paused",
                                                capturedMediaURL: capturedMediaURL,
                                                capturedStoppedPosition: capturedPosition)
            }

        case .ended:
            let posAtEnded = capturedPosition
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let capturedURLName = capturedMediaURL?.lastPathComponent ?? "—"
                let currentURLName = self.currentMediaURL?.lastPathComponent ?? "—"
                if let capturedPath = capturedMediaURL?.path,
                   let currentPath = self.currentMediaURL?.path,
                   capturedPath != currentPath {
                    NSLog("[dwb-playback] .ended: capturedURL=%@ currentURL=%@ position=%.3f accepted=0 reason=stale-url-mismatch",
                          capturedURLName,
                          currentURLName,
                          posAtEnded)
                    return
                }
                self.naturalEOFDetected   = true
                self.positionAtEndedEvent = posAtEnded
                self.lastStoppedDate = Date()
                self.lastStoppedPosition = max(self.lastStoppedPosition, posAtEnded)
                self.lastStoppedMediaURL = capturedMediaURL ?? self.currentMediaURL
                NSLog("[dwb-playback] .ended: capturedURL=%@ currentURL=%@ position=%.3f accepted=1",
                      capturedURLName,
                      currentURLName,
                      posAtEnded)
                NSLog("[dwb-playback] .ended: naturalEOFDetected=1 posAtEnded=%.3f displayIdx=%d/%d repeat=%d shuffle=%d endless=%d hasNext=%d media=%@ session=%d",
                      posAtEnded,
                      self.currentDisplayIndex, self.displayOrder.count,
                      self.isRepeatOne ? 1 : 0,
                      self.isShuffleOn ? 1 : 0,
                      self.isEndlessShuffleOn ? 1 : 0,
                      self.hasNext ? 1 : 0,
                      capturedMediaName,
                      self.currentPlaybackSessionID)
                self.logPlaybackQueueSnapshot(".ended")
                self.evaluateCompletionWatchdog(source: "ended",
                                                capturedMediaURL: capturedMediaURL,
                                                capturedStoppedPosition: posAtEnded)
            }

        case .stopped:
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                let now = Date()
                let suppressAge = self.suppressNextStoppedDate.map { now.timeIntervalSince($0) } ?? -1.0
                let suppressFresh = self.suppressNextStopped &&
                    suppressAge >= 0 &&
                    suppressAge < self.replacementStopSuppressionWindow
                let recentSeekAge = self.lastUserSeekDate.map { now.timeIntervalSince($0) } ?? -1.0
                let recentSeek = recentSeekAge >= 0 && recentSeekAge < self.userSeekEOFGuardWindow
                self.lastStoppedDate = now
                self.lastStoppedPosition = max(self.lastStoppedPosition, capturedPosition)
                self.lastStoppedMediaURL = capturedMediaURL ?? self.currentMediaURL

                NSLog("[dwb-playback] .stopped: userStop=%d suppress=%d naturalEOF=%d lastPos=%.3f capPos=%.3f posAtEnded=%.3f timeMs=%d durationMs=%d recentSeek=%d(%.2fs) suppressAge=%.2fs suppressFresh=%d displayIdx=%d/%d shuffle=%d endless=%d repeat=%d hasNext=%d media=%@ session=%d completionSeq=%d",
                      self.isUserStop          ? 1 : 0,
                      self.suppressNextStopped ? 1 : 0,
                      self.naturalEOFDetected  ? 1 : 0,
                      self.lastKnownPosition,
                      capturedPosition,
                      self.positionAtEndedEvent,
                      self.lastKnownTimeMs,
                      self.lastKnownDurationMs,
                      recentSeek ? 1 : 0,
                      max(0.0, recentSeekAge),
                      max(0.0, suppressAge),
                      suppressFresh ? 1 : 0,
                      self.currentDisplayIndex, self.displayOrder.count,
                      self.isShuffleOn ? 1 : 0,
                      self.isEndlessShuffleOn ? 1 : 0,
                      self.isRepeatOne ? 1 : 0,
                      self.hasNext ? 1 : 0,
                      capturedMediaName,
                      self.currentPlaybackSessionID,
                      self.activeCompletionSequence?.id ?? 0)

                if self.isUserStop {
                    self.isUserStop = false
                    self.resetPlaybackCompletionSignals(reason: "stopped-user-stop")
                    NSLog("[dwb-playback] completionDecision: source=stopped action=%@ media=%@",
                          PlaybackCompletionAction.ignoredUserStop.rawValue,
                          capturedMediaName)
                    return
                }

                if suppressFresh && self.replacementStartWorkItem != nil {
                    self.clearStoppedSuppression()
                    NSLog("[dwb-playback] .stopped: reasonCode=replacement-suppressed media=%@",
                          capturedMediaName)
                    return
                }

                if self.suppressNextStopped {
                    NSLog("[dwb-playback] .stopped: suppression flag present (age=%.2fs fresh=%d) — clearing stale suppression if needed",
                          max(0.0, suppressAge),
                          suppressFresh ? 1 : 0)
                    if !suppressFresh || self.replacementStartWorkItem == nil {
                        self.clearStoppedSuppression()
                    }
                }

                self.evaluateCompletionWatchdog(source: "stopped",
                                                capturedMediaURL: capturedMediaURL,
                                                capturedStoppedPosition: capturedPosition)
            }

        case .error:
            let filename = player.media?.url?.lastPathComponent ?? "unknown file"
            NSLog("[dwb-playback] state=error   media=%@", filename)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.resetPlaybackCompletionSignals(reason: "state-error")
                let alert = NSAlert()
                alert.messageText     = "Playback Error"
                alert.informativeText = "Could not play \"\(filename)\". The file may be unsupported or corrupt."
                alert.alertStyle      = .warning
                alert.addButton(withTitle: "OK")
                if let window = self.window { alert.beginSheetModal(for: window) }
            }

        default:
            NSLog("[dwb-playback] state=other(%d) pos=%.3f media=%@",
                  capturedState.rawValue, capturedPosition, capturedMediaName)
        }
    }
}

// MARK: - QueuePageViewDelegate

extension PlayerWindowController: QueuePageViewDelegate {

    func queuePage(_ view: QueuePageView, didSelectDisplayIndex index: Int) {
        currentDisplayIndex = index
        playCurrentItem(startReason: "queue-page-select")
    }

    func queuePage(_ view: QueuePageView, didRequestRenameAt index: Int) {
        showRenameSheet(forDisplayIndex: index)
    }

    func queuePage(_ view: QueuePageView, didRequestRevealAt index: Int) {
        revealInFinder(displayIndex: index)
    }

    func queuePage(_ view: QueuePageView, didRequestDeleteAt index: Int) {
        removeQueueItem(displayIndex: index)
    }

    func queuePage(_ view: QueuePageView, didChangeSortMode mode: QueueSortMode) {
        queueSortMode = mode
        if mode != .manual {
            isShuffleOn = false
            isEndlessShuffleOn = false
        }
        applyQueueSortIfNeeded(reason: "queue-page-sort-change")
        logPlaybackQueueSnapshot("queueSortChange")
    }

    func queuePageDidRequestClose(_ view: QueuePageView) {
        isQueuePageOpen = false
        layoutPlayerViews()
        transport.update()
    }

    /// Row drag-and-drop reorder from Queue Page.
    ///
    /// `from` is the dragged row's index; `to` is the insertion point (0…n, .above semantics).
    /// The manual reorder becomes the authoritative playback order.
    /// If shuffle is ON it is disabled: the explicit manual order replaces the shuffled order.
    func queuePage(_ view: QueuePageView, didReorderFromIndex from: Int, toIndex to: Int) {
        guard from >= 0, from < displayOrder.count,
              to >= 0, to <= displayOrder.count else { return }
        // No-op drops (same position or directly below source)
        guard from != to, from != to - 1 else { return }

        // Save the current playback-set index so we can track it through the reorder
        let curSetIdx = currentSetIndex

        // Disable shuffle — manual reorder takes over as the authoritative order
        if isShuffleOn { isShuffleOn = false }
        if curSetIdx >= 0 {
            NSLog("[dwb-playback] queueReorder: manual order wins; from=%d to=%d currentSetIdx=%d",
                  from, to, curSetIdx)
        }

        // Perform the move in displayOrder
        let movedItem = displayOrder.remove(at: from)
        // After removing, the insertion index shifts down by 1 if to > from
        let insertAt = to > from ? to - 1 : to
        displayOrder.insert(movedItem, at: insertAt)

        // Restore currentDisplayIndex to keep pointing at the same item
        if curSetIdx >= 0, let newIdx = displayOrder.firstIndex(of: curSetIdx) {
            currentDisplayIndex = newIdx
        }

        queueSortMode = .manual
        refreshQueueDisplays()
        logPlaybackQueueSnapshot("queueReorder")
    }
}
