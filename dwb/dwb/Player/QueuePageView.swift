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
    /// Called when the user triggers the one-click custom prefix rename action (feature-gated).
    /// `indices` is always ascending. Caller must preflight all targets before renaming any.
    func queuePage(_ view: QueuePageView, didRequestCustomPrefixRenameAt indices: [Int])
    /// Called when the user triggers the secondary custom prefix rename action (feature-gated).
    /// `indices` is always ascending. Caller must preflight all targets before renaming any.
    func queuePage(_ view: QueuePageView, didRequestSecondaryCustomPrefixRenameAt indices: [Int])
    /// Called when the user presses Delete/Backspace with multiple rows selected.
    /// `indices` is sorted descending so the caller can delete safely without index shifts.
    func queuePage(_ view: QueuePageView, didRequestDeleteRows indices: [Int])
    /// Called from the queue empty state to use the app's existing media-open flow.
    func queuePageDidRequestAddMedia(_ view: QueuePageView)
    /// Called when the user triggers the folder rescan action from the queue footer.
    func queuePageDidRequestRescan(_ view: QueuePageView)
}

/// Full in-window Queue Page panel.
/// Designed to occupy ~35–45 % of the window width as a right-side panel.
/// Shows the playback set in current traversal order with filename, duration,
/// and file size. Supports single-click selection, double-click playback, and
/// queue file actions.
final class QueuePageView: NSView, NSSearchFieldDelegate {

    fileprivate enum Palette {
        static let panel = NSColor(calibratedWhite: 0.105, alpha: 1.0)
        static let header = NSColor(calibratedWhite: 0.085, alpha: 1.0)
        static let columnHeader = NSColor(calibratedWhite: 0.125, alpha: 1.0)
        static let footer = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        static let separator = NSColor.white.withAlphaComponent(0.075)
        static let primaryText = NSColor.white.withAlphaComponent(0.84)
        static let secondaryText = NSColor.white.withAlphaComponent(0.58)
        static let tertiaryText = NSColor.white.withAlphaComponent(0.42)
        /// Suite accent #4C62A8 — matches dwb skim's DwbSkimProductSpec.accent.
        static let accent = NSColor(calibratedRed: 76.0 / 255.0,
                                    green: 98.0 / 255.0,
                                    blue: 168.0 / 255.0,
                                    alpha: 1.0)
        static let currentText = NSColor.white
        static let currentFill = accent.withAlphaComponent(0.18)
        static let currentBar = accent
        static let selectedFill = NSColor.white.withAlphaComponent(0.10)
    }

    // MARK: - Item model

    struct Item {
        let url:         URL
        var displayName: String
        var duration:    String   // "1:23:45" or "--:--"
        var fileSize:    String   // "12.3 MB" or "--"
        var isBookmarked: Bool = false
    }

    private enum VisibleRow {
        case section(String)
        case item(displayIndex: Int, item: Item)

        var displayIndex: Int? {
            if case let .item(displayIndex, _) = self { return displayIndex }
            return nil
        }

        var item: Item? {
            if case let .item(_, item) = self { return item }
            return nil
        }
    }

    // MARK: - Public state

    weak var delegate: QueuePageViewDelegate?

    /// Call update(items:currentIndex:) to refresh data and reload the table.
    private(set) var items: [Item] = []
    private var visibleItems: [Item] = []
    private var visibleToDisplayIndices: [Int] = []
    private var visibleRows: [VisibleRow] = []
    private(set) var currentDisplayIndex: Int = -1
    private var currentSortMode: QueueSortMode = .manual
    private var allowsManualReorder = true
    private var isUpdatingSortControl = false
    /// True while the user has scrolled upward into the PREVIOUS history area.
    /// Suppresses auto-follow until they scroll back down past NOW PLAYING.
    private var userIsReviewingHistory = false
    private var totalDurationText = MediaFileSupport.formatClockDuration(0)
    private var bookmarkFilterEnabled = false

    /// When true, the one-click custom prefix rename button(s) are shown in the bottom bar.
    var isCustomPrefixRenameEnabled: Bool = false {
        didSet {
            updateCustomPrefixButtonVisibility()
            needsLayout = true
        }
    }

    func update(items: [Item], currentIndex: Int, sortMode: QueueSortMode, totalDurationText: String) {
        let selectedURLs = Set(tableView.selectedRowIndexes.compactMap { row -> URL? in
            guard let item = visibleItem(at: row) else { return nil }
            return item.url
        })
        let scroll = currentIndex != currentDisplayIndex && currentIndex >= 0 && !userIsReviewingHistory
        self.items = items
        self.currentDisplayIndex = currentIndex
        self.totalDurationText = totalDurationText
        currentSortMode = sortMode
        allowsManualReorder = sortMode == .manual && currentSearchQuery.isEmpty
        updateSortControlSelection()
        updateHeaderSortIndicators()
        applySearchFilter(preservingSelectedURLs: selectedURLs)
        if scroll {
            scrollNowPlayingToTop()
        }
        applyColumnLayout(reason: "queue-reload", forceDiagnostic: false)
    }

    /// Scrolls so the NOW PLAYING section header is at the top of the visible area.
    private func scrollNowPlayingToTop() {
        guard currentDisplayIndex >= 0,
              let itemRow = visibleRow(forDisplayIndex: currentDisplayIndex) else { return }
        let targetRow = max(0, itemRow - 1)
        let rowRect = tableView.rect(ofRow: targetRow)
        let targetY = max(0, rowRect.minY)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        userIsReviewingHistory = false
    }

    // MARK: - Subviews

    private let headerView       = NSView()
    private let titleLabel       = NSTextField(labelWithString: "Queue")
    private let searchSortPill   = QueueSearchSortPillView()
    private let searchSortDivider = QueuePassthroughView()
    private let searchIconView   = QueueCenteredSymbolView()
    private let sortPopUpButton  = NSPopUpButton()
    private let sortTitleView    = QueueCenteredTextView()
    private let sortChevronView  = QueueCenteredSymbolView()
    private let searchField      = NSSearchField()
    private let bookmarkFilterButton = QueueHeaderSymbolButton(frame: .zero)
    private let closeButton      = QueueHeaderSymbolButton(frame: .zero)
    private let topSeparator     = NSView()
    let scrollView               = NSScrollView()
    let tableView                = QueuePageTableView()
    private let emptyStateView   = NSView()
    private let emptyStateLogoView = NSImageView()
    private let emptyIconLabel   = NSTextField(labelWithString: "+")
    private let emptyStateLabel  = NSTextField(labelWithString: "No media in queue")
    private let emptyStateDetailLabel = NSTextField(labelWithString: "Add files or folders to build the queue.")
    private let addMediaButton   = NSButton()
    private let bottomSeparator  = NSView()
    private let bottomBar        = NSView()
    private let deleteButton              = NSButton()
    private let prefixPill                = NSView()
    private let prefixPillDivider         = NSView()
    private let customPrefixButton        = NSButton()
    private let customPrefixSecondaryButton = NSButton()
    private let footerPrefixSeparator     = NSView()
    private let rescanButton              = NSButton()
    private let footerClearSeparator      = NSView()
    private let removeAllButton           = NSButton()
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
    private static let metadataColumnDefaultWidth: CGFloat = 68
    private static let metadataColumnMinimumWidth: CGFloat = 56

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

        searchSortPill.wantsLayer = true
        searchSortPill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        searchSortPill.layer?.cornerRadius = 12
        headerView.addSubview(searchSortPill)

        searchSortDivider.wantsLayer = true
        searchSortDivider.layer?.backgroundColor = Palette.separator.cgColor
        searchSortPill.addSubview(searchSortDivider)

        searchIconView.configure(symbolName: "magnifyingglass",
                                 pointSize: 13,
                                 weight: .regular,
                                 color: Palette.secondaryText,
                                 accessibilityDescription: nil)
        searchSortPill.addSubview(searchIconView)

        sortTitleView.font = .systemFont(ofSize: 10.5, weight: .regular)
        sortTitleView.textColor = Palette.primaryText
        searchSortPill.addSubview(sortTitleView)

        sortChevronView.configure(symbolName: "chevron.up.chevron.down",
                                  pointSize: 13,
                                  weight: .medium,
                                  color: Palette.secondaryText,
                                  accessibilityDescription: nil)
        searchSortPill.addSubview(sortChevronView)

        sortPopUpButton.cell = QueueTransparentPopUpButtonCell(textCell: "", pullsDown: false)
        sortPopUpButton.font = .systemFont(ofSize: 10.5, weight: .regular)
        sortPopUpButton.bezelStyle = .rounded
        sortPopUpButton.isBordered = false
        sortPopUpButton.target = self
        sortPopUpButton.action = #selector(sortModeChanged)
        sortPopUpButton.toolTip = "Queue sort order"
        sortPopUpButton.setAccessibilityLabel("Queue sort order")
        QueueSortMode.allCases.forEach { mode in
            let title = mode == .manual ? "Sort: Manual" : "Sort: \(mode.title)"
            sortPopUpButton.addItem(withTitle: title)
            sortPopUpButton.lastItem?.tag = mode.rawValue
        }
        updateSortControlSelection()
        searchSortPill.addSubview(sortPopUpButton)

        searchField.cell = QueueSearchFieldCell(textCell: "")
        searchField.isEditable = true
        searchField.placeholderString = "Search queue"
        searchField.font = .systemFont(ofSize: 11)
        searchField.textColor = Palette.primaryText
        searchField.backgroundColor = NSColor.white.withAlphaComponent(0.10)
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.toolTip = "Search queue filenames"
        searchField.setAccessibilityLabel("Search queue")
        searchSortPill.searchField = searchField
        searchSortPill.addSubview(searchField)

        bookmarkFilterButton.isBordered = false
        bookmarkFilterButton.bezelStyle = .regularSquare
        bookmarkFilterButton.symbolPointSize = 13
        bookmarkFilterButton.symbolWeight = .medium
        bookmarkFilterButton.target = self
        bookmarkFilterButton.action = #selector(bookmarkFilterTapped)
        bookmarkFilterButton.setButtonType(.toggle)
        bookmarkFilterButton.toolTip = "Show bookmarked queue files"
        bookmarkFilterButton.setAccessibilityLabel("Bookmark filter")
        headerView.addSubview(bookmarkFilterButton)
        updateBookmarkFilterButton()

        closeButton.isBordered     = false
        closeButton.bezelStyle     = .regularSquare
        closeButton.symbolName     = "xmark"
        closeButton.symbolPointSize = 10
        closeButton.symbolWeight   = .medium
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
        durCol.headerCell = QueueColumnHeaderCell(title: "Duration", alignment: .right)

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
        updateHeaderSortIndicators()
        // applyColumnLayout() is the single source of truth; AppKit must not mutate widths.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.headerView   = nil
        tableView.rowHeight    = 70
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.gridColor = Palette.separator
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

        // The sidebar presentation renders file metadata inside each media card,
        // so the legacy Duration/Size columns remain hidden while their data
        // still feeds the row subtitle.
        durCol.isHidden = true
        sizeCol.isHidden = true

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

        emptyStateView.wantsLayer = true
        emptyStateView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(emptyStateView)

        // Faded decorative app icon — behind all other empty-state content.
        emptyStateLogoView.image = NSApplication.shared.applicationIconImage
        emptyStateLogoView.imageScaling = .scaleProportionallyUpOrDown
        emptyStateLogoView.alphaValue = 0.07
        emptyStateLogoView.isEditable = false
        emptyStateLogoView.setAccessibilityElement(false)
        emptyStateLogoView.focusRingType = .none
        emptyStateView.addSubview(emptyStateLogoView)

        emptyIconLabel.font = .systemFont(ofSize: 34, weight: .light)
        emptyIconLabel.textColor = Palette.accent.withAlphaComponent(0.95)
        emptyIconLabel.alignment = .center
        emptyIconLabel.drawsBackground = false
        emptyIconLabel.isEditable = false
        emptyIconLabel.isBordered = false
        emptyIconLabel.isSelectable = false
        emptyStateView.addSubview(emptyIconLabel)

        emptyStateLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        emptyStateLabel.textColor = Palette.primaryText
        emptyStateLabel.alignment = .center
        emptyStateLabel.drawsBackground = false
        emptyStateLabel.isEditable = false
        emptyStateLabel.isBordered = false
        emptyStateLabel.isSelectable = false
        emptyStateView.addSubview(emptyStateLabel)

        emptyStateDetailLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        emptyStateDetailLabel.textColor = Palette.secondaryText
        emptyStateDetailLabel.alignment = .center
        emptyStateDetailLabel.drawsBackground = false
        emptyStateDetailLabel.isEditable = false
        emptyStateDetailLabel.isBordered = false
        emptyStateDetailLabel.isSelectable = false
        emptyStateDetailLabel.lineBreakMode = .byWordWrapping
        emptyStateView.addSubview(emptyStateDetailLabel)

        addMediaButton.bezelStyle = .rounded
        addMediaButton.font = .systemFont(ofSize: 12, weight: .semibold)
        addMediaButton.title = "Add Media"
        addMediaButton.toolTip = "Add media to the queue"
        addMediaButton.setAccessibilityLabel("Add Media")
        addMediaButton.target = self
        addMediaButton.action = #selector(addMediaTapped)
        emptyStateView.addSubview(addMediaButton)

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
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(scrollDidEndLive),
                                               name: NSScrollView.didEndLiveScrollNotification,
                                               object: scrollView)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleCustomPrefixValueChanged),
                                               name: .customPrefixValueChanged,
                                               object: nil)

        // ── Bottom bar ────────────────────────────────────────────────────
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = Palette.footer.cgColor
        addSubview(bottomBar)

        deleteButton.isBordered     = false
        deleteButton.bezelStyle     = .regularSquare
        deleteButton.imageScaling   = .scaleProportionallyDown
        let trashCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if let img = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove") {
            deleteButton.image = img.withSymbolConfiguration(trashCfg) ?? img
        }
        deleteButton.contentTintColor = NSColor.systemRed.withAlphaComponent(0.70)
        deleteButton.toolTip   = "Remove selected file(s) from queue"
        deleteButton.setAccessibilityLabel("Remove selected file(s) from queue")
        deleteButton.target    = self
        deleteButton.action    = #selector(deleteTapped)
        bottomBar.addSubview(deleteButton)

        prefixPill.wantsLayer = true
        prefixPill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        prefixPill.layer?.cornerRadius = 12
        prefixPill.isHidden = true
        bottomBar.addSubview(prefixPill)

        prefixPillDivider.wantsLayer = true
        prefixPillDivider.layer?.backgroundColor = Palette.separator.cgColor
        prefixPill.addSubview(prefixPillDivider)

        // Primary custom-prefix button — matches the playback bar's prefix control.
        customPrefixButton.isBordered     = false
        customPrefixButton.bezelStyle     = .regularSquare
        customPrefixButton.image          = nil
        customPrefixButton.font           = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        customPrefixButton.contentTintColor = PrefixBrandColors.primaryCustomPrefixColor
        customPrefixButton.toolTip          = "Apply primary prefix to selected filename(s) (one-click, no dialog). Shortcut: Q"
        customPrefixButton.setAccessibilityLabel("Apply primary custom prefix to selected file")
        customPrefixButton.target           = self
        customPrefixButton.action           = #selector(customPrefixTapped)
        customPrefixButton.isHidden         = true
        prefixPill.addSubview(customPrefixButton)

        // Secondary custom-prefix button.
        customPrefixSecondaryButton.isBordered     = false
        customPrefixSecondaryButton.bezelStyle     = .regularSquare
        customPrefixSecondaryButton.image          = nil
        customPrefixSecondaryButton.font           = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        customPrefixSecondaryButton.contentTintColor = PrefixBrandColors.secondaryCustomPrefixColor
        customPrefixSecondaryButton.toolTip          = "Apply secondary prefix to selected filename(s) (one-click, no dialog). Shortcut: Option-Q"
        customPrefixSecondaryButton.setAccessibilityLabel("Apply secondary custom prefix to selected file")
        customPrefixSecondaryButton.target           = self
        customPrefixSecondaryButton.action           = #selector(customPrefixSecondaryTapped)
        customPrefixSecondaryButton.isHidden         = true
        prefixPill.addSubview(customPrefixSecondaryButton)

        footerPrefixSeparator.wantsLayer = true
        footerPrefixSeparator.layer?.backgroundColor = Palette.separator.cgColor
        bottomBar.addSubview(footerPrefixSeparator)

        rescanButton.isBordered     = false
        rescanButton.bezelStyle     = .regularSquare
        rescanButton.font           = .systemFont(ofSize: 11.5, weight: .regular)
        rescanButton.title          = "Rescan"
        rescanButton.contentTintColor = Palette.secondaryText
        rescanButton.toolTip        = "Rescan Folder — refresh the queue from current folder contents on disk"
        rescanButton.setAccessibilityLabel("Rescan Folder")
        rescanButton.target         = self
        rescanButton.action         = #selector(rescanTapped)
        bottomBar.addSubview(rescanButton)

        footerClearSeparator.wantsLayer = true
        footerClearSeparator.layer?.backgroundColor = Palette.separator.cgColor
        bottomBar.addSubview(footerClearSeparator)

        removeAllButton.isBordered   = false
        removeAllButton.bezelStyle   = .regularSquare
        removeAllButton.font         = .systemFont(ofSize: 11.5, weight: .regular)
        removeAllButton.title        = "Clear Queue"
        removeAllButton.contentTintColor = NSColor.systemRed.withAlphaComponent(0.78)
        removeAllButton.toolTip      = "Clear Queue"
        removeAllButton.setAccessibilityLabel("Clear Queue")
        removeAllButton.target       = self
        removeAllButton.action       = #selector(removeAllTapped)
        bottomBar.addSubview(removeAllButton)

        // Wire up keyboard-delete handler so Delete/Backspace on a selected row
        // removes that item.  Re-selecting the appropriate row is handled after
        // the table reloads (see QueuePageTableView.keyDown).
        tableView.deleteRowsHandler = { [weak self] indices in
            guard let self = self else { return }
            let displayIndices = indices.compactMap { self.displayIndex(forVisibleRow: $0) }.sorted(by: >)
            guard !displayIndices.isEmpty else { return }
            if displayIndices.count == 1 {
                self.delegate?.queuePage(self, didRequestDeleteAt: displayIndices[0])
            } else {
                self.delegate?.queuePage(self, didRequestDeleteRows: displayIndices)
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
        updateCustomPrefixButtonLabels()
    }

    // MARK: - Layout constants

    private let headerH:    CGFloat = 48
    private let colHeaderH: CGFloat = 20
    private let bottomH:    CGFloat = 36

    override func layout() {
        super.layout()
        let b = bounds

        // Header
        headerView.frame = NSRect(x: 0, y: b.height - headerH, width: b.width, height: headerH)
        let headerAxisY = headerView.bounds.midY
        let edgePad: CGFloat = 10
        let interItemGap: CGFloat = 8
        let queueTitleToPillGap: CGFloat = 12
        let queueTitleTrailingSafety: CGFloat = 5
        let closeSize: CGFloat = 22
        let bookmarkSize: CGFloat = 24
        closeButton.frame = NSRect(x: max(edgePad, b.width - edgePad - closeSize),
                                   y: floor(headerAxisY - closeSize / 2),
                                   width: closeSize,
                                   height: closeSize)
        bookmarkFilterButton.frame = NSRect(x: max(edgePad, closeButton.frame.minX - interItemGap - bookmarkSize),
                                            y: floor(headerAxisY - bookmarkSize / 2),
                                            width: bookmarkSize,
                                            height: bookmarkSize)

        let titlePreferredWidth = ceil(titleLabel.intrinsicContentSize.width) + queueTitleTrailingSafety
        let titleAvailableWidth = max(0, bookmarkFilterButton.frame.minX - interItemGap - edgePad)
        let titleWidth = min(titlePreferredWidth, titleAvailableWidth)
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        titleLabel.frame = NSRect(x: edgePad,
                                  y: floor(headerAxisY - titleHeight / 2),
                                  width: titleWidth,
                                  height: titleHeight)
        let pillX = titleLabel.frame.maxX + queueTitleToPillGap
        let pillRight = bookmarkFilterButton.frame.minX - interItemGap
        let maxPillW = max(260, min(560, b.width * 0.66))
        let pillW = max(0, min(pillRight - pillX, maxPillW))
        let pillH: CGFloat = 30
        searchSortPill.frame = NSRect(x: pillX,
                                      y: floor(headerAxisY - pillH / 2),
                                      width: pillW,
                                      height: pillH)
        searchSortPill.isHidden = pillW <= 0
        let dividerH: CGFloat = 20
        let innerPad: CGFloat = 9
        let searchIconSlotWidth: CGFloat = 24
        let searchFieldX = innerPad + searchIconSlotWidth + 1
        let minimumSearchTextWidth: CGFloat = 72
        let minimumSortWidth: CGFloat = 84
        let sortWidth = min(CGFloat(122), max(minimumSortWidth, pillW * 0.34))
        let sortVisible = pillW >= searchFieldX + minimumSearchTextWidth + 6 + sortWidth
        let effectiveSortWidth = sortVisible ? sortWidth : 0
        let dividerX = sortVisible ? max(0, pillW - effectiveSortWidth - 1) : pillW
        let searchAreaWidth = sortVisible ? dividerX : pillW
        searchSortPill.searchFocusRect = NSRect(x: 0,
                                                y: 0,
                                                width: max(0, searchAreaWidth),
                                                height: pillH)
        searchSortDivider.frame = NSRect(x: dividerX,
                                         y: centeredY(height: dividerH, in: pillH),
                                         width: 1,
                                         height: dividerH)
        searchSortDivider.isHidden = !sortVisible
        searchIconView.frame = NSRect(x: innerPad,
                                      y: 0,
                                      width: searchIconSlotWidth,
                                      height: pillH)
        let searchFieldHeight: CGFloat = 22
        searchField.frame = NSRect(x: searchFieldX,
                                   y: centeredY(height: searchFieldHeight, in: pillH),
                                   width: max(0, searchAreaWidth - searchFieldX - 5),
                                   height: searchFieldHeight)
        let sortHeight: CGFloat = 24
        let sortFrame = NSRect(x: dividerX + 1,
                               y: centeredY(height: sortHeight, in: pillH),
                               width: max(0, effectiveSortWidth),
                               height: sortHeight)
        sortPopUpButton.isHidden = !sortVisible
        sortTitleView.isHidden = !sortVisible
        sortChevronView.isHidden = !sortVisible
        sortPopUpButton.frame = sortFrame
        let sortInnerPad: CGFloat = 12
        let chevronSlotWidth: CGFloat = 22
        sortChevronView.frame = NSRect(x: max(sortFrame.minX, sortFrame.maxX - chevronSlotWidth),
                                       y: sortFrame.minY,
                                       width: min(chevronSlotWidth, sortFrame.width),
                                       height: sortFrame.height)
        sortTitleView.frame = NSRect(x: sortFrame.minX + sortInnerPad,
                                     y: sortFrame.minY,
                                     width: max(0, sortChevronView.frame.minX - sortFrame.minX - sortInnerPad - 4),
                                     height: sortFrame.height)

        topSeparator.frame = NSRect(x: 0, y: b.height - headerH - 1, width: b.width, height: 1)

        // Table scroll view
        let tableTop = b.height - headerH - 1
        let tableH   = max(0, tableTop - bottomH - 1)
        scrollView.frame = NSRect(x: 0, y: bottomH + 1, width: b.width, height: tableH)
        emptyStateView.frame = scrollView.frame.insetBy(dx: 22, dy: 28)
        layoutEmptyState()
        scrollView.layoutSubtreeIfNeeded()
        // Do not manually set tableView.headerView.frame here — tile() owns header width,
        // and writing it inside a layout pass posts a frame-change notification that fed
        // back into the P43.6 recursive layout storm.
        applyColumnLayout(reason: "layout", forceDiagnostic: false)

        bottomSeparator.frame = NSRect(x: 0, y: bottomH, width: b.width, height: 1)

        // Bottom bar
        bottomBar.frame = NSRect(x: 0, y: 0, width: b.width, height: bottomH)
        let btnSz: CGFloat = 24
        let buttonY = centeredY(height: btnSz, in: bottomH)
        let bottomEdgePad: CGFloat = 10
        let spacing: CGFloat = 8
        let separatorGap: CGFloat = 12
        deleteButton.frame  = NSRect(x: bottomEdgePad, y: buttonY, width: btnSz, height: btnSz)
        var nextX: CGFloat = deleteButton.frame.maxX + spacing
        let primaryPrefixVisible = !customPrefixButton.isHidden
        let secondaryPrefixVisible = !customPrefixSecondaryButton.isHidden
        if primaryPrefixVisible || secondaryPrefixVisible {
            let pBtnH: CGFloat = 24
            let primaryW = primaryPrefixVisible
                ? Self.queuePrefixButtonWidth(for: customPrefixButton.attributedTitle.string)
                : 0
            let secondaryW = secondaryPrefixVisible
                ? Self.queuePrefixButtonWidth(for: customPrefixSecondaryButton.attributedTitle.string)
                : 0
            let dividerW: CGFloat = (primaryPrefixVisible && secondaryPrefixVisible) ? 1 : 0
            let pillW = primaryW + dividerW + secondaryW
            prefixPill.isHidden = false
            prefixPill.frame = NSRect(x: nextX,
                                      y: centeredY(height: pBtnH, in: bottomH),
                                      width: pillW,
                                      height: pBtnH)
            customPrefixButton.frame = primaryPrefixVisible
                ? NSRect(x: 0, y: 0, width: primaryW, height: pBtnH)
                : .zero
            prefixPillDivider.isHidden = dividerW == 0
            prefixPillDivider.frame = dividerW == 0
                ? .zero
                : NSRect(x: primaryW,
                         y: centeredY(height: 16, in: pBtnH),
                         width: dividerW,
                         height: 16)
            customPrefixSecondaryButton.frame = secondaryPrefixVisible
                ? NSRect(x: primaryW + dividerW, y: 0, width: secondaryW, height: pBtnH)
                : .zero
            nextX = prefixPill.frame.maxX + spacing
        } else {
            prefixPill.isHidden = true
            prefixPill.frame = .zero
            prefixPillDivider.isHidden = true
            prefixPillDivider.frame = .zero
            customPrefixButton.frame = .zero
            customPrefixSecondaryButton.frame = .zero
        }

        footerPrefixSeparator.isHidden = false
        footerPrefixSeparator.frame = NSRect(x: nextX + separatorGap - spacing,
                                             y: centeredY(height: 18, in: bottomH),
                                             width: 1,
                                             height: 18)
        nextX = footerPrefixSeparator.frame.maxX + separatorGap

        let rescanW: CGFloat = 72
        let rescanH: CGFloat = 24
        rescanButton.frame = NSRect(x: nextX,
                                    y: centeredY(height: rescanH, in: bottomH),
                                    width: rescanW,
                                    height: rescanH)
        rescanButton.isEnabled = !items.isEmpty
        nextX += rescanW + spacing

        let removeAllW: CGFloat = 92
        let removeAllH: CGFloat = 24
        removeAllButton.frame   = NSRect(x: max(nextX, b.width - removeAllW - bottomEdgePad),
                                         y: centeredY(height: removeAllH, in: bottomH),
                                         width: removeAllW,
                                         height: removeAllH)
        removeAllButton.isEnabled = !items.isEmpty
        let clearSeparatorX = removeAllButton.frame.minX - separatorGap
        let availableBetweenRescanAndClear = clearSeparatorX - nextX - spacing
        let totalPreferredW = ceil(totalDurationLabel.intrinsicContentSize.width)
        let showTotalDuration = availableBetweenRescanAndClear >= max(totalPreferredW, 86)
        footerClearSeparator.isHidden = !showTotalDuration
        footerClearSeparator.frame = showTotalDuration
            ? NSRect(x: clearSeparatorX,
                     y: centeredY(height: 18, in: bottomH),
                     width: 1,
                     height: 18)
            : .zero
        let labX = nextX
        let totalRightEdge = showTotalDuration ? footerClearSeparator.frame.minX - spacing : labX
        let totalHeight = ceil(totalDurationLabel.intrinsicContentSize.height)
        totalDurationLabel.frame = NSRect(x: labX,
                                          y: centeredY(height: totalHeight, in: bottomH),
                                          width: max(0, totalRightEdge - labX),
                                          height: totalHeight)
        totalDurationLabel.isHidden = !showTotalDuration

    }

    private func layoutEmptyState() {
        let b = emptyStateView.bounds
        // Decorative logo — centered behind all content, fixed max size
        let logoSize = min(min(b.width, b.height) * 0.78, 220.0)
        emptyStateLogoView.frame = NSRect(
            x: floor((b.width - logoSize) / 2),
            y: floor((b.height - logoSize) / 2),
            width: logoSize,
            height: logoSize
        )
        let contentW = min(b.width, 320)
        let x = floor((b.width - contentW) / 2)
        let buttonW: CGFloat = 118
        let buttonH: CGFloat = 28
        let totalH: CGFloat = addMediaButton.isHidden ? 112 : 152
        var y = floor((b.height - totalH) / 2) + totalH

        y -= 44
        emptyIconLabel.frame = NSRect(x: x, y: y, width: contentW, height: 44)
        y -= 26
        emptyStateLabel.frame = NSRect(x: x, y: y, width: contentW, height: 22)
        y -= 46
        emptyStateDetailLabel.frame = NSRect(x: x, y: y, width: contentW, height: 38)
        if addMediaButton.isHidden {
            addMediaButton.frame = .zero
        } else {
            y -= 38
            addMediaButton.frame = NSRect(x: x + floor((contentW - buttonW) / 2),
                                          y: y,
                                          width: buttonW,
                                          height: buttonH)
        }
    }

    @objc private func scrollContentDidResize() {
        // Vertical scrolling and vertical-scroller toggles both mutate the clip view.
        // Schedule (do not run inline) so that the synchronous notification chain
        // produced by tile()/setFrame writes cannot recurse on the same call stack.
        scheduleColumnLayout(reason: "clip-geometry-change")
        updateScrollHistoryState()
    }

    private func updateScrollHistoryState() {
        guard currentDisplayIndex >= 0 else { return }
        guard let itemRow = visibleRow(forDisplayIndex: currentDisplayIndex), itemRow > 0 else { return }
        let sectionRow = itemRow - 1
        let sectionRect = tableView.rect(ofRow: sectionRow)
        let clipOriginY = scrollView.contentView.bounds.origin.y
        if clipOriginY < sectionRect.minY - 5 {
            userIsReviewingHistory = true
        }
    }

    @objc private func scrollDidEndLive() {
        guard userIsReviewingHistory else { return }
        guard currentDisplayIndex >= 0,
              let itemRow = visibleRow(forDisplayIndex: currentDisplayIndex),
              itemRow > 0 else { return }
        let sectionRow = itemRow - 1
        let sectionRect = tableView.rect(ofRow: sectionRow)
        let clipOriginY = scrollView.contentView.bounds.origin.y
        // User scrolled back down to or past NOW PLAYING — snap to it
        if clipOriginY >= sectionRect.minY - 10 {
            let targetY = max(0, sectionRect.minY)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            userIsReviewingHistory = false
        }
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

        let rawAvailable = max(0, floor(clipView.bounds.width))
        let available = rawAvailable

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

        let nameWidth = max(0, floor(available))
        let durWidth: CGFloat = 0
        let sizeWidth: CGFloat = 0

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
        if !durCol.isHidden && abs(durCol.width - durWidth) > tol { durCol.width = durWidth; widthsChanged = true }
        if !sizeCol.isHidden && abs(sizeCol.width - sizeWidth) > tol { sizeCol.width = sizeWidth; widthsChanged = true }

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
        if !selected.isEmpty {
            return selected.sorted(by: >).compactMap { displayIndex(forVisibleRow: $0) }
        }
        return currentDisplayIndexIfVisible().map { [$0] } ?? []
    }

    private var currentSearchQuery: String {
        searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func visibleItem(at row: Int) -> Item? {
        guard row >= 0, row < visibleRows.count else { return nil }
        return visibleRows[row].item
    }

    private func displayIndex(forVisibleRow row: Int) -> Int? {
        guard row >= 0, row < visibleRows.count else { return nil }
        return visibleRows[row].displayIndex
    }

    private func visibleRow(forDisplayIndex displayIndex: Int) -> Int? {
        visibleRows.firstIndex { $0.displayIndex == displayIndex }
    }

    private func currentDisplayIndexIfVisible() -> Int? {
        guard currentDisplayIndex >= 0,
              visibleRow(forDisplayIndex: currentDisplayIndex) != nil else { return nil }
        return currentDisplayIndex
    }

    private func applySearchFilter(preservingSelectedURLs selectedURLs: Set<URL>) {
        let query = currentSearchQuery
        let bookmarkedPaths = BookmarkStore.shared.bookmarkedPaths()
        let pairs = items.enumerated().filter { _, item in
            let matchesSearch = query.isEmpty
                || item.displayName.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            let matchesBookmark = !bookmarkFilterEnabled
                || bookmarkedPaths.contains(item.url.standardizedFileURL.path)
            return matchesSearch && matchesBookmark
        }
        visibleToDisplayIndices = pairs.map(\.0)
        visibleItems = pairs.map(\.1)
        rebuildVisibleRows(from: pairs)
        allowsManualReorder = currentSortMode == .manual && query.isEmpty && !bookmarkFilterEnabled
        updateTotalDurationLabel()
        tableView.reloadData()
        if !selectedURLs.isEmpty {
            let remapped = IndexSet(visibleRows.indices.filter { row in
                guard let item = visibleRows[row].item else { return false }
                return selectedURLs.contains(item.url)
            })
            if !remapped.isEmpty {
                tableView.selectRowIndexes(remapped, byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
        }
        updateEmptyState()
        needsLayout = true
    }

    private func rebuildVisibleRows(from pairs: [(Int, Item)]) {
        visibleRows = []
        guard !pairs.isEmpty else { return }

        let filterActive = !currentSearchQuery.isEmpty || bookmarkFilterEnabled

        // PREVIOUS area — only when no filter active and a current item exists.
        // Previous items appear above NOW PLAYING; scrolling up reveals them.
        if !filterActive && currentDisplayIndex >= 0 {
            let prevPairs = pairs.filter { $0.0 < currentDisplayIndex }
            visibleRows.append(.section("PREVIOUS"))
            if prevPairs.isEmpty {
                visibleRows.append(.section("No previous"))
            } else {
                // Chronological top-to-bottom; newest previous item lands closest to NOW PLAYING.
                prevPairs.forEach { visibleRows.append(.item(displayIndex: $0.0, item: $0.1)) }
            }
        }

        if let currentPair = pairs.first(where: { $0.0 == currentDisplayIndex }) {
            visibleRows.append(.section("NOW PLAYING"))
            visibleRows.append(.item(displayIndex: currentPair.0, item: currentPair.1))
        }

        let nextPairs = filterActive
            ? pairs.filter { $0.0 != currentDisplayIndex }
            : pairs.filter { $0.0 > currentDisplayIndex }
        if !nextPairs.isEmpty {
            visibleRows.append(.section("UP NEXT"))
            nextPairs.forEach { visibleRows.append(.item(displayIndex: $0.0, item: $0.1)) }
        }
    }

    private func updateTotalDurationLabel() {
        if currentSearchQuery.isEmpty && !bookmarkFilterEnabled {
            totalDurationLabel.stringValue = "Total: \(totalDurationText)"
        } else {
            totalDurationLabel.stringValue = "Total: \(totalDurationText) | \(visibleItems.count)/\(items.count) shown"
        }
    }

    private func updateEmptyState() {
        if items.isEmpty {
            emptyIconLabel.stringValue = "+"
            emptyStateLabel.stringValue = "No media in queue"
            emptyStateDetailLabel.stringValue = "Add files or folders to build the queue."
            addMediaButton.isHidden = false
            emptyStateView.isHidden = false
            scrollView.isHidden = true
        } else if visibleItems.isEmpty {
            emptyIconLabel.stringValue = bookmarkFilterEnabled ? "bookmark" : "?"
            if bookmarkFilterEnabled && currentSearchQuery.isEmpty {
                emptyStateLabel.stringValue = "No bookmarked files in queue"
                emptyStateDetailLabel.stringValue = "Bookmark queued files from the playback bar, then return here."
            } else {
                emptyStateLabel.stringValue = "No matching files"
                emptyStateDetailLabel.stringValue = "Adjust search or filters to show more queue items."
            }
            addMediaButton.isHidden = true
            emptyStateView.isHidden = false
            scrollView.isHidden = true
        } else {
            emptyStateView.isHidden = true
            scrollView.isHidden = false
        }
        layoutEmptyState()
    }

    // MARK: - Actions

    @objc private func closeTapped()  { delegate?.queuePageDidRequestClose(self) }

    @objc private func addMediaTapped() {
        delegate?.queuePageDidRequestAddMedia(self)
    }

    @objc private func bookmarkFilterTapped() {
        bookmarkFilterEnabled.toggle()
        updateBookmarkFilterButton()
        let selectedURLs = Set(tableView.selectedRowIndexes.compactMap { row -> URL? in
            guard let item = visibleItem(at: row) else { return nil }
            return item.url
        })
        applySearchFilter(preservingSelectedURLs: selectedURLs)
    }

    @objc private func rowClicked() {
        // Single-click selection is handled by NSTableView so Command-click,
        // Shift-click, and keyboard selection extension keep normal AppKit behavior.
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard let displayIndex = displayIndex(forVisibleRow: row) else { return }
        delegate?.queuePage(self, didSelectDisplayIndex: displayIndex)
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

    @objc private func customPrefixTapped() {
        let selected = tableView.selectedRowIndexes
        if selected.isEmpty {
            guard let row = currentDisplayIndexIfVisible() else { return }
            delegate?.queuePage(self, didRequestCustomPrefixRenameAt: [row])
        } else {
            let displayIndices = selected.sorted().compactMap { displayIndex(forVisibleRow: $0) }
            delegate?.queuePage(self, didRequestCustomPrefixRenameAt: displayIndices)
        }
    }

    @objc private func customPrefixSecondaryTapped() {
        let selected = tableView.selectedRowIndexes
        if selected.isEmpty {
            guard let row = currentDisplayIndexIfVisible() else { return }
            delegate?.queuePage(self, didRequestSecondaryCustomPrefixRenameAt: [row])
        } else {
            let displayIndices = selected.sorted().compactMap { displayIndex(forVisibleRow: $0) }
            delegate?.queuePage(self, didRequestSecondaryCustomPrefixRenameAt: displayIndices)
        }
    }

    @objc private func handleCustomPrefixValueChanged() {
        updateCustomPrefixButtonLabels()
    }

    private func updateCustomPrefixButtonLabels() {
        let primary = SettingsWindowController.customPrefixValue()
        let secondary = SettingsWindowController.customPrefixSecondaryValue()
        customPrefixButton.attributedTitle = Self.queuePrefixButtonTitle(Self.queuePrefixLabel(primary),
                                                                         color: PrefixBrandColors.primaryCustomPrefixColor)
        customPrefixSecondaryButton.attributedTitle = Self.queuePrefixButtonTitle(Self.queuePrefixLabel(secondary),
                                                                                  color: PrefixBrandColors.secondaryCustomPrefixColor)
        updateCustomPrefixButtonVisibility()
        needsLayout = true
    }

    private func updateCustomPrefixButtonVisibility() {
        let primary = Self.trimmedPrefix(SettingsWindowController.customPrefixValue())
        let secondary = Self.trimmedPrefix(SettingsWindowController.customPrefixSecondaryValue())
        let hasDistinctSecondary = !secondary.isEmpty && secondary != primary
        customPrefixButton.isHidden = !isCustomPrefixRenameEnabled || primary.isEmpty
        customPrefixSecondaryButton.isHidden = !isCustomPrefixRenameEnabled || !hasDistinctSecondary
    }

    private static func trimmedPrefix(_ prefix: String) -> String {
        prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func queuePrefixLabel(_ prefix: String) -> String {
        let t = trimmedPrefix(prefix)
        if t.isEmpty { return "—" }
        return t.count <= 8 ? t : String(t.prefix(8)) + "…"
    }

    private static func queuePrefixButtonTitle(_ title: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: color
        ])
    }

    private static func queuePrefixButtonWidth(for title: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        ]
        let textWidth = ceil((title as NSString).size(withAttributes: attributes).width)
        return max(70, textWidth + 16)
    }

    @objc private func rescanTapped() {
        delegate?.queuePageDidRequestRescan(self)
    }

    @objc private func removeAllTapped() {
        delegate?.queuePageDidRequestRemoveAll(self)
    }

    @objc private func sortModeChanged() {
        guard !isUpdatingSortControl,
              let mode = QueueSortMode(rawValue: sortPopUpButton.selectedTag()) else { return }
        delegate?.queuePage(self, didChangeSortMode: mode)
    }

    @objc private func searchFieldChanged() {
        let selectedURLs = Set(tableView.selectedRowIndexes.compactMap { row -> URL? in
            guard let item = visibleItem(at: row) else { return nil }
            return item.url
        })
        applySearchFilter(preservingSelectedURLs: selectedURLs)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        searchFieldChanged()
    }

    private func updateBookmarkFilterButton() {
        let symbol = bookmarkFilterEnabled ? "bookmark.fill" : "bookmark"
        bookmarkFilterButton.symbolName = symbol
        bookmarkFilterButton.contentTintColor = bookmarkFilterEnabled ? Palette.accent : Palette.secondaryText
        bookmarkFilterButton.state = bookmarkFilterEnabled ? .on : .off
        bookmarkFilterButton.toolTip = bookmarkFilterEnabled ? "Showing bookmarked queue files" : "Show bookmarked queue files"
        bookmarkFilterButton.setAccessibilityValue(bookmarkFilterEnabled ? "on" : "off")
    }

    private func updateSortControlSelection() {
        isUpdatingSortControl = true
        sortPopUpButton.selectItem(withTag: currentSortMode.rawValue)
        sortTitleView.stringValue = sortPopUpButton.titleOfSelectedItem ?? "Sort: \(currentSortMode.title)"
        isUpdatingSortControl = false
    }

    private func updateHeaderSortIndicators() {
        tableView.tableColumn(withIdentifier: Self.colName)?.headerCell.stringValue = headerTitle("File",
                                                                                                  ascendingMode: .filenameAscending,
                                                                                                  descendingMode: .filenameDescending)
        tableView.tableColumn(withIdentifier: Self.colDur)?.headerCell.stringValue = headerTitle("Duration",
                                                                                                 ascendingMode: .durationAscending,
                                                                                                 descendingMode: .durationDescending)
        tableView.tableColumn(withIdentifier: Self.colSize)?.headerCell.stringValue = headerTitle("Size",
                                                                                                  ascendingMode: .fileSizeAscending,
                                                                                                  descendingMode: .fileSizeDescending)
        tableView.headerView?.needsDisplay = true
    }

    private func headerTitle(_ base: String,
                             ascendingMode: QueueSortMode,
                             descendingMode: QueueSortMode) -> String {
        if currentSortMode == ascendingMode {
            return "\(base) ^"
        }
        if currentSortMode == descendingMode {
            return "\(base) v"
        }
        return base
    }

    private func nextHeaderSortMode(for column: NSTableColumn) -> QueueSortMode? {
        switch column.identifier {
        case Self.colName:
            return currentSortMode == .filenameAscending ? .filenameDescending : .filenameAscending
        case Self.colDur:
            return currentSortMode == .durationAscending ? .durationDescending : .durationAscending
        case Self.colSize:
            return currentSortMode == .fileSizeAscending ? .fileSizeDescending : .fileSizeAscending
        default:
            return nil
        }
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
        guard displayIndex(forVisibleRow: row) != nil else { return NSMenu() }
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
        item.representedObject = displayIndex(forVisibleRow: row)
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

    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }

    // MARK: Drag source — write dragged row index to pasteboard

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard allowsManualReorder else { return nil }
        guard let displayIndex = displayIndex(forVisibleRow: row) else { return nil }
        // This view preserves the pre-existing single-row reorder model. Multi-row
        // selection is supported, but multi-row drag reorder is intentionally not.
        guard tableView.selectedRowIndexes.count <= 1 else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(displayIndex), forType: Self.draggedRowType)
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
        let to = displayInsertionIndex(forVisibleRow: row)
        // No-op: drop on same position or the position immediately below the source
        guard from != to, from != to - 1 else { return false }
        delegate?.queuePage(self, didReorderFromIndex: from, toIndex: to)
        return true
    }

    private func displayInsertionIndex(forVisibleRow row: Int) -> Int {
        guard row < visibleRows.count else { return items.count }
        if let displayIndex = displayIndex(forVisibleRow: row) {
            return displayIndex
        }
        var nextRow = row + 1
        while nextRow < visibleRows.count {
            if let displayIndex = displayIndex(forVisibleRow: nextRow) {
                return displayIndex
            }
            nextRow += 1
        }
        return items.count
    }
}

// MARK: - NSTableViewDelegate

extension QueuePageView: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let mode = nextHeaderSortMode(for: tableColumn) else { return }
        delegate?.queuePage(self, didChangeSortMode: mode)
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < visibleRows.count, let colID = tableColumn?.identifier else { return nil }
        guard colID == Self.colName else { return nil }

        if case let .section(title) = visibleRows[row] {
            let reuseID = NSUserInterfaceItemIdentifier("qpSectionCell")
            var cell = tableView.makeView(withIdentifier: reuseID, owner: nil) as? QueuePageSectionCell
            if cell == nil {
                cell = QueuePageSectionCell(reuseID: reuseID)
            }
            cell?.configure(title: title)
            return cell
        }

        guard let item = visibleItem(at: row), let displayIndex = displayIndex(forVisibleRow: row) else { return nil }
        let isCurrent = displayIndex == currentDisplayIndex

        let reuseID = NSUserInterfaceItemIdentifier("qpMediaCell")
        var cell = tableView.makeView(withIdentifier: reuseID, owner: nil) as? QueuePageCell
        if cell == nil {
            cell = QueuePageCell(reuseID: reuseID)
        }

        cell?.configure(item: item, isCurrent: isCurrent)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < visibleRows.count else { return 70 }
        if case .section = visibleRows[row] { return 28 }
        return 70
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < visibleRows.count else { return false }
        if case .section = visibleRows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = QueuePageRowView()
        guard row >= 0, row < visibleRows.count else { return rv }
        if case .section = visibleRows[row] {
            rv.isSection = true
        } else if let displayIndex = displayIndex(forVisibleRow: row) {
            rv.isCurrent = displayIndex == currentDisplayIndex
        } else {
            rv.isCurrent = false
        }
        rv.isBookmarked = visibleItem(at: row)?.isBookmarked ?? false
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

private final class QueuePageSectionCell: NSView {
    private let label = NSTextField(labelWithString: "")

    init(reuseID: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = reuseID
        label.drawsBackground = false
        label.isEditable = false
        label.isBordered = false
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = QueuePageView.Palette.tertiaryText
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 14, y: 5, width: max(0, bounds.width - 28), height: 14)
    }

    func configure(title: String) {
        label.stringValue = title
        setAccessibilityLabel(title)
    }
}

private final class QueuePageCell: NSView {

    private let playIndicator = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let bookmarkIndicator = NSImageView()

    init(reuseID: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = reuseID

        playIndicator.imageScaling = .scaleProportionallyDown
        addSubview(playIndicator)

        for label in [titleLabel, metadataLabel] {
            label.drawsBackground = false
            label.isEditable = false
            label.isBordered = false
            label.lineBreakMode = .byTruncatingMiddle
            addSubview(label)
        }

        bookmarkIndicator.imageScaling = .scaleProportionallyDown
        addSubview(bookmarkIndicator)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let left: CGFloat = 28
        let right: CGFloat = 36
        playIndicator.frame = NSRect(x: 12, y: 26, width: 12, height: 12)
        bookmarkIndicator.frame = NSRect(x: bounds.width - 34, y: floor((bounds.height - 13) / 2), width: 13, height: 13)
        titleLabel.frame = NSRect(x: left, y: 34, width: max(0, bounds.width - left - right), height: 18)
        metadataLabel.frame = NSRect(x: left, y: 15, width: max(0, bounds.width - left - right), height: 16)
    }

    func configure(item: QueuePageView.Item, isCurrent: Bool) {
        let titleColor = isCurrent ? QueuePageView.Palette.currentText : QueuePageView.Palette.primaryText
        let baseFont = NSFont.systemFont(ofSize: 12.5, weight: isCurrent ? .semibold : .medium)
        let text = item.displayName
        let primaryPrefix = SettingsWindowController.customPrefixValue().trimmingCharacters(in: .whitespacesAndNewlines)
        let secondaryPrefix = SettingsWindowController.customPrefixSecondaryValue().trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixMatches: [(prefix: String, color: NSColor)] = [
            (primaryPrefix, PrefixBrandColors.primaryCustomPrefixColor),
            (secondaryPrefix, PrefixBrandColors.secondaryCustomPrefixColor)
        ]
        .filter { !$0.prefix.isEmpty }
        .sorted { $0.prefix.count > $1.prefix.count } // prefer longer match to avoid partial highlighting
        if let matchedPrefix = prefixMatches.first(where: { text.hasPrefix($0.prefix) }) {
            let attrStr = NSMutableAttributedString(string: text, attributes: [
                .font: baseFont,
                .foregroundColor: titleColor
            ])
            let prefixRange = NSRange(location: 0, length: (matchedPrefix.prefix as NSString).length)
            attrStr.addAttributes([
                .foregroundColor: matchedPrefix.color.withAlphaComponent(0.92),
                .font: NSFont.systemFont(ofSize: 12.5, weight: .bold)
            ], range: prefixRange)
            titleLabel.attributedStringValue = attrStr
        } else {
            titleLabel.font = baseFont
            titleLabel.textColor = titleColor
            titleLabel.stringValue = text
        }

        metadataLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        metadataLabel.textColor = QueuePageView.Palette.secondaryText
        metadataLabel.stringValue = "\(item.duration) | \(item.fileSize)"

        let playCfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        if isCurrent, let img = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Now playing") {
            playIndicator.image = img.withSymbolConfiguration(playCfg) ?? img
            playIndicator.contentTintColor = QueuePageView.Palette.accent
            playIndicator.isHidden = false
        } else {
            playIndicator.image = nil
            playIndicator.isHidden = true
        }

        let bookmarkCfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        if item.isBookmarked, let img = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "Bookmarked") {
            bookmarkIndicator.image = img.withSymbolConfiguration(bookmarkCfg) ?? img
            bookmarkIndicator.contentTintColor = QueuePageView.Palette.accent.withAlphaComponent(0.9)
            bookmarkIndicator.isHidden = false
        } else {
            bookmarkIndicator.image = nil
            bookmarkIndicator.isHidden = true
        }
        setAccessibilityLabel(item.isBookmarked ? "\(text), bookmarked" : text)
        setAccessibilityValue(isCurrent ? "now playing" : "queued")
    }
}

// MARK: - QueuePageRowView

private final class QueuePageRowView: NSTableRowView {

    var isSection: Bool = false
    var isCurrent: Bool = false
    var isBookmarked: Bool = false

    // Ensure the row redraws whenever isSelected changes. With selectionHighlightStyle = .none,
    // AppKit may not reliably call setNeedsDisplay on the row view after a programmatic
    // selectRowIndexes call, so we force it here.
    override var isSelected: Bool {
        get { super.isSelected }
        set { if super.isSelected != newValue { super.isSelected = newValue; needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard !isSection else { return }
        let highlightRect = bounds.insetBy(dx: 9, dy: 5)
        let path = NSBezierPath(roundedRect: highlightRect, xRadius: 8, yRadius: 8)

        let baseFill = isCurrent
            ? QueuePageView.Palette.currentFill.withAlphaComponent(0.28)
            : NSColor.white.withAlphaComponent(0.045)
        baseFill.setFill()
        path.fill()

        (isCurrent ? QueuePageView.Palette.accent.withAlphaComponent(0.42) : QueuePageView.Palette.separator).setStroke()
        path.lineWidth = 1
        path.stroke()

        if isSelected {
            QueuePageView.Palette.selectedFill.setFill()
            path.fill()
        }

        if isCurrent {
            QueuePageView.Palette.currentBar.setFill()
            let barRect = NSRect(x: 10, y: 12, width: 4, height: max(0, bounds.height - 24))
            NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2).fill()
        }
    }

    // Use drawBackground for selection so we don't get the system blue.
    override var isEmphasized: Bool { get { false } set {} }
}

// MARK: - Native Queue Table Header

private final class QueueSearchSortPillView: NSView {
    weak var searchField: NSSearchField?
    var searchFocusRect: NSRect = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if searchFocusRect.contains(point),
           let searchField = searchField,
           !searchField.isHidden,
           searchField.frame.width > 0 {
            window?.makeFirstResponder(searchField)
            return
        }
        super.mouseDown(with: event)
    }
}

private final class QueuePassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class QueueSearchFieldCell: NSSearchFieldCell {
    private let textLeading: CGFloat = 0
    private let textTrailing: CGFloat = 6

    override init(textCell string: String) {
        super.init(textCell: string)
        // NSCell.init(textCell:) creates a non-editable label cell; restore editability.
        isEditable = true
        usesSingleLineMode = true
        isScrollable = true
        lineBreakMode = .byClipping
    }

    required init(coder: NSCoder) { fatalError() }

    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        .zero
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        let x = rect.minX + textLeading
        let width = max(0, rect.maxX - x - textTrailing)
        let font = self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let textHeight = ceil(font.ascender - font.descender + font.leading)
        return NSRect(x: x,
                      y: rect.minY + floor((rect.height - textHeight) / 2),
                      width: width,
                      height: textHeight)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        searchTextRect(forBounds: rect)
    }

    override func edit(withFrame rect: NSRect,
                       in controlView: NSView,
                       editor textObj: NSText,
                       delegate: Any?,
                       event: NSEvent?) {
        super.edit(withFrame: searchTextRect(forBounds: rect),
                   in: controlView,
                   editor: textObj,
                   delegate: delegate,
                   event: event)
    }

    override func select(withFrame rect: NSRect,
                         in controlView: NSView,
                         editor textObj: NSText,
                         delegate: Any?,
                         start selStart: Int,
                         length selLength: Int) {
        super.select(withFrame: searchTextRect(forBounds: rect),
                     in: controlView,
                     editor: textObj,
                     delegate: delegate,
                     start: selStart,
                     length: selLength)
    }
}

private final class QueueTransparentPopUpButtonCell: NSPopUpButtonCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {}
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {}
}

private final class QueueHeaderSymbolButton: NSButton {
    private let symbolView = QueueCenteredSymbolView()

    var symbolName: String? {
        get { symbolView.symbolName }
        set { symbolView.symbolName = newValue }
    }

    var symbolPointSize: CGFloat {
        get { symbolView.pointSize }
        set { symbolView.pointSize = newValue }
    }

    var symbolWeight: NSFont.Weight {
        get { symbolView.weight }
        set { symbolView.weight = newValue }
    }

    override var contentTintColor: NSColor? {
        didSet {
            symbolView.color = contentTintColor ?? QueuePageView.Palette.secondaryText
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        image = nil
        symbolView.color = contentTintColor ?? QueuePageView.Palette.secondaryText
        addSubview(symbolView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        symbolView.frame = bounds
    }
}

private final class QueueCenteredSymbolView: NSView {
    var symbolName: String? {
        didSet { rebuildImage() }
    }
    var pointSize: CGFloat = 13 {
        didSet { rebuildImage() }
    }
    var weight: NSFont.Weight = .regular {
        didSet { rebuildImage() }
    }
    var color: NSColor = .labelColor {
        didSet { needsDisplay = true }
    }
    private var symbolImage: NSImage?

    func configure(symbolName: String,
                   pointSize: CGFloat,
                   weight: NSFont.Weight,
                   color: NSColor,
                   accessibilityDescription: String?) {
        self.pointSize = pointSize
        self.weight = weight
        self.color = color
        self.symbolName = symbolName
        setAccessibilityElement(accessibilityDescription != nil)
        if let accessibilityDescription {
            setAccessibilityLabel(accessibilityDescription)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let symbolImage else { return }
        let alignmentRect = symbolImage.alignmentRect
        let drawOrigin = NSPoint(x: bounds.midX - alignmentRect.midX,
                                 y: bounds.midY - alignmentRect.midY)
        let drawRect = NSRect(origin: drawOrigin, size: symbolImage.size)
        symbolImage.draw(in: drawRect,
                         from: .zero,
                         operation: .sourceOver,
                         fraction: 1.0,
                         respectFlipped: true,
                         hints: nil)
        color.setFill()
        drawRect.fill(using: .sourceAtop)
    }

    private func rebuildImage() {
        guard let symbolName,
              let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            symbolImage = nil
            needsDisplay = true
            return
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        symbolImage = image.withSymbolConfiguration(configuration) ?? image
        symbolImage?.isTemplate = true
        needsDisplay = true
    }
}

private final class QueueCenteredTextView: NSView {
    var stringValue: String = "" {
        didSet { needsDisplay = true }
    }
    var font: NSFont = .systemFont(ofSize: 10.5, weight: .regular) {
        didSet { needsDisplay = true }
    }
    var textColor: NSColor = .labelColor {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]
        let textHeight = ceil(font.ascender - font.descender + font.leading)
        let textRect = NSRect(x: 0,
                              y: bounds.minY + floor((bounds.height - textHeight) / 2),
                              width: bounds.width,
                              height: textHeight)
        (stringValue as NSString).draw(in: textRect, withAttributes: attrs)
    }
}

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
