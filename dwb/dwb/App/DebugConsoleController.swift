import Cocoa

// MARK: - Debug level

enum DebugLevel: Int, Comparable {
    case info = 0, warning, error

    static func < (lhs: DebugLevel, rhs: DebugLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Log entry

struct DebugLogEntry {
    let date: Date
    let level: DebugLevel
    let category: String
    let message: String
}

// MARK: - Controller

/// App-wide in-app debug console. Off by default; toggle in Settings > Developer.
/// Ring buffer of 1000 entries. Supports category, level, and text filtering,
/// plus Pause/Resume for freezing the visible log while the app continues buffering.
final class DebugConsoleController: NSWindowController {

    static let shared = DebugConsoleController()

    // MARK: - Constants

    private static let maxEntries = 1000

    // MARK: - Buffer state

    private var entries: [DebugLogEntry] = []
    private(set) var isEnabled: Bool = false
    private var isPaused: Bool = false
    private var knownCategories: [String] = []

    // MARK: - Filter state

    private var filterCategory: String? = nil     // nil = all categories
    private var filterMinLevel: DebugLevel? = nil // nil = all levels
    private var filterText: String = ""

    // MARK: - UI

    private let textView          = NSTextView()
    private let scrollView        = NSScrollView()
    private let searchField       = NSSearchField()
    private let categoryPopup     = NSPopUpButton()
    private let levelSegment      = NSSegmentedControl()
    private let pauseButton       = NSButton()
    private let statusLabel       = NSTextField(labelWithString: "")

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // Text attributes by level
    private lazy var infoAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.white
    ]
    private lazy var warnAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor(red: 1.0, green: 0.85, blue: 0.3, alpha: 1.0)
    ]
    private lazy var errorAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor(red: 1.0, green: 0.45, blue: 0.45, alpha: 1.0)
    ]

    // MARK: - Log entry points (main-thread only; dispatches if called off-main)

    static func log(_ category: String, _ message: String) {
        log(level: .info, category: category, message: message)
    }

    static func log(level: DebugLevel, category: String, message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { log(level: level, category: category, message: message) }
            return
        }
        guard shared.isEnabled else { return }
        shared.appendEntry(DebugLogEntry(date: Date(), level: level, category: category, message: message))
    }

    // MARK: - Internal append

    private func appendEntry(_ entry: DebugLogEntry) {
        let isNewCategory = !knownCategories.contains(entry.category)
        if isNewCategory {
            knownCategories.append(entry.category)
            knownCategories.sort()
            rebuildCategoryPopup()
        }

        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
            if !isPaused { rebuildTextView() }
            updateStatus()
            return
        }

        if !isPaused, entryMatchesFilters(entry), window?.isVisible == true {
            let str = NSAttributedString(string: formatEntry(entry) + "\n",
                                         attributes: attrsFor(entry.level))
            textView.textStorage?.append(str)
            textView.scrollToEndOfDocument(nil)
        }
        updateStatus()
    }

    // MARK: - Filtering

    private func entryMatchesFilters(_ entry: DebugLogEntry) -> Bool {
        if let cat = filterCategory, cat != entry.category { return false }
        if let minLev = filterMinLevel, entry.level < minLev { return false }
        if !filterText.isEmpty {
            let q = filterText.lowercased()
            if !entry.message.lowercased().contains(q) && !entry.category.lowercased().contains(q) {
                return false
            }
        }
        return true
    }

    private func visibleEntries() -> [DebugLogEntry] {
        entries.filter { entryMatchesFilters($0) }
    }

    private func rebuildTextView() {
        guard let storage = textView.textStorage else { return }
        let combined = NSMutableAttributedString()
        for e in visibleEntries() {
            combined.append(NSAttributedString(string: formatEntry(e) + "\n",
                                               attributes: attrsFor(e.level)))
        }
        storage.setAttributedString(combined)
        textView.scrollToEndOfDocument(nil)
    }

    private func updateStatus() {
        let total   = entries.count
        let visible = filterCategory == nil && filterMinLevel == nil && filterText.isEmpty
            ? total
            : visibleEntries().count
        let pausedSuffix = isPaused ? " — PAUSED" : ""
        statusLabel.stringValue = "Showing \(visible) of \(total) total\(pausedSuffix)"
    }

    private func formatEntry(_ entry: DebugLogEntry) -> String {
        let ts = timeFormatter.string(from: entry.date)
        switch entry.level {
        case .info:    return "[\(ts)] [\(entry.category)] \(entry.message)"
        case .warning: return "[\(ts)] [WARN] [\(entry.category)] \(entry.message)"
        case .error:   return "[\(ts)] [ERR ] [\(entry.category)] \(entry.message)"
        }
    }

    private func attrsFor(_ level: DebugLevel) -> [NSAttributedString.Key: Any] {
        switch level {
        case .info:    return infoAttrs
        case .warning: return warnAttrs
        case .error:   return errorAttrs
        }
    }

    // MARK: - Category popup

    private func rebuildCategoryPopup() {
        let selected = filterCategory
        categoryPopup.removeAllItems()
        categoryPopup.addItem(withTitle: "All Categories")
        categoryPopup.lastItem?.tag = -1
        for cat in knownCategories {
            categoryPopup.addItem(withTitle: cat)
        }
        if let cat = selected,
           let item = categoryPopup.itemArray.first(where: { $0.title == cat }) {
            categoryPopup.select(item)
        } else {
            categoryPopup.selectItem(withTag: -1)
        }
    }

    // MARK: - Settings observation

    @objc private func debugConsoleSettingDidChange() {
        let enabled = SettingsWindowController.isDebugConsoleEnabled()
        if enabled && !isEnabled {
            isEnabled = true
            rebuildTextView()
            updateStatus()
            showWindow(nil)
            appendEntry(DebugLogEntry(date: Date(), level: .info,
                                      category: "console", message: "Debug Console enabled"))
        } else if !enabled && isEnabled {
            appendEntry(DebugLogEntry(date: Date(), level: .info,
                                      category: "console", message: "Debug Console disabled"))
            isEnabled = false
            window?.orderOut(nil)
        }
    }

    // MARK: - Button actions

    @objc private func pauseTapped() {
        isPaused.toggle()
        pauseButton.title = isPaused ? "Resume" : "Pause"
        if !isPaused {
            rebuildTextView()
        }
        updateStatus()
    }

    @objc private func clearTapped() {
        entries.removeAll()
        knownCategories.removeAll()
        filterCategory = nil
        rebuildCategoryPopup()
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        updateStatus()
    }

    @objc private func copyAllTapped() {
        let text = entries.map { formatEntry($0) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func exportTapped() {
        let panel = NSSavePanel()
        panel.title = "Export Debug Log"
        let safe = timeFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        panel.nameFieldStringValue = "dwb-debug-\(safe).txt"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self = self else { return }
            let text = self.entries.map { self.formatEntry($0) }.joined(separator: "\n")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func copySnapshotTapped() {
        let total = entries.count
        let visible = visibleEntries().count
        let pausedNote = isPaused ? " [PAUSED]" : ""
        let ts = timeFormatter.string(from: Date())
        var lines: [String] = [
            "dwb Debug Snapshot — \(ts)",
            "Buffer: \(total) entries, \(visible) visible\(pausedNote)",
            ""
        ]
        let recent = entries.suffix(20)
        lines.append("Last \(recent.count) of \(total) entries:")
        lines.append(contentsOf: recent.map { formatEntry($0) })
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @objc private func categoryChanged(_ sender: NSPopUpButton) {
        let title = sender.titleOfSelectedItem ?? ""
        filterCategory = (title == "All Categories") ? nil : title
        if !isPaused { rebuildTextView() }
        updateStatus()
    }

    @objc private func levelChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 1:  filterMinLevel = .warning
        case 2:  filterMinLevel = .error
        default: filterMinLevel = nil
        }
        if !isPaused { rebuildTextView() }
        updateStatus()
    }

    @objc private func searchTextChanged(_ notification: Notification) {
        filterText = searchField.stringValue
        if !isPaused { rebuildTextView() }
        updateStatus()
    }

    // MARK: - Init

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "dwb Debug Console"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 500, height: 300)
        super.init(window: panel)
        buildUI()
        isEnabled = SettingsWindowController.isDebugConsoleEnabled()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(debugConsoleSettingDidChange),
            name: .debugConsoleSettingChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(searchTextChanged(_:)),
            name: NSControl.textDidChangeNotification,
            object: searchField
        )
        if isEnabled { showWindow(nil) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI construction

    private func buildUI() {
        guard let cv = window?.contentView else { return }
        let bg     = NSColor(white: 0.09, alpha: 1.0)
        let barBg  = NSColor(white: 0.13, alpha: 1.0)
        window?.backgroundColor = bg

        // ── Toolbar (bottom) ──────────────────────────────────────────
        let toolbarH: CGFloat = 76
        let toolbar = NSView(frame: NSRect(x: 0, y: 0, width: cv.bounds.width, height: toolbarH))
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = barBg.cgColor
        toolbar.autoresizingMask = [.width]
        cv.addSubview(toolbar)

        let W = cv.bounds.width   // 780

        // Row 0 — status label (y: 4, h: 14)
        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        statusLabel.frame = NSRect(x: 8, y: 4, width: W - 16, height: 14)
        statusLabel.autoresizingMask = [.width]
        toolbar.addSubview(statusLabel)

        // Row 1 — filter controls (y: 22, h: 24)
        let filterY: CGFloat = 22
        let filterH: CGFloat = 24
        let catW:    CGFloat = 140
        let lvlW:    CGFloat = 130
        let gap:     CGFloat = 6
        let searchW  = W - 8 - gap - catW - gap - lvlW - 8

        searchField.placeholderString = "Filter…"
        searchField.font = .systemFont(ofSize: 11)
        searchField.frame = NSRect(x: 8, y: filterY, width: searchW, height: filterH)
        searchField.autoresizingMask = [.width]
        toolbar.addSubview(searchField)

        categoryPopup.font = .systemFont(ofSize: 11)
        categoryPopup.target = self
        categoryPopup.action = #selector(categoryChanged(_:))
        categoryPopup.addItem(withTitle: "All Categories")
        categoryPopup.lastItem?.tag = -1
        categoryPopup.frame = NSRect(x: W - lvlW - gap - catW - 8, y: filterY, width: catW, height: filterH)
        categoryPopup.autoresizingMask = [.minXMargin]
        toolbar.addSubview(categoryPopup)

        levelSegment.segmentCount = 3
        levelSegment.setLabel("All",   forSegment: 0)
        levelSegment.setLabel("⚠ Warn", forSegment: 1)
        levelSegment.setLabel("✕ Err",  forSegment: 2)
        levelSegment.selectedSegment = 0
        levelSegment.target = self
        levelSegment.action = #selector(levelChanged(_:))
        levelSegment.frame = NSRect(x: W - lvlW - 8, y: filterY, width: lvlW, height: filterH)
        levelSegment.autoresizingMask = [.minXMargin]
        toolbar.addSubview(levelSegment)

        // Row 2 — action buttons (y: 50, h: 20)
        let btnY: CGFloat = 50
        let btnH: CGFloat = 20

        func makeBtn(_ title: String, action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .inline
            b.sizeToFit()
            return b
        }

        let btns: [(NSButton)] = [
            makeBtn("Clear",    action: #selector(clearTapped)),
            makeBtn("Copy All", action: #selector(copyAllTapped)),
            makeBtn("Snapshot", action: #selector(copySnapshotTapped)),
            makeBtn("Export…",  action: #selector(exportTapped)),
        ]
        var bx: CGFloat = 8
        for btn in btns {
            let bw = max(54, btn.frame.width + 6)
            btn.frame = NSRect(x: bx, y: btnY, width: bw, height: btnH)
            toolbar.addSubview(btn)
            bx += bw + 4
        }

        pauseButton.title = "Pause"
        pauseButton.bezelStyle = .inline
        pauseButton.target = self
        pauseButton.action = #selector(pauseTapped)
        pauseButton.sizeToFit()
        let pauseW = max(60, pauseButton.frame.width + 8)
        pauseButton.frame = NSRect(x: W - pauseW - 8, y: btnY, width: pauseW, height: btnH)
        pauseButton.autoresizingMask = [.minXMargin]
        toolbar.addSubview(pauseButton)

        // ── Scroll view ───────────────────────────────────────────────
        scrollView.frame = NSRect(x: 0, y: toolbarH, width: W, height: cv.bounds.height - toolbarH)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = bg
        cv.addSubview(scrollView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = bg
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView

        updateStatus()
    }
}
