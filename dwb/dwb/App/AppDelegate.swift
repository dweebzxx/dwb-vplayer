import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private let maxPlayerWindowCount = 5

    var windowControllers: [PlayerWindowController] = []
    private weak var rewindMenuItem: NSMenuItem?
    private weak var forwardMenuItem: NSMenuItem?
    private var hasReceivedOpenEventDuringLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsWindowController.registerDefaults()
        _ = DebugConsoleController.shared   // eagerly init so it observes settings from launch
        buildMainMenu()
        observeSettings()
        updateSkipMenuItemTitles()
        openInitialPlayerWindowIfNeeded()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        DebugConsoleController.log("app", "launched: version=\(version) build=\(build) pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugConsoleController.log("app", "terminating")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        openSubmittedURLs(urls, source: "openFiles")
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openSubmittedURLs([URL(fileURLWithPath: filename)], source: "openFile")
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openSubmittedURLs(urls, source: "openURLs")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let visiblePlayerWindows = windowControllers.compactMap { wc -> NSWindow? in
            guard let window = wc.window, window.isVisible else { return nil }
            return window
        }

        if visiblePlayerWindows.isEmpty {
            _ = openNewPlayerWindow()
        } else {
            visiblePlayerWindows.forEach { $0.deminiaturize(nil) }
            visiblePlayerWindows.last?.makeKeyAndOrderFront(nil)
        }

        sender.activate(ignoringOtherApps: true)
        return false
    }

    // MARK: - Window management

    @discardableResult
    func openNewPlayerWindow() -> PlayerWindowController? {
        pruneClosedPlayerWindowControllers()
        guard windowControllers.count < maxPlayerWindowCount else {
            presentWindowCapDenial(context: "new-window")
            return nil
        }
        let wc = PlayerWindowController()
        // Cascade from the most recently opened window so new windows don't
        // stack exactly on top of existing ones.  cascadeTopLeft(from:) uses
        // AppKit's standard bottom-left origin screen coordinates; the "top-left"
        // of a window is (frame.minX, frame.maxY).
        if let prevWindow = windowControllers.last?.window {
            wc.window?.cascadeTopLeft(from: NSPoint(x: prevWindow.frame.minX,
                                                    y: prevWindow.frame.maxY))
        }
        wc.showWindow(nil)
        windowControllers.append(wc)
        return wc
    }

    private func openInitialPlayerWindowIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  !self.hasReceivedOpenEventDuringLaunch,
                  self.usablePlayerWindowController() == nil else { return }
            _ = self.openNewPlayerWindow()
        }
    }

    private func openSubmittedURLs(_ urls: [URL], source: String) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }

        hasReceivedOpenEventDuringLaunch = true

        guard let wc = usablePlayerWindowController() ?? openNewPlayerWindow() else { return }
        wc.window?.deminiaturize(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSLog("[dwb-open] source=%@ count=%d files=%@",
              source,
              fileURLs.count,
              fileURLs.map(\.lastPathComponent).joined(separator: ","))

        // Native Finder/Dock open events are explicit external submissions, so
        // use the same queue-top insertion semantics as an explicit file drop.
        wc.handleDroppedURLs(fileURLs, appendingExplicitFiles: true)
        noteRecentDocumentURLs(from: fileURLs)
    }

    private func usablePlayerWindowController() -> PlayerWindowController? {
        if let wc = NSApp.keyWindow?.windowController as? PlayerWindowController,
           wc.window?.isVisible == true {
            return wc
        }
        if let wc = NSApp.mainWindow?.windowController as? PlayerWindowController,
           wc.window?.isVisible == true {
            return wc
        }
        for window in NSApp.orderedWindows {
            if let wc = window.windowController as? PlayerWindowController,
               window.isVisible {
                return wc
            }
        }
        return windowControllers.last { $0.window?.isVisible == true }
    }

    private func pruneClosedPlayerWindowControllers() {
        windowControllers.removeAll { $0.window == nil }
    }

    private func presentWindowCapDenial(context: String) {
        DebugConsoleController.log(level: .warning,
                                   category: "window",
                                   message: "windowCapDenied: context=\(context) cap=\(maxPlayerWindowCount) current=\(windowControllers.count)")
        let alert = NSAlert()
        alert.messageText = "Window limit reached"
        alert.informativeText = "dwb player supports up to \(maxPlayerWindowCount) player windows."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let sheetWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: sheetWindow)
        } else {
            alert.runModal()
        }
    }

    private func orderedPlayerWindowControllers() -> [PlayerWindowController] {
        pruneClosedPlayerWindowControllers()
        var ordered: [PlayerWindowController] = []
        if let front = usablePlayerWindowController() {
            ordered.append(front)
        }
        for window in NSApp.orderedWindows {
            guard let wc = window.windowController as? PlayerWindowController,
                  !ordered.contains(where: { $0 === wc }) else { continue }
            ordered.append(wc)
        }
        for wc in windowControllers where !ordered.contains(where: { $0 === wc }) {
            ordered.append(wc)
        }
        return ordered
    }

    private func gridTargetScreen(from selected: [PlayerWindowController]) -> NSScreen? {
        if let front = usablePlayerWindowController(),
           let screen = front.window?.screen {
            return screen
        }
        return selected.first(where: { $0.window?.isKeyWindow == true })?.window?.screen
            ?? selected.first(where: { $0.window?.isMainWindow == true })?.window?.screen
            ?? NSScreen.main
    }

    private func arrangeFourWindowGrid() {
        var selected = orderedPlayerWindowControllers()
        let initialCount = selected.count
        let needed = max(0, 4 - selected.count)

        for _ in 0..<needed {
            guard let wc = openNewPlayerWindow() else {
                DebugConsoleController.log(level: .warning,
                                           category: "window",
                                           message: "fourWindowGrid: deniedByCap initial=\(initialCount) selected=\(selected.count) cap=\(maxPlayerWindowCount)")
                return
            }
            selected.append(wc)
        }

        selected = Array(selected.prefix(4))
        guard selected.count == 4 else {
            presentWindowCapDenial(context: "four-window-grid")
            return
        }

        guard let screen = gridTargetScreen(from: selected) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let halfW = floor(visibleFrame.width / 2)
        let halfH = floor(visibleFrame.height / 2)
        let frames = [
            NSRect(x: visibleFrame.minX, y: visibleFrame.minY + halfH, width: halfW, height: visibleFrame.height - halfH),
            NSRect(x: visibleFrame.minX + halfW, y: visibleFrame.minY + halfH, width: visibleFrame.width - halfW, height: visibleFrame.height - halfH),
            NSRect(x: visibleFrame.minX, y: visibleFrame.minY, width: halfW, height: halfH),
            NSRect(x: visibleFrame.minX + halfW, y: visibleFrame.minY, width: visibleFrame.width - halfW, height: halfH)
        ]

        for (wc, frame) in zip(selected, frames) {
            wc.window?.setFrame(frame, display: true, animate: false)
            wc.window?.deminiaturize(nil)
            wc.showWindow(nil)
        }
        selected.first?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DebugConsoleController.log("window", "fourWindowGrid: initial=\(initialCount) opened=\(needed) arranged=\(selected.map(\.debugIdentity).joined(separator: ",")) screen=\(screen.localizedName) frame=\(Int(visibleFrame.width))x\(Int(visibleFrame.height))")
    }

    private func noteRecentDocumentURLs(from urls: [URL]) {
        for url in urls where shouldAddToRecentDocuments(url) {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
    }

    private func shouldAddToRecentDocuments(_ url: URL) -> Bool {
        guard url.isFileURL,
              MediaFileSupport.isSupported(url) else { return false }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }

        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        if isDescendant(resolvedURL, of: FileManager.default.temporaryDirectory) {
            return false
        }
        if isDescendant(resolvedURL, of: Bundle.main.bundleURL) {
            return false
        }
        return true
    }

    private func isDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let childPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let ancestorPath = ancestor.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = ancestorPath.hasSuffix("/") ? ancestorPath : ancestorPath + "/"
        return childPath == ancestorPath || childPath.hasPrefix(prefix)
    }

    // MARK: - Menu actions

    @objc func openFile(_ sender: Any) {
        guard let wc = NSApp.keyWindow?.windowController as? PlayerWindowController else {
            guard let wc = openNewPlayerWindow() else { return }
            wc.openFile()
            return
        }
        wc.openFile()
    }

    @objc func revealInFinder(_ sender: Any) {
        frontPlayerWindowController?.revealInFinder()
    }

    @objc func renameCurrentFile(_ sender: Any) {
        frontPlayerWindowController?.showRenameSheet()
    }

    @objc func removeCurrentQueueItem(_ sender: Any) {
        frontPlayerWindowController?.removeCurrentQueueItem()
    }

    @objc func deleteAllQueueItems(_ sender: Any) {
        frontPlayerWindowController?.removeAllQueueItems(source: "menu")
    }

    @objc func newWindow(_ sender: Any) {
        _ = openNewPlayerWindow()
    }

    @objc func fourWindowGrid(_ sender: Any) {
        arrangeFourWindowGrid()
    }

    @objc func playPause(_ sender: Any) {
        frontPlayerWindowController?.togglePlayPause()
    }

    @objc func stop(_ sender: Any) {
        frontPlayerWindowController?.stopPlayback()
    }

    @objc func volumeUp(_ sender: Any) {
        frontPlayerWindowController?.volumeUp()
    }

    @objc func volumeDown(_ sender: Any) {
        frontPlayerWindowController?.volumeDown()
    }

    @objc func rewind10(_ sender: Any) {
        frontPlayerWindowController?.skipBackward10()
    }

    @objc func forward10(_ sender: Any) {
        frontPlayerWindowController?.skipForward10()
    }

    @objc func toggleShuffle(_ sender: Any) {
        frontPlayerWindowController?.toggleShuffle()
    }

    @objc func toggleEndlessShuffle(_ sender: Any) {
        frontPlayerWindowController?.toggleEndlessShuffle()
    }

    @objc func toggleRepeatOne(_ sender: Any) {
        frontPlayerWindowController?.toggleRepeat()
    }

    @objc func setPlaybackSpeedFromMenu(_ sender: NSMenuItem) {
        guard let option = PlaybackSpeedOption.option(forTag: sender.tag - 1000) else { return }
        frontPlayerWindowController?.setPlaybackSpeed(option.rate, source: "playback-menu")
    }

    @objc func setScaleFit(_ sender: Any) {
        frontPlayerWindowController?.setScaleMode(.fit)
    }

    @objc func setScaleFill(_ sender: Any) {
        frontPlayerWindowController?.setScaleMode(.fill)
    }

    @objc func setScaleStretch(_ sender: Any) {
        frontPlayerWindowController?.setScaleMode(.stretch)
    }

    @objc func openSettings(_ sender: Any) {
        SettingsWindowController.shared.openSettings()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.tag {
        case 1:
            menuItem.state = frontPlayerWindowController?.scaleMode == .fit     ? .on : .off
        case 2:
            menuItem.state = frontPlayerWindowController?.scaleMode == .fill    ? .on : .off
        case 3:
            menuItem.state = frontPlayerWindowController?.scaleMode == .stretch ? .on : .off
        case 10: // Reveal in Finder
            return frontPlayerWindowController?.currentMediaURL != nil
        case 11: // Rename
            return frontPlayerWindowController?.canRenameCurrentMedia == true
        case 12: // Remove from Queue
            return frontPlayerWindowController?.currentMediaURL != nil
        case 13: // Clear Queue
            return frontPlayerWindowController != nil
        case 20: // Shuffle
            menuItem.state = frontPlayerWindowController?.isShuffleOn == true ? .on : .off
            return (frontPlayerWindowController?.playbackSet.count ?? 0) > 1
        case 21: // Endless Shuffle
            menuItem.state = frontPlayerWindowController?.isEndlessShuffleOn == true ? .on : .off
            return (frontPlayerWindowController?.playbackSet.count ?? 0) > 0
        case 22: // Repeat One
            menuItem.state = frontPlayerWindowController?.isRepeatOne == true ? .on : .off
            return frontPlayerWindowController?.currentMediaURL != nil
        case 30: // Keep Window On Top
            menuItem.state = frontPlayerWindowController?.isKeepAtTop == true ? .on : .off
        case 31: // Auto-hide Titlebar
            menuItem.state = SettingsWindowController.isAutoHideTitlebarEnabled() ? .on : .off
        default:
            if menuItem.tag >= 1000,
               let option = PlaybackSpeedOption.option(forTag: menuItem.tag - 1000) {
                let current = frontPlayerWindowController?.currentPlaybackSpeed ?? PlaybackSpeedOption.normalRate
                menuItem.state = PlaybackSpeedOption.validated(current) == option ? .on : .off
                return frontPlayerWindowController != nil
            }
            break
        }
        return true
    }

    private var frontPlayerWindowController: PlayerWindowController? {
        return usablePlayerWindowController()
    }

    private func observeSettings() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(skipDurationDidChange),
            name: .skipDurationChanged,
            object: nil
        )
    }

    @objc private func skipDurationDidChange() {
        updateSkipMenuItemTitles()
    }

    private func updateSkipMenuItemTitles() {
        let seconds = SettingsWindowController.currentSkipDurationSeconds()
        rewindMenuItem?.title = SettingsWindowController.skipActionTitle(isForward: false, seconds: seconds)
        forwardMenuItem?.title = SettingsWindowController.skipActionTitle(isForward: true, seconds: seconds)
    }

    // MARK: - Main menu (programmatic)

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // ── App menu ────────────────────────────────────────────────────────
        let appItem = NSMenuItem()
        appItem.title = "dwb player"
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "dwb player")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About dwb player",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings\u{2026}",
                                      action: #selector(openSettings(_:)),
                                      keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit dwb player",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // ── File menu ───────────────────────────────────────────────────────
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu

        let openItem = NSMenuItem(title: "Open\u{2026}",
                                  action: #selector(openFile(_:)),
                                  keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)

        fileMenu.addItem(.separator())

        let revealItem = NSMenuItem(title: "Reveal in Finder",
                                    action: #selector(revealInFinder(_:)),
                                    keyEquivalent: "r")
        revealItem.keyEquivalentModifierMask = [.command, .shift]
        revealItem.target = self
        revealItem.tag    = 10
        fileMenu.addItem(revealItem)

        let renameItem = NSMenuItem(title: "Rename\u{2026}",
                                    action: #selector(renameCurrentFile(_:)),
                                    keyEquivalent: "")
        renameItem.target = self
        renameItem.tag    = 11
        fileMenu.addItem(renameItem)

        let removeItem = NSMenuItem(title: "Remove Current from Queue",
                                    action: #selector(removeCurrentQueueItem(_:)),
                                    keyEquivalent: "")
        removeItem.target = self
        removeItem.tag    = 12
        fileMenu.addItem(removeItem)

        // AppKit represents Delete as NSDeleteCharacter for menu shortcuts.
        // The visible shortcut remains Command+Shift+Delete.
        let deleteAllItem = NSMenuItem(title: "Clear Queue",
                                       action: #selector(deleteAllQueueItems(_:)),
                                       keyEquivalent: String(UnicodeScalar(NSDeleteCharacter)!))
        deleteAllItem.keyEquivalentModifierMask = [.command, .shift]
        deleteAllItem.target = self
        deleteAllItem.tag    = 13
        fileMenu.addItem(deleteAllItem)

        fileMenu.addItem(.separator())

        let newWindowItem = NSMenuItem(title: "New Window",
                                       action: #selector(newWindow(_:)),
                                       keyEquivalent: "n")
        newWindowItem.target = self
        fileMenu.addItem(newWindowItem)

        // ── Playback menu ───────────────────────────────────────────────────
        let playbackItem = NSMenuItem()
        mainMenu.addItem(playbackItem)
        let playbackMenu = NSMenu(title: "Playback")
        playbackItem.submenu = playbackMenu

        let playPauseItem = NSMenuItem(title: "Play / Pause",
                                       action: #selector(playPause(_:)),
                                       keyEquivalent: " ")
        playPauseItem.target = self
        playbackMenu.addItem(playPauseItem)

        let stopItem = NSMenuItem(title: "Stop",
                                  action: #selector(stop(_:)),
                                  keyEquivalent: "")
        stopItem.target = self
        playbackMenu.addItem(stopItem)

        playbackMenu.addItem(.separator())

        let rewind10Item = NSMenuItem(title: SettingsWindowController.skipActionTitle(isForward: false,
                                                                                     seconds: SettingsWindowController.currentSkipDurationSeconds()),
                                      action: #selector(rewind10(_:)),
                                      keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        rewind10Item.keyEquivalentModifierMask = .option
        rewind10Item.target = self
        playbackMenu.addItem(rewind10Item)
        self.rewindMenuItem = rewind10Item

        let forward10Item = NSMenuItem(title: SettingsWindowController.skipActionTitle(isForward: true,
                                                                                       seconds: SettingsWindowController.currentSkipDurationSeconds()),
                                       action: #selector(forward10(_:)),
                                       keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        forward10Item.keyEquivalentModifierMask = .option
        forward10Item.target = self
        playbackMenu.addItem(forward10Item)
        self.forwardMenuItem = forward10Item

        playbackMenu.addItem(.separator())

        let volUpItem = NSMenuItem(title: "Volume Up",
                                   action: #selector(volumeUp(_:)),
                                   keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        volUpItem.keyEquivalentModifierMask = .command
        volUpItem.target = self
        playbackMenu.addItem(volUpItem)

        let volDownItem = NSMenuItem(title: "Volume Down",
                                     action: #selector(volumeDown(_:)),
                                     keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        volDownItem.keyEquivalentModifierMask = .command
        volDownItem.target = self
        playbackMenu.addItem(volDownItem)

        playbackMenu.addItem(.separator())

        let shuffleItem = NSMenuItem(title: "Shuffle",
                                     action: #selector(toggleShuffle(_:)),
                                     keyEquivalent: "s")
        shuffleItem.keyEquivalentModifierMask = [.command, .option]
        shuffleItem.target = self
        shuffleItem.tag = 20
        playbackMenu.addItem(shuffleItem)

        let endlessShuffleItem = NSMenuItem(title: "Endless Shuffle",
                                            action: #selector(toggleEndlessShuffle(_:)),
                                            keyEquivalent: "e")
        endlessShuffleItem.keyEquivalentModifierMask = [.command, .option]
        endlessShuffleItem.target = self
        endlessShuffleItem.tag = 21
        playbackMenu.addItem(endlessShuffleItem)

        let repeatOneItem = NSMenuItem(title: "Repeat One",
                                       action: #selector(toggleRepeatOne(_:)),
                                       keyEquivalent: "r")
        repeatOneItem.keyEquivalentModifierMask = [.command, .option]
        repeatOneItem.target = self
        repeatOneItem.tag = 22
        playbackMenu.addItem(repeatOneItem)

        playbackMenu.addItem(.separator())

        let speedItem = NSMenuItem(title: "Playback Speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu(title: "Playback Speed")
        for option in PlaybackSpeedOption.all {
            let item = NSMenuItem(title: option.title,
                                  action: #selector(setPlaybackSpeedFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = 1000 + option.tag
            speedMenu.addItem(item)
        }
        speedItem.submenu = speedMenu
        playbackMenu.addItem(speedItem)

        // ── Video menu ──────────────────────────────────────────────────────
        let videoItem = NSMenuItem()
        mainMenu.addItem(videoItem)
        let videoMenu = NSMenu(title: "Video")
        videoItem.submenu = videoMenu

        let fitItem = NSMenuItem(title: "Fit",
                                 action: #selector(setScaleFit(_:)),
                                 keyEquivalent: "1")
        fitItem.target = self
        fitItem.tag = 1
        videoMenu.addItem(fitItem)

        let fillItem = NSMenuItem(title: "Fill",
                                  action: #selector(setScaleFill(_:)),
                                  keyEquivalent: "2")
        fillItem.target = self
        fillItem.tag = 2
        videoMenu.addItem(fillItem)

        let stretchItem = NSMenuItem(title: "Stretch",
                                     action: #selector(setScaleStretch(_:)),
                                     keyEquivalent: "3")
        stretchItem.target = self
        stretchItem.tag = 3
        videoMenu.addItem(stretchItem)

        // ── Window menu ─────────────────────────────────────────────────────
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")

        windowMenu.addItem(.separator())

        let gridItem = NSMenuItem(title: "Four Window Grid",
                                  action: #selector(fourWindowGrid(_:)),
                                  keyEquivalent: "4")
        gridItem.keyEquivalentModifierMask = .command
        gridItem.target = self
        windowMenu.addItem(gridItem)

        windowMenu.addItem(.separator())

        let keepAtTopItem = NSMenuItem(title: "Keep Window On Top",
                                       action: #selector(toggleKeepAtTop(_:)),
                                       keyEquivalent: "")
        keepAtTopItem.target = self
        keepAtTopItem.tag    = 30
        windowMenu.addItem(keepAtTopItem)

        let autoHideTitlebarItem = NSMenuItem(title: "Auto-hide Titlebar",
                                              action: #selector(toggleAutoHideTitlebar(_:)),
                                              keyEquivalent: "")
        autoHideTitlebarItem.target = self
        autoHideTitlebarItem.tag    = 31
        windowMenu.addItem(autoHideTitlebarItem)

        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc func toggleKeepAtTop(_ sender: Any) {
        frontPlayerWindowController?.toggleKeepAtTop()
    }

    @objc func toggleAutoHideTitlebar(_ sender: Any) {
        let current = SettingsWindowController.isAutoHideTitlebarEnabled()
        UserDefaults.standard.set(!current, forKey: SettingsWindowController.autoHideTitlebarKey)
        NotificationCenter.default.post(name: .autoHideTitlebarChanged, object: nil)
    }
}
