import Cocoa

private enum MediaDropRouting {
    static func readDroppedURLs(from sender: NSDraggingInfo) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard
                .readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else { return nil }
        return urls
    }

    static func isValidDrop(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = readDroppedURLs(from: sender) else { return false }
        return urls.contains { url in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue || MediaFileSupport.isSupported(url)
        }
    }

    static func performDrop(_ sender: NSDraggingInfo, in window: NSWindow?) -> Bool {
        guard let urls = readDroppedURLs(from: sender),
              let wc = window?.windowController as? PlayerWindowController else { return false }
        wc.handleDroppedURLs(urls, appendingExplicitFiles: true)
        return true
    }
}

/// The NSView into which VLCMediaPlayer renders its video output.
/// Background is black. Scroll wheel adjusts volume (0–150), clamped.
/// Double-click toggles fullscreen. Accepts file/folder drops (single or multi).
/// Space / Left / Right arrow keys drive transport when this view is first responder.
class VideoSurfaceView: NSView {

    private var isDragHighlighted = false

    /// Timer that fires repeated configured-duration seeks while Left/Right Arrow is held.
    /// Nil when no key is held.
    private var seekTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used – UI is programmatic")
    }

    override var acceptsFirstResponder: Bool { true }
    // L1: full-bleed black/video host — no transparency needed.
    override var isOpaque: Bool { true }

    // MARK: - Keyboard transport (Space / ← / →)
    //
    // Space is also wired as a menu key-equivalent (Play/Pause menu item) and will be
    // intercepted by NSApplication before keyDown in most cases.  Handling it here as
    // well provides a fallback (e.g., while a sheet is closing) and does no harm.
    //
    // Left / Right Arrows are NOT in the menu and only reach here when this view owns
    // first-responder focus — i.e. not when a text field or other control is active.

    override func keyDown(with event: NSEvent) {
        guard let wc = window?.windowController as? PlayerWindowController else {
            super.keyDown(with: event)
            return
        }
        wc.noteChromeActivity()
        switch event.keyCode {
        case 49:   // Space — play/pause, no repeat
            if !event.isARepeat { wc.togglePlayPause() }
        case 123:  // Left Arrow — rewind configured duration; hold-to-repeat
            if !event.isARepeat {
                seekTimer?.invalidate()
                wc.skipBackward10()
                scheduleSeekRepeat(backward: true, controller: wc)
            }
        case 124:  // Right Arrow — forward configured duration; hold-to-repeat
            if !event.isARepeat {
                seekTimer?.invalidate()
                wc.skipForward10()
                scheduleSeekRepeat(backward: false, controller: wc)
            }
        case 125:  // Down Arrow — volume down
            wc.volumeDown()
        case 126:  // Up Arrow — volume up
            wc.volumeUp()
        default:
            // Option-Q: secondary custom-prefix rename. Checked before noMods block.
            let optionOnly = event.modifierFlags.intersection([.command, .control, .shift]).isEmpty
                && event.modifierFlags.contains(.option)
            if optionOnly, !event.isARepeat,
               let chars = event.charactersIgnoringModifiers, chars == "q" {
                wc.performSecondaryCustomPrefixRenameCurrentItem(source: "videoPage-optQ")
                return
            }
            // Character shortcuts — video player mode only, no modifier keys.
            // Cmd+1/2/3 go through the menu system before reaching here, so
            // plain 1/3 do not conflict with the Video > Fit/Stretch menu items.
            let noMods = event.modifierFlags
                .intersection([.command, .option, .control, .shift]).isEmpty
            if noMods, let chars = event.charactersIgnoringModifiers {
                switch chars {
                case "1":
                    SettingsWindowController.setSkipDuration(10)
                    return
                case "3":
                    SettingsWindowController.setSkipDuration(30)
                    return
                case "6":
                    SettingsWindowController.setSkipDuration(60)
                    return
                case "9":
                    SettingsWindowController.setSkipDuration(180)
                    return
                case "z":
                    if !event.isARepeat { wc.playPrevious() }
                    return
                case "x":
                    if !event.isARepeat { wc.playNext() }
                    return
                case "q":
                    if !event.isARepeat { wc.performCustomPrefixRenameCurrentItem(source: "videoPage-Q") }
                    return
                case "b":
                    if !event.isARepeat { wc.toggleBookmark() }
                    return
                default:
                    break
                }
            }
            super.keyDown(with: event)
        }
    }

    /// Cancel the hold-to-seek timer the moment Left/Right Arrow is released.
    override func keyUp(with event: NSEvent) {
        switch event.keyCode {
        case 123, 124:
            seekTimer?.invalidate()
            seekTimer = nil
        default:
            super.keyUp(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        (window?.windowController as? PlayerWindowController)?.noteChromeActivity()
        super.flagsChanged(with: event)
    }

    /// Start a two-phase timer for smooth hold-to-seek:
    ///   Phase 1 — 350 ms initial delay (avoids spurious repeat on quick taps)
    ///   Phase 2 — 80 ms repeating interval (smooth continued seeking)
    private func scheduleSeekRepeat(backward: Bool, controller: PlayerWindowController) {
        seekTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self, weak controller] _ in
            guard let self = self, let wc = controller else { return }
            self.seekTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak wc] _ in
                if backward { wc?.skipBackward10() } else { wc?.skipForward10() }
            }
        }
    }

    // MARK: - Scroll / Volume

    /// Vertical scroll adjusts volume. Scroll down = louder, scroll up = quieter
    /// (reversed from natural direction per user preference).
    override func scrollWheel(with event: NSEvent) {
        guard let wc = window?.windowController as? PlayerWindowController else {
            super.scrollWheel(with: event)
            return
        }
        // Negate deltaY: scroll up (positive deltaY with natural scrolling) → quieter
        let delta = Int(-event.deltaY * 5.0)
        wc.adjustVolume(by: delta)
    }

    // MARK: - Double-click fullscreen

    override func mouseDown(with event: NSEvent) {
        // Clicking the video area makes it first responder so keyboard events land here
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            window?.toggleFullScreen(nil)
        }
        super.mouseDown(with: event)
    }

    // MARK: - Drag highlight

    private func setDragHighlight(_ on: Bool) {
        guard isDragHighlighted != on else { return }
        isDragHighlighted = on
        layer?.borderWidth = on ? 3 : 0
        layer?.borderColor = NSColor.systemBlue.cgColor
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isValidDrop(sender) else { return [] }
        setDragHighlight(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isValidDrop(sender) else {
            setDragHighlight(false)
            return []
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDragHighlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDragHighlight(false)
        return MediaDropRouting.performDrop(sender, in: window)
    }

    private func isValidDrop(_ sender: NSDraggingInfo) -> Bool {
        MediaDropRouting.isValidDrop(sender)
    }
}

final class ImageSurfaceView: NSImageView {
    private var isDragHighlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageScaling = .scaleProportionallyUpOrDown
        imageAlignment = .alignCenter
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used – UI is programmatic")
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.toggleFullScreen(nil)
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let wc = window?.windowController as? PlayerWindowController else {
            super.keyDown(with: event)
            return
        }
        let noMods = event.modifierFlags
            .intersection([.command, .option, .control, .shift]).isEmpty
        if noMods, let chars = event.charactersIgnoringModifiers, chars == "b" {
            if !event.isARepeat { wc.toggleBookmark() }
            return
        }
        super.keyDown(with: event)
    }

    private func setDragHighlight(_ on: Bool) {
        guard isDragHighlighted != on else { return }
        isDragHighlighted = on
        layer?.borderWidth = on ? 3 : 0
        layer?.borderColor = NSColor.systemBlue.cgColor
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard MediaDropRouting.isValidDrop(sender) else { return [] }
        setDragHighlight(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard MediaDropRouting.isValidDrop(sender) else {
            setDragHighlight(false)
            return []
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDragHighlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDragHighlight(false)
        return MediaDropRouting.performDrop(sender, in: window)
    }
}
