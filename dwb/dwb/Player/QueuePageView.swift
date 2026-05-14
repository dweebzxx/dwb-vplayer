import Cocoa

/// Delegate for queue-page interactions.
protocol QueuePageViewDelegate: AnyObject {
    func queuePage(_ view: QueuePageView, didSelectDisplayIndex index: Int)
    func queuePage(_ view: QueuePageView, didRequestRenameAt index: Int)
    func queuePage(_ view: QueuePageView, didRequestRevealAt index: Int)
    func queuePage(_ view: QueuePageView, didRequestDeleteAt index: Int)
    func queuePage(_ view: QueuePageView, didChangeSortMode mode: QueueSortMode)
    func queuePageDidRequestClose(_ view: QueuePageView)
    /// Called when the user drags a row from `from` to the insertion point `to`
    /// (NSTableView .above drop-operation semantics; 0…items.count).
    func queuePage(_ view: QueuePageView, didReorderFromIndex from: Int, toIndex to: Int)
    /// Called when the user activates "Remove All" in the queue page.
    func queuePageDidRequestRemoveAll(_ view: QueuePageView)
    /// Called when the user triggers the one-click x_ prefix rename action (feature-gated).
    func queuePage(_ view: QueuePageView, didRequestXPrefixRenameAt index: Int)
    /// Called when the user triggers the one-click custom prefix rename action (feature-gated).
    /// `indices` is always ascending. Caller must preflight all targets before renaming any.
    func queuePage(_ view: QueuePageView, didRequestCustomPrefixRenameAt indices: [Int])
    /// Called when the user presses Delete/Backspace with multiple rows selected.
    /// `indices` is sorted descending so the caller can delete safely without index shifts.
    func queuePage(_ view: QueuePageView, didRequestDeleteRows indices: [Int])
}

/// Full in-window Queue Page panel.
/// Designed to occupy ~35–45 % of the window width as a right-side panel.
/// Shows the playback set in current traversal order with filename, duration,
/// and file size. Supports single-click selection, double-click playback, and
/// queue file actions.
final class QueuePageView: NSView {

    fileprivate enum Palette {
        static let panel = NSColor(calibratedWhite: 0.105, alpha: 1.0)
        static let header = NSColor(calibratedWhite: 0.085, alpha: 1.0)
        static let columnHeader = NSColor(calibratedWhite: 0.125, alpha: 1.0)
        static let footer = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        static let separator = NSColor.white.withAlphaComponent(0.075)
        static let primaryText = NSColor.white.withAlphaComponent(0.84)
        static let secondaryText = NSColor.white.withAlphaComponent(0.58)
        static let tertiaryText = NSColor.white.withAlphaComponent(0.42)
        static let currentText = NSColor.white.withAlphaComponent(0.92)
        static let currentFill = NSColor.controlAccentColor.withAlphaComponent(0.14)
        static let currentBar = NSColor.controlAccentColor.withAlphaComponent(0.88)
        static let selectedFill = NSColor.white.withAlphaComponent(0.10)
    }

    // MARK: - Item model

    struct Item {
        let url:         URL
        var displayName: String
        var duration:    String   // "1:23:45" or "--:--"
        var fileSize:    String   // "12.3 MB" or "--"
    }

    // MARK: - Public state

    weak var delegate: QueuePageViewDelegate?

    /// Call update(items:currentIndex:) to refresh data and reload the table.
    private(set) var items: [Item] = []
    private(set) var currentDisplayIndex: Int = -1
    private var currentSortMode: QueueSortMode = .manual
    private var allowsManualReorder = true
    private var isUpdatingSortControl = false

    /// When true, the one-click x_ prefix rename button is shown in the bottom bar.
    var isXPrefixRenameEnabled: Bool = false {
        didSet {
            xPrefixButton.isHidden = !isXPrefixRenameEnabled
            needsLayout = true
        }
    }

    /// When true, the one-click custom prefix rename button is shown in the bottom bar.
    var isCustomPrefixRenameEnabled: Bool = false {
        didSet {
            customPrefixButton.isHidden = !isCustomPrefixRenameEnabled
            needsLayout = true
        }
    }

    func update(items: [Item], currentIndex: Int, sortMode: QueueSortMode, totalDurationText: String) {
        let scroll = currentIndex != currentDisplayIndex && currentIndex >= 0
        self.items = items
        self.currentDisplayIndex = currentIndex
        currentSortMode = sortMode
        allowsManualReorder = sortMode == .manual
        updateSortControlSelection()
        totalDurationLabel.stringValue = "Total: \(totalDurationText)"
        tableView.reloadData()
        if scroll { tableView.scrollRowToVisible(currentIndex) }
        applyColumnLayout(reason: "queue-reload", forceDiagnostic: false)
    }

    // MARK: - Subviews

    private let headerView       = NSView()
    private let titleLabel       = NSTextField(labelWithString: "Queue")
    private let sortPopUpButton  = NSPopUpButton()
    private let closeButton      = NSButton()
    private let topSeparator     = NSView()
    let scrollView               = NSScrollView()
    let tableView                = QueuePageTableView()
    private let bottomSeparator  = NSView()
    private let bottomBar        = NSView()
    private let renameButton     = NSButton()
    private let deleteButton     = NSButton()
    private let xPrefixButton       = NSButton()
    private let customPrefixButton  = NSButton()
    private let removeAllButton  = NSButton()
    private let totalDurationLabel = NSTextField(labelWithString: "Total: 00:00:00")

    // Column identifiers
    private static let colName = NSUserInterfaceItemIdentifier("name")
    private static let colDur  = NSUserInterfaceItemIdentifier("dur")
    private static let colSize = NSUserInterfaceItemIdentifier("size")

    // UserDefaults keys for optional column visibility (Duration and Size).
    // File column is always visible; these default to true.
    static let durationColumnVisibleKey = "com.dwb.queueColumnDurationVisible"
    static let sizeColumnVisibleKey     = "com.dwb.queueColumnSizeVisible"
    static let durationColumnWidthKey   = "com.dwb.queueColumnDurationWidth"
    static let sizeColumnWidthKey       = "com.dwb.queueColumnSizeWidth"

    private static let fileColumnMinimumWidth: CGFloat = 180

    // Shared metadata-column dimensions so Duration and Size are equal width.
    // Fixed adaptive widths for Duration/Size — no user-driven resize as of P43.4.
    // Old `*WidthKey` UserDefaults values from P43.2/P43.3 are intentionally ignored.
    private static let metadataColumnDefaultWidth: CGFloat = 104
    private static let metadataColumnMinimumWidth: CGFloat = 88

    private static let durationColumnDefaultWidth = metadataColumnDefaultWidth
    private static let durationColumnMinimumWidth = metadataColumnMinimumWidth

    private static let sizeColumnDefaultWidth = metadataColumnDefaultWidth
    private static let sizeColumnMinimumWidth = metadataColumnMinimumWidth

    // Footer-safe trailing boundary: keeps the total-duration label visually
    // separated from the far-right panel edge, aligning it under the metadata
    // columns rather than hugging the Size column's right text edge. This is
    // intentionally a footer-only inset; it does not affect column/header/row geometry.
    private static let totalDurationTrailingInset: CGFloat = 72

    // Padding constants used by QueueColumnGeometry to keep header labels, row
    // cells, and the bottom total-duration label aligned to the same content insets.
    fileprivate static let cellLeadingPadding: CGFloat = 8
    fileprivate static let cellTrailingPadding: CGFloat = 8

    // Pasteboard type for internal row-reorder drag
    private static let draggedRowType = NSPasteboard.PasteboardType("com.dwb.queueRow")
    private var lastCoordinateDiagnosticTimeByReason: [String: Date] = [:]

    // Layout reentrancy guard and coalescing state.
    // isApplyingColumnLayout is set while inside applyColumnLayout; prevents
    // synchronous recursion. pendingColumnLayout captures any request that
    // arrives while the guard is held — the defer block drains it via
    // DispatchQueue.main.async so it never recurses on the same call stack.
    private var isApplyingColumnLayout = false
    private var pendingColumnLayout: (reason: String, force: Bool)? = nil

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupViews()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupViews() {
        layer?.backgroundColor = Palette.panel.cgColor

        // ── Header ──────────────────────────────────────────────────────────
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = Palette.header.cgColor
        addSubview(headerView)

        titleLabel.font           = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor      = Palette.primaryText
        titleLabel.drawsBackground = false
        titleLabel.isEditable     = false
        titleLabel.isBordered     = false
        headerView.addSubview(titleLabel)

        sortPopUpButton.font = .systemFont(ofSize: 10.5, weight: .regular)
        sortPopUpButton.bezelStyle = .rounded
        sortPopUpButton.target = self
        sortPopUpButton.action = #selector(sortModeChanged)
        sortPopUpButton.toolTip = "Queue sort order"
        sortPopUpButton.setAccessibilityLabel("Queue sort order")
        QueueSortMode.allCases.forEach { mode in
            sortPopUpButton.addItem(withTitle: mode.title)
            sortPopUpButton.lastItem?.tag = mode.rawValue
        }
        updateSortControlSelection()
        headerView.addSubview(sortPopUpButton)

        closeButton.isBordered     = false
        closeButton.bezelStyle     = .regularSquare
        closeButton.imageScaling   = .scaleProportionallyDown
        let xCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        if let img = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Queue") {
            closeButton.image = img.withSymbolConfiguration(xCfg) ?? img
        }
        closeButton.contentTintColor = Palette.secondaryText
        closeButton.toolTip          = "Close Queue"
        closeButton.setAccessibilityLabel("Close Queue")
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        headerView.addSubview(closeButton)

        // ── Separators ────────────────────────────────────────────────────
        for sep in [topSeparator, bottomSeparator] {
            sep.wantsLayer = true
            sep.layer?.backgroundColor = Palette.separator.cgColor
            addSubview(sep)
        }

        // ── Table ─────────────────────────────────────────────────────────
        // NSTableColumn.minWidth is intentionally tiny (1) so AppKit cannot clamp
        // the real column widths back to a hard minimum and defeat the no-overflow
        // layout below. The `fileColumnMinimumWidth`, `durationColumnMinimumWidth`,
        // and `sizeColumnMinimumWidth` constants are layout *preferences* honored by
        // `applyColumnLayout`, not AppKit-enforced minimums. When the panel is too
        // narrow, the layout must be allowed to shrink rather than have AppKit
        // force the column sum past the visible clip width.
        let nameCol = NSTableColumn(identifier: Self.colName)
        nameCol.title  = "File"
        nameCol.resizingMask = []
        nameCol.minWidth = 1
        nameCol.headerCell = QueueColumnHeaderCell(title: "File", alignment: .left)

        let durCol  = NSTableColumn(identifier: Self.colDur)
        durCol.title = "Duration"
        durCol.width = Self.durationColumnDefaultWidth
        durCol.minWidth = 1
        durCol.maxWidth = Self.durationColumnDefaultWidth
        durCol.resizingMask = []
        durCol.headerCell = QueueColumnHeaderCell(title: "Duration", alignment: .center)

        let sizeCol = NSTableColumn(identifier: Self.colSize)
        sizeCol.title = "Size"
        sizeCol.width = Self.sizeColumnDefaultWidth
        sizeCol.minWidth = 1
        sizeCol.maxWidth = Self.sizeColumnDefaultWidth
        sizeCol.resizingMask = []
        sizeCol.headerCell = QueueColumnHeaderCell(title: "Size", alignment: .right)

        tableView.addTableColumn(nameCol)
        tableView.addTableColumn(durCol)
        tableView.addTableColumn(sizeCol)
        // applyColumnLayout() is the single source of truth; AppKit must not mutate widths.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        let nativeHeaderView = QueueTableHeaderView()
        nativeHeaderView.frame = NSRect(x: 0, y: 0, width: 0, height: colHeaderH)
        nativeHeaderView.menuProvider = { [weak self] in self?.makeColumnVisibilityMenu() }
        tableView.headerView   = nativeHeaderView
        tableView.rowHeight    = 26
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsMultipleSelection = true
        tableView.dataSource   = self
        tableView.delegate     = self
        tableView.target       = self
        tableView.action       = #selector(rowClicked)
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.contextMenuProvider = { [weak self] row in
            self?.makeContextMenu(for: row)
        }

        // Enable row reordering via drag-and-drop
        tableView.registerForDraggedTypes([Self.draggedRowType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        // Apply persisted optional column visibility (Duration and Size).
        // Registered defaults are true, so both columns are visible on fresh install.
        let defaults = UserDefaults.standard
        durCol.isHidden  = !defaults.bool(forKey: Self.durationColumnVisibleKey)
        sizeCol.isHidden = !defaults.bool(forKey: Self.sizeColumnVisibleKey)

        let lockedClipView = LockedHorizontalClipView()
        lockedClipView.drawsBackground = false
        scrollView.contentView          = lockedClipView
        scrollView.documentView           = tableView
        scrollView.hasVerticalScroller     = true
        scrollView.hasHorizontalScroller   = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true
        scrollView.autohidesScrollers      = true
        scrollView.borderType              = .noBorder
        scrollView.backgroundColor         = .clear
        addSubview(scrollView)

        // Re-run the column layout when the clip view's width changes — this happens
        // when the vertical scroller toggles, which would otherwise leave the Size
        // column extending past the visible cell area on the right edge.
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(scrollContentDidResize),
                                               name: NSView.frameDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(scrollContentDidResize),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)

        // ── Bottom bar ────────────────────────────────────────────────────
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = Palette.footer.cgColor
        addSubview(bottomBar)

        renameButton.isBordered     = false
        renameButton.bezelStyle     = .regularSquare
        renameButton.imageScaling   = .scaleProportionallyDown
        let pencilCfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        if let img = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Rename") {
            renameButton.image = img.withSymbolConfiguration(pencilCfg) ?? img
        }
        renameButton.contentTintColor = Palette.secondaryText
        renameButton.toolTip   = "Rename selected file"
        renameButton.setAccessibilityLabel("Rename selected file")
        renameButton.target    = self
        renameButton.action    = #selector(renameTapped)
        bottomBar.addSubview(renameButton)

        deleteButton.isBordered     = false
        deleteButton.bezelStyle     = .regularSquare
        deleteButton.imageScaling   = .scaleProportionallyDown
        let trashCfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        if let img = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove") {
            deleteButton.image = img.withSymbolConfiguration(trashCfg) ?? img
        }
        deleteButton.contentTintColor = NSColor.systemRed.withAlphaComponent(0.70)
        deleteButton.toolTip   = "Remove selected file(s) from queue"
        deleteButton.setAccessibilityLabel("Remove selected file(s) from queue")
        deleteButton.target    = self
        deleteButton.action    = #selector(deleteTapped)
        bottomBar.addSubview(deleteButton)

        xPrefixButton.isBordered     = false
        xPrefixButton.bezelStyle     = .regularSquare
        xPrefixButton.font           = .systemFont(ofSize: 10.5, weight: .semibold)
        xPrefixButton.title          = "x_"
        xPrefixButton.contentTintColor = NSColor.systemOrange.withAlphaComponent(0.85)
        xPrefixButton.toolTip        = "Prefix filename with x_ (one-click, no dialog)"
        xPrefixButton.setAccessibilityLabel("Prefix selected filename with x underscore")
        xPrefixButton.target         = self
        xPrefixButton.action         = #selector(xPrefixTapped)
        xPrefixButton.isHidden       = true
        bottomBar.addSubview(xPrefixButton)

        customPrefixButton.isBordered     = false
        customPrefixButton.bezelStyle     = .regularSquare
        customPrefixButton.imageScaling   = .scaleProportionallyDown
        let tagCfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        if let tagImg = NSImage(systemSymbolName: "tag", accessibilityDescription: "Apply custom prefix") {
            customPrefixButton.image = tagImg.withSymbolConfiguration(tagCfg) ?? tagImg
        }
        customPrefixButton.contentTintColor = NSColor.systemBlue.withAlphaComponent(0.85)
        customPrefixButton.toolTip          = "Apply custom prefix to selected filename(s) (one-click, no dialog)"
        customPrefixButton.setAccessibilityLabel("Apply configured custom prefix to selected file")
        customPrefixButton.target           = self
        customPrefixButton.action           = #selector(customPrefixTapped)
        customPrefixButton.isHidden         = true
        bottomBar.addSubview(customPrefixButton)

        removeAllButton.isBordered   = false
        removeAllButton.bezelStyle   = .regularSquare
        removeAllButton.font         = .systemFont(ofSize: 10.5, weight: .regular)
        removeAllButton.title        = "Remove All"
        removeAllButton.contentTintColor = NSColor.systemRed.withAlphaComponent(0.68)
        removeAllButton.toolTip      = "Remove all files from queue"
        removeAllButton.setAccessibilityLabel("Remove all files from queue")
        removeAllButton.target       = self
        removeAllButton.action       = #selector(removeAllTapped)
        bottomBar.addSubview(removeAllButton)

        // Wire up keyboard-delete handler so Delete/Backspace on a selected row
        // removes that item.  Re-selecting the appropriate row is handled after
        // the table reloads (see QueuePageTableView.keyDown).
        tableView.deleteRowsHandler = { [weak self] indices in
            guard let self = self else { return }
            if indices.count == 1 {
                self.delegate?.queuePage(self, didRequestDeleteAt: indices[0])
            } else {
                self.delegate?.queuePage(self, didRequestDeleteRows: indices)
            }
        }

        totalDurationLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        totalDurationLabel.textColor = Palette.tertiaryText
        totalDurationLabel.alignment = .right
        totalDurationLabel.lineBreakMode = .byClipping
        bottomBar.addSubview(totalDurationLabel)

        DispatchQueue.main.async { [weak self] in
            self?.applyColumnLayout(reason: "queue-setup", forceDiagnostic: true)
        }
    }

    // MARK: - Layout constants

    private let headerH:    CGFloat = 34
    private let colHeaderH: CGFloat = 22
    private let bottomH:    CGFloat = 28

    override func layout() {
        super.layout()
        let b = bounds

        // Header
        headerView.frame = NSRect(x: 0, y: b.height - headerH, width: b.width, height: headerH)
        let closeX = b.width - headerH + 6
        let sortWidth: CGFloat = 158
        let sortHeight: CGFloat = 24
        sortPopUpButton.frame = NSRect(x: max(92, closeX - sortWidth - 10),
                                       y: centeredY(height: sortHeight, in: headerH),
                                       width: sortWidth,
                                       height: sortHeight)
        // Title sits on the same leading inset as the File column header label and row
        // cells, so the top of the page reads as a single content edge.
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        titleLabel.frame = NSRect(x: Self.cellLeadingPadding,
                                  y: centeredY(height: titleHeight, in: headerH),
                                  width: max(0, sortPopUpButton.frame.minX - Self.cellLeadingPadding - 8),
                                  height: titleHeight)
        let closeSize = headerH - 10
        closeButton.frame = NSRect(x: closeX,
                                   y: centeredY(height: closeSize, in: headerH),
                                   width: closeSize,
                                   height: closeSize)

        topSeparator.frame = NSRect(x: 0, y: b.height - headerH - 1, width: b.width, height: 1)

        // Table scroll view
        let tableTop = b.height - headerH - 1
        let tableH   = max(0, tableTop - bottomH - 1)
        scrollView.frame = NSRect(x: 0, y: bottomH + 1, width: b.width, height: tableH)
        scrollView.layoutSubtreeIfNeeded()
        // Do not manually set tableView.headerView.frame here — tile() owns header width,
        // and writing it inside a layout pass posts a frame-change notification that fed
        // back into the P43.6 recursive layout storm.
        applyColumnLayout(reason: "layout", forceDiagnostic: false)

        bottomSeparator.frame = NSRect(x: 0, y: bottomH, width: b.width, height: 1)

        // Bottom bar
        bottomBar.frame = NSRect(x: 0, y: 0, width: b.width, height: bottomH)
        let btnSz: CGFloat = 18
        let buttonY = centeredY(height: btnSz, in: bottomH)
        renameButton.frame  = NSRect(x: 8, y: buttonY, width: btnSz, height: btnSz)
        deleteButton.frame  = NSRect(x: 34, y: buttonY, width: btnSz, height: btnSz)
        var nextX: CGFloat = 58
        if !xPrefixButton.isHidden {
            let xBtnW: CGFloat = 30
            let xBtnH: CGFloat = 20
            xPrefixButton.frame = NSRect(x: nextX,
                                         y: centeredY(height: xBtnH, in: bottomH),
                                         width: xBtnW,
                                         height: xBtnH)
            nextX += xBtnW + 4
        }
        if !customPrefixButton.isHidden {
            let pBtnW: CGFloat = 30
            let pBtnH: CGFloat = 20
            customPrefixButton.frame = NSRect(x: nextX,
                                              y: centeredY(height: pBtnH, in: bottomH),
                                              width: pBtnW,
                                              height: pBtnH)
            nextX += pBtnW + 4
        }
        let removeAllW: CGFloat = 72
        let removeAllH: CGFloat = 20
        removeAllButton.frame   = NSRect(x: nextX,
                                         y: centeredY(height: removeAllH, in: bottomH),
                                         width: removeAllW,
                                         height: removeAllH)
        removeAllButton.isEnabled = !items.isEmpty
        let labX = nextX + removeAllW + 8
        // Anchor the total-duration label to the same text right edge the Size
        // column uses when visible; otherwise use the table content right edge.
        let totalRightEdge = totalDurationRightEdgeInPanel()
        let totalHeight = ceil(totalDurationLabel.intrinsicContentSize.height)
        totalDurationLabel.frame = NSRect(x: labX,
                                          y: centeredY(height: totalHeight, in: bottomH),
                                          width: max(0, totalRightEdge - labX),
                                          height: totalHeight)

    }

    @objc private func scrollContentDidResize() {
        // Vertical scrolling and vertical-scroller toggles both mutate the clip view.
        // Schedule (do not run inline) so that the synchronous notification chain
        // produced by tile()/setFrame writes cannot recurse on the same call stack.
        scheduleColumnLayout(reason: "clip-geometry-change")
    }

    /// Coalesces column layout requests from frame/bounds notifications.
    /// Multiple notifications fired synchronously while layout is active are merged
    /// into a single deferred run on the next main-run-loop turn.
    private func scheduleColumnLayout(reason: String, force: Bool = false) {
        if let existing = pendingColumnLayout {
            pendingColumnLayout = (reason, existing.force || force)
            return
        }
        pendingColumnLayout = (reason, force)
        if isApplyingColumnLayout { return }  // defer block will drain it
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let req = self.pendingColumnLayout else { return }
            self.pendingColumnLayout = nil
            self.applyColumnLayout(reason: req.reason, forceDiagnostic: req.force)
        }
    }

    /// Single source of truth for queue column layout.
    ///
    /// Duration and Size are compact fixed-width columns (no user resize as of P43.4).
    /// File absorbs the remaining clip-view width. At narrow widths, optional columns
    /// shrink from rightmost-first toward their minimums before File is allowed to
    /// drop below `fileColumnMinimumWidth`. Widths are floored and the rounding
    /// remainder is absorbed by File so the visible columns sum exactly to the clip
    /// width — no horizontal overflow can occur.
    ///
    /// The native `NSTableHeaderView` and row cells both use the table's actual
    /// `NSTableColumn` rects, so header, row, and footer geometry share one
    /// coordinate system.
    private func applyColumnLayout(reason: String, forceDiagnostic: Bool) {
        // ── Reentrancy guard ───────────────────────────────────────────────
        // Any synchronous notification that fires while we are tiling (from
        // tile()/setFrame writes) calls scheduleColumnLayout, which sets
        // pendingColumnLayout and returns. But if applyColumnLayout is called
        // DIRECTLY (from layout(), update(), or toggleDuration/SizeColumn)
        // while already active, capture the request here and let the defer
        // block drain it on the next main-loop turn.
        if isApplyingColumnLayout {
            pendingColumnLayout = (reason, forceDiagnostic || pendingColumnLayout?.force == true)
            return
        }
        isApplyingColumnLayout = true
        defer {
            isApplyingColumnLayout = false
            if let pending = pendingColumnLayout {
                pendingColumnLayout = nil
                DispatchQueue.main.async { [weak self] in
                    self?.applyColumnLayout(reason: pending.reason,
                                            forceDiagnostic: pending.force)
                }
            }
        }

        guard let nameCol = tableView.tableColumn(withIdentifier: Self.colName),
              let durCol  = tableView.tableColumn(withIdentifier: Self.colDur),
              let sizeCol = tableView.tableColumn(withIdentifier: Self.colSize) else { return }

        // Check for clip x drift and log — do NOT scroll/reflect here.
        // LockedHorizontalClipView already enforces x = 0; mutation from inside
        // this method is what created the P43.6 recursive notification storm.
        lockHorizontalClipOrigin(reason: reason)

        let clipView = scrollView.contentView

        // The footer already uses `totalDurationTrailingInset` as the visual right
        // boundary for Queue Page metadata. Use the same boundary for the table columns
        // so File/Duration/Size and Total agree on the same right edge.
        //
        // This does not change the footer code. It moves the table's content boundary
        // left to match the footer-safe metadata boundary that is already visually correct.
        let rawAvailable = max(0, floor(clipView.bounds.width))
        let available = max(0, rawAvailable - Self.totalDurationTrailingInset)

        // Transient startup state: clip has not yet received real dimensions from
        // AppKit (this is normal — the view may enter the hierarchy before the first
        // real layout pass). Assigning zero-width columns would produce corrupt
        // geometry. Log the skip and schedule one coalesced retry so the layout
        // converges once the clip is meaningful. Natural frame/bounds notifications
        // (from layout(), scrollContentDidResize) will also trigger re-entry.
        // Guard the retry on reason to avoid an infinite spin if the clip stays zero.
        if rawAvailable <= 1 || available <= 1 {
            logQueueCoordinateState(reason: reason, outcome: "skipped-zero-clip", force: false)
            if reason != "zero-clip-retry" {
                scheduleColumnLayout(reason: "zero-clip-retry")
            }
            return
        }

        let durVisible  = !durCol.isHidden
        let sizeVisible = !sizeCol.isHidden

        var durWidth:  CGFloat = durVisible  ? Self.durationColumnDefaultWidth : 0
        var sizeWidth: CGFloat = sizeVisible ? Self.sizeColumnDefaultWidth     : 0

        let durMin:  CGFloat = durVisible  ? Self.durationColumnMinimumWidth : 0
        let sizeMin: CGFloat = sizeVisible ? Self.sizeColumnMinimumWidth     : 0

        var nameWidth = available - durWidth - sizeWidth
        if nameWidth < Self.fileColumnMinimumWidth {
            var deficit = Self.fileColumnMinimumWidth - nameWidth
            if sizeVisible {
                let shrink = min(deficit, sizeWidth - sizeMin)
                if shrink > 0 { sizeWidth -= shrink; deficit -= shrink }
            }
            if deficit > 0, durVisible {
                let shrink = min(deficit, durWidth - durMin)
                if shrink > 0 { durWidth -= shrink; deficit -= shrink }
            }
            nameWidth = available - durWidth - sizeWidth
        }

        nameWidth  = max(0, floor(nameWidth))
        durWidth   = max(0, floor(durWidth))
        sizeWidth  = max(0, floor(sizeWidth))

        var overflow = max(0, nameWidth + durWidth + sizeWidth - available)
        if overflow > 0, sizeVisible  { let s = min(overflow, sizeWidth); sizeWidth -= s; overflow -= s }
        if overflow > 0, durVisible   { let s = min(overflow, durWidth);  durWidth  -= s; overflow -= s }
        if overflow > 0               { let s = min(overflow, nameWidth); nameWidth -= s }

        // Absorb rounding remainder into File so visible columns sum exactly to
        // clip width — never wider, which is what would expose a horizontal range.
        let sum = nameWidth + durWidth + sizeWidth
        if sum < available { nameWidth += (available - sum) }

        // ── Idempotent writes ──────────────────────────────────────────────
        // Only write a column width when it has actually changed (≥ 0.5 pt).
        //
        // The table frame is corrected here too: origin.x must converge to 0 and
        // size.width must converge to the available clip width. P43.7 removed all
        // frame writes to break the recursive notification storm; P43.8 restores
        // only this minimal, guarded, idempotent correction.
        //
        // Constraints:
        //   * Only tableView.frame is touched (documentView is tableView; we do
        //     not write scrollView.documentView.frame separately).
        //   * tableView.headerView.frame is NEVER written here — tile() owns it.
        //   * No scroll(to:), scrollToPoint, or reflectScrolledClipView calls.
        //   * The whole block runs under `isApplyingColumnLayout`, so any
        //     synchronous frame-change notification fired by these writes is
        //     coalesced into pendingColumnLayout by scheduleColumnLayout and
        //     never re-enters the call stack.
        //   * tile() is only called when at least one width OR the table frame
        //     was actually changed — avoiding unnecessary notification traffic.
        let tol: CGFloat = 0.5
        var widthsChanged = false
        if abs(nameCol.width - nameWidth) > tol { nameCol.width = nameWidth; widthsChanged = true }
        if durVisible  && abs(durCol.width  - durWidth)  > tol { durCol.width  = durWidth;  widthsChanged = true }
        if sizeVisible && abs(sizeCol.width - sizeWidth) > tol { sizeCol.width = sizeWidth; widthsChanged = true }

        let currentFrame = tableView.frame
        let needsOriginFix = abs(currentFrame.origin.x) > tol
        let needsWidthFix  = abs(currentFrame.size.width - available) > tol
        var frameChanged = false
        if needsOriginFix || needsWidthFix {
            var target = currentFrame
            target.origin.x = 0
            target.size.width = available
            tableView.frame = target
            frameChanged = true
        }

        if widthsChanged || frameChanged { tableView.tile() }

        let outcome: String
        switch (widthsChanged, frameChanged) {
        case (true,  true):  outcome = "applied-widths-and-frame"
        case (true,  false): outcome = "applied-widths"
        case (false, true):  outcome = "applied-frame"
        case (false, false): outcome = "skipped"
        }
        logQueueCoordinateState(reason: reason, outcome: outcome, force: forceDiagnostic)
    }

    /// Checks for horizontal clip x drift and logs a warning if detected.
    /// Does NOT call scroll(to:) or reflectScrolledClipView — those calls drive
    /// NSClipView._immediateScrollToPoint, posting a bounds-change notification
    /// that is the root cause of the P43.6 recursive layout storm.
    /// LockedHorizontalClipView.constrainBoundsRect / setBoundsOrigin already
    /// enforce origin.x = 0; if drift appears here a bypass occurred externally.
    private func lockHorizontalClipOrigin(reason: String) {
        let x = scrollView.contentView.bounds.origin.x
        guard abs(x) > 0.5 else { return }
        let msg = "clipX drift reason=\(reason) x=\(String(format: "%.3f", x))"
        DebugConsoleController.log(level: .warning, category: "queue-geometry", message: msg)
        NSLog("dwb queueGeometryWarning %@", msg)
    }

    private func visibleColumnWidthSum() -> CGFloat {
        tableView.tableColumns.reduce(CGFloat(0)) { partial, column in
            column.isHidden ? partial : partial + column.width
        }
    }

    private func columnRectDescription(_ identifier: NSUserInterfaceItemIdentifier) -> String {
        guard let column = tableView.tableColumn(withIdentifier: identifier) else { return "missing" }
        guard !column.isHidden else { return "hidden" }
        let index = tableView.column(withIdentifier: identifier)
        guard index >= 0 else { return "missing-index" }
        return NSStringFromRect(tableView.rect(ofColumn: index))
    }

    private func logQueueCoordinateState(reason: String, outcome: String, force: Bool) {
        if !force {
            let now = Date()
            if let last = lastCoordinateDiagnosticTimeByReason[reason],
               now.timeIntervalSince(last) < 0.75 {
                return
            }
            lastCoordinateDiagnosticTimeByReason[reason] = now
        }

        let clip       = scrollView.contentView
        let clipInPanel = clip.convert(clip.bounds, to: self)
        let visibleClipRight = clipInPanel.maxX
        let docWidth   = scrollView.documentView?.frame.width ?? 0
        let tableFrame = tableView.frame
        let visibleSum = visibleColumnWidthSum()
        let durHidden  = tableView.tableColumn(withIdentifier: Self.colDur)?.isHidden  ?? true
        let sizeHidden = tableView.tableColumn(withIdentifier: Self.colSize)?.isHidden ?? true
        let footerRight = totalDurationRightEdgeInPanel()
        // Diagnostic-only: `guarded` is always 1 here (we only log from inside
        // applyColumnLayout); kept as an explicit field so future readers can
        // grep for it next to outcome.
        let guarded = isApplyingColumnLayout ? 1 : 0
        let message = String(format:
            "reason=%@ outcome=%@ guarded=%d clipX=%.3f clipW=%.3f docW=%.3f" +
            " tableX=%.3f tableW=%.3f visibleColumnSum=%.3f" +
            " fileRect=%@ durationRect=%@ sizeRect=%@" +
            " durationHidden=%@ sizeHidden=%@" +
            " footerRight=%.3f visibleClipRight=%.3f",
            reason, outcome, guarded,
            clip.bounds.origin.x, clip.bounds.width, docWidth,
            tableFrame.origin.x, tableFrame.size.width, visibleSum,
            columnRectDescription(Self.colName),
            columnRectDescription(Self.colDur),
            columnRectDescription(Self.colSize),
            String(durHidden), String(sizeHidden),
            footerRight, visibleClipRight)
        DebugConsoleController.log("queue-geometry", message)
        NSLog("dwb queueGeometry %@", message)

        #if DEBUG
        // Gate geometry invariant checks on clipReady. When the clip has not yet
        // received real AppKit dimensions (e.g. during initial view setup), the
        // values are meaningless and must not trigger diagnostic stops.
        // Warnings remain useful once the clip is ready; they are warning-only —
        // assertionFailure has been removed to allow DEBUG launches to proceed
        // normally through transient startup geometry states.
        let clipReady = window != nil
            && bounds.width > 1
            && bounds.height > 1
            && clip.bounds.width > 1
        if clipReady {
            let tolerance: CGFloat = 0.5
            var warnings: [String] = []
            if abs(clip.bounds.origin.x) > tolerance {
                warnings.append(String(format: "clip.bounds.origin.x %.3f exceeds tolerance",
                                       clip.bounds.origin.x))
            }
            if docWidth > clip.bounds.width + tolerance {
                warnings.append(String(format: "documentView.frame.width %.3f exceeds clip %.3f",
                                       docWidth, clip.bounds.width))
            }
            if tableFrame.size.width > clip.bounds.width + tolerance {
                warnings.append(String(format: "tableView.frame.width %.3f exceeds clip %.3f",
                                       tableFrame.size.width, clip.bounds.width))
            }
            if visibleSum > clip.bounds.width + tolerance {
                warnings.append(String(format: "visible column sum %.3f exceeds clip %.3f",
                                       visibleSum, clip.bounds.width))
            }
            if footerRight > visibleClipRight + tolerance {
                warnings.append(String(format: "footer right edge %.3f exceeds visible clip right %.3f",
                                       footerRight, visibleClipRight))
            }
            if !warnings.isEmpty {
                let warningText = "reason=\(reason) outcome=\(outcome) " + warnings.joined(separator: "; ")
                DebugConsoleController.log(level: .warning, category: "queue-geometry",
                                           message: warningText)
                NSLog("dwb queueGeometryWarning %@", warningText)
                // Warning-only: no assertionFailure until layout has stabilized
                // across startup, queue reload, resize, and column-toggle sequences.
            }
        }
        #endif
    }

    private func centeredY(height: CGFloat, in containerHeight: CGFloat) -> CGFloat {
        floor((containerHeight - height) / 2)
    }

    /// Right edge for the bottom-bar total-duration label, in QueuePageView
    /// coordinates.
    ///
    /// Geometry is derived from the real `NSTableView.rect(ofColumn:)` converted
    /// into this view's coordinate space — no manual panel-coordinate construction
    /// from `scrollView.frame.minX - clipView.bounds.origin.x`. Preference order is
    /// Size → Duration → File so the footer aligns with the rightmost visible
    /// column's text right edge.
    ///
    /// The result is clamped to a footer-safe right limit: visibleClipRight minus
    /// `totalDurationTrailingInset` (72 pt). This intentionally moves the label
    /// left so it sits under the metadata columns rather than hugging the panel
    /// edge. The inset is a footer-only boundary — it does not affect column,
    /// header, or row geometry. The label is additionally bounded by the column
    /// text rect, so it never exceeds the Size column's right text edge.
    private func totalDurationRightEdgeInPanel() -> CGFloat {
        let clipView = scrollView.contentView
        let clipInPanel = clipView.convert(clipView.bounds, to: self)
        let visibleClipRight = clipInPanel.maxX
        // Footer-safe right boundary: keeps the total label visually inside the
        // metadata area rather than at the raw panel edge.
        let footerRightLimit = max(0, visibleClipRight - Self.totalDurationTrailingInset)

        let preferred: [NSUserInterfaceItemIdentifier] = [Self.colSize, Self.colDur, Self.colName]
        for identifier in preferred {
            guard let column = tableView.tableColumn(withIdentifier: identifier),
                  !column.isHidden else { continue }
            let columnIndex = tableView.column(withIdentifier: identifier)
            guard columnIndex >= 0 else { continue }
            let columnRectInTable = tableView.rect(ofColumn: columnIndex)
            guard columnRectInTable.width > 0 else { continue }
            let columnRectInPanel = tableView.convert(columnRectInTable, to: self)
            let textRect = QueueColumnGeometry.textRect(in: columnRectInPanel,
                                                        textHeight: columnRectInPanel.height)
            return min(textRect.maxX, footerRightLimit)
        }
        return footerRightLimit
    }

    private func selectedRowsOrCurrentRowDescending() -> [Int] {
        let selected = tableView.selectedRowIndexes
        if !selected.isEmpty { return selected.sorted(by: >) }
        return currentDisplayIndex >= 0 ? [currentDisplayIndex] : []
    }

    // MARK: - Actions

    @objc private func closeTapped()  { delegate?.queuePageDidRequestClose(self) }

    @objc private func rowClicked() {
        // Single-click selection is handled by NSTableView so Command-click,
        // Shift-click, and keyboard selection extension keep normal AppKit behavior.
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        delegate?.queuePage(self, didSelectDisplayIndex: row)
    }

    @objc private func renameTapped() {
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : currentDisplayIndex
        guard row >= 0 else { return }
        delegate?.queuePage(self, didRequestRenameAt: row)
    }

    @objc private func deleteTapped() {
        let rows = selectedRowsOrCurrentRowDescending()
        guard !rows.isEmpty else { return }
        if rows.count == 1 {
            delegate?.queuePage(self, didRequestDeleteAt: rows[0])
        } else {
            delegate?.queuePage(self, didRequestDeleteRows: rows)
        }
    }

    @objc private func xPrefixTapped() {
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : currentDisplayIndex
        guard row >= 0 else { return }
        delegate?.queuePage(self, didRequestXPrefixRenameAt: row)
    }

    @objc private func customPrefixTapped() {
        let selected = tableView.selectedRowIndexes
        if selected.isEmpty {
            let row = currentDisplayIndex
            guard row >= 0 else { return }
            delegate?.queuePage(self, didRequestCustomPrefixRenameAt: [row])
        } else {
            delegate?.queuePage(self, didRequestCustomPrefixRenameAt: selected.sorted())
        }
    }

    @objc private func removeAllTapped() {
        delegate?.queuePageDidRequestRemoveAll(self)
    }

    @objc private func sortModeChanged() {
        guard !isUpdatingSortControl,
              let mode = QueueSortMode(rawValue: sortPopUpButton.selectedTag()) else { return }
        delegate?.queuePage(self, didChangeSortMode: mode)
    }

    private func updateSortControlSelection() {
        isUpdatingSortControl = true
        sortPopUpButton.selectItem(withTag: currentSortMode.rawValue)
        isUpdatingSortControl = false
    }

    // MARK: - Column visibility menu

    private func makeColumnVisibilityMenu() -> NSMenu {
        let menu = NSMenu()
        menu.title = "Columns"

        let durCol  = tableView.tableColumn(withIdentifier: Self.colDur)
        let sizeCol = tableView.tableColumn(withIdentifier: Self.colSize)

        let durItem = NSMenuItem(title: "Duration",
                                 action: #selector(toggleDurationColumn),
                                 keyEquivalent: "")
        durItem.target = self
        durItem.state = (durCol?.isHidden == false) ? .on : .off
        menu.addItem(durItem)

        let sizeItem = NSMenuItem(title: "Size",
                                  action: #selector(toggleSizeColumn),
                                  keyEquivalent: "")
        sizeItem.target = self
        sizeItem.state = (sizeCol?.isHidden == false) ? .on : .off
        menu.addItem(sizeItem)

        return menu
    }

    @objc private func toggleDurationColumn() {
        guard let col = tableView.tableColumn(withIdentifier: Self.colDur) else { return }
        let nowVisible = !col.isHidden
        col.isHidden = nowVisible
        if !col.isHidden { col.width = Self.durationColumnDefaultWidth }
        UserDefaults.standard.set(!nowVisible, forKey: Self.durationColumnVisibleKey)
        applyColumnLayout(reason: "toggle-duration", forceDiagnostic: true)
        needsLayout = true
    }

    @objc private func toggleSizeColumn() {
        guard let col = tableView.tableColumn(withIdentifier: Self.colSize) else { return }
        let nowVisible = !col.isHidden
        col.isHidden = nowVisible
        if !col.isHidden { col.width = Self.sizeColumnDefaultWidth }
        UserDefaults.standard.set(!nowVisible, forKey: Self.sizeColumnVisibleKey)
        applyColumnLayout(reason: "toggle-size", forceDiagnostic: true)
        needsLayout = true
    }

    private func makeContextMenu(for row: Int) -> NSMenu {
        let menu = NSMenu()
        addContextItem("Play", action: #selector(contextPlay(_:)), row: row, to: menu)
        menu.addItem(.separator())
        addContextItem("Reveal in Finder", action: #selector(contextReveal(_:)), row: row, to: menu)
        addContextItem("Rename...", action: #selector(contextRename(_:)), row: row, to: menu)
        menu.addItem(.separator())
        addContextItem("Remove from Queue", action: #selector(contextDelete(_:)), row: row, to: menu)
        return menu
    }

    private func addContextItem(_ title: String, action: Selector, row: Int, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = row
        menu.addItem(item)
    }

    @objc private func contextPlay(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int else { return }
        delegate?.queuePage(self, didSelectDisplayIndex: row)
    }

    @objc private func contextReveal(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int else { return }
        delegate?.queuePage(self, didRequestRevealAt: row)
    }

    @objc private func contextRename(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int else { return }
        delegate?.queuePage(self, didRequestRenameAt: row)
    }

    @objc private func contextDelete(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int else { return }
        delegate?.queuePage(self, didRequestDeleteAt: row)
    }
}

final class QueuePageTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?
    /// Called when Delete or Backspace is pressed with one or more selected rows.
    /// Indices are sorted descending so the caller can remove them safely.
    var deleteRowsHandler: (([Int]) -> Void)?

    // Select on mouseDown so the highlight appears immediately, before drag detection
    // and before the action fires on mouseUp. Without this, selectionHighlightStyle = .none
    // means the system never automatically selects, and the visual update can lag or miss.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .shift, .option]).isEmpty {
            let point = convert(event.locationInWindow, from: nil)
            let r = row(at: point)
            if r >= 0 { selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false) }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenuProvider?(row)
    }

    override func keyDown(with event: NSEvent) {
        // keyCode 51 = Delete (backspace), keyCode 117 = Forward Delete
        if event.keyCode == 51 || event.keyCode == 117 {
            let rows = selectedRowIndexes
            guard !rows.isEmpty else { return }
            let minRow = rows.min() ?? 0
            deleteRowsHandler?(rows.sorted(by: >))
            // Re-select the nearest row after the table reloads.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let count = self.numberOfRows
                guard count > 0 else { return }
                let newRow = min(minRow, count - 1)
                self.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
                self.scrollRowToVisible(newRow)
            }
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - NSTableViewDataSource

extension QueuePageView: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    // MARK: Drag source — write dragged row index to pasteboard

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard allowsManualReorder else { return nil }
        // This view preserves the pre-existing single-row reorder model. Multi-row
        // selection is supported, but multi-row drag reorder is intentionally not.
        guard tableView.selectedRowIndexes.count <= 1 else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.draggedRowType)
        return item
    }

    // MARK: Drop target — accept only same-table moves, inserting between rows

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard allowsManualReorder else { return [] }
        // Only accept drops that insert between rows (not on top of a row)
        guard dropOperation == .above else {
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }
        return .move
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard allowsManualReorder else { return false }
        guard let str = info.draggingPasteboard.string(forType: Self.draggedRowType),
              let from = Int(str) else { return false }
        let to = row
        // No-op: drop on same position or the position immediately below the source
        guard from != to, from != to - 1 else { return false }
        delegate?.queuePage(self, didReorderFromIndex: from, toIndex: to)
        return true
    }
}

// MARK: - NSTableViewDelegate

extension QueuePageView: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < items.count, let colID = tableColumn?.identifier else { return nil }
        let item = items[row]
        let isCurrent = row == currentDisplayIndex

        let reuseID = NSUserInterfaceItemIdentifier("qpCell-\(colID.rawValue)")
        var cell = tableView.makeView(withIdentifier: reuseID, owner: nil) as? QueuePageCell
        if cell == nil {
            cell = QueuePageCell(reuseID: reuseID)
        }

        let text: String
        let alignment: NSTextAlignment
        switch colID {
        case Self.colName:
            text = item.displayName
            alignment = .left
        case Self.colDur:
            text = item.duration
            alignment = .center
        case Self.colSize:
            text = item.fileSize
            alignment = .right
        default:
            text = ""
            alignment = .left
        }

        cell?.configure(text: text, alignment: alignment, isCurrent: isCurrent)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 26 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = QueuePageRowView()
        rv.isCurrent = row == currentDisplayIndex
        return rv
    }
}

// MARK: - QueuePageCell

fileprivate struct QueueColumnGeometry {
    let identifier: NSUserInterfaceItemIdentifier
    let title: String
    let alignment: NSTextAlignment
    let columnRect: NSRect
    let textRect: NSRect

    static func textRect(in rect: NSRect, textHeight: CGFloat) -> NSRect {
        NSRect(x: rect.minX + QueuePageView.cellLeadingPadding,
               y: rect.minY + floor((rect.height - textHeight) / 2),
               width: max(0, rect.width - QueuePageView.cellLeadingPadding - QueuePageView.cellTrailingPadding),
               height: textHeight)
    }
}

private final class QueuePageCell: NSView {

    private let label = NSTextField(labelWithString: "")

    init(reuseID: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = reuseID
        label.drawsBackground = false
        label.isEditable      = false
        label.isBordered      = false
        label.lineBreakMode   = .byTruncatingMiddle
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.frame = QueueColumnGeometry.textRect(in: bounds, textHeight: 13)
    }

    func configure(text: String, alignment: NSTextAlignment, isCurrent: Bool) {
        label.stringValue = text
        label.alignment   = alignment
        if isCurrent {
            label.font      = .systemFont(ofSize: 11.5, weight: .medium)
            label.textColor = QueuePageView.Palette.currentText
        } else {
            label.font      = .systemFont(ofSize: 11.5, weight: .regular)
            label.textColor = QueuePageView.Palette.primaryText
        }
    }
}

// MARK: - QueuePageRowView

private final class QueuePageRowView: NSTableRowView {

    var isCurrent: Bool = false

    // Ensure the row redraws whenever isSelected changes. With selectionHighlightStyle = .none,
    // AppKit may not reliably call setNeedsDisplay on the row view after a programmatic
    // selectRowIndexes call, so we force it here.
    override var isSelected: Bool {
        get { super.isSelected }
        set { if super.isSelected != newValue { super.isSelected = newValue; needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isSelected {
            QueuePageView.Palette.selectedFill.setFill()
            bounds.fill()
        } else if isCurrent {
            QueuePageView.Palette.currentFill.setFill()
            bounds.fill()
        }

        if isCurrent {
            QueuePageView.Palette.currentBar.setFill()
            NSRect(x: 0, y: 3, width: 3, height: max(0, bounds.height - 6)).fill()
        }
    }

    // Use drawBackground for selection so we don't get the system blue.
    override var isEmphasized: Bool { get { false } set {} }
}

// MARK: - Native Queue Table Header

private final class LockedHorizontalClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        rect.origin.x = 0
        return rect
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(NSPoint(x: 0, y: newOrigin.y))
    }
}

private final class QueueTableHeaderView: NSTableHeaderView {
    var menuProvider: (() -> NSMenu?)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = QueuePageView.Palette.columnHeader.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        QueuePageView.Palette.columnHeader.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}

private final class QueueColumnHeaderCell: NSTableHeaderCell {
    private let textAlignment: NSTextAlignment

    init(title: String, alignment: NSTextAlignment) {
        self.textAlignment = alignment
        super.init(textCell: title)
        self.stringValue = title
        self.alignment = alignment
    }

    required init(coder: NSCoder) { fatalError() }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.alignment = textAlignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: QueuePageView.Palette.tertiaryText,
            .paragraphStyle: paragraph
        ]
        let labelRect = QueueColumnGeometry.textRect(in: cellFrame, textHeight: 11)
        stringValue.draw(in: labelRect, withAttributes: attrs)

        QueuePageView.Palette.separator.setFill()
        NSRect(x: floor(cellFrame.maxX), y: cellFrame.minY + 3, width: 1, height: max(0, cellFrame.height - 6)).fill()
    }

    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        draw(withFrame: cellFrame, in: controlView)
    }
}
