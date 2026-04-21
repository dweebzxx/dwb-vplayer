import Cocoa

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
        default:
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
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard
                .readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else { return false }
        guard let wc = window?.windowController as? PlayerWindowController else { return false }
        // Explicit file drops append to this window's queue; folder drops still replace.
        wc.handleDroppedURLs(urls, appendingExplicitFiles: true)
        return true
    }

    private func isValidDrop(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard
                .readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else { return false }
        // Accept if any URL is a directory or a supported media file
        return urls.contains { url in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue || MediaFileSupport.isSupported(url)
        }
    }
}
