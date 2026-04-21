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
}

/// Full in-window Queue Page panel.
/// Designed to occupy ~35–45 % of the window width as a right-side panel.
/// Shows the playback set in current traversal order with filename, duration,
/// and file size. Supports single-click-to-play and a rename affordance.
final class QueuePageView: NSView {

    // MARK: - Item model

    struct Item {
        let url:         URL
        var displayName: String
        var duration:    String   // "1:23:45" or "–:––"
        var fileSize:    String   // "12.3 MB" or "–"
    }

    // MARK: - Public state

    weak var delegate: QueuePageViewDelegate?

    /// Call update(items:currentIndex:) to refresh data and reload the table.
    private(set) var items: [Item] = []
    private(set) var currentDisplayIndex: Int = -1
    private var currentSortMode: QueueSortMode = .manual
    private var allowsManualReorder = true
    private var isUpdatingSortControl = false

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
    }

    // MARK: - Subviews

    private let headerView       = NSView()
    private let titleLabel       = NSTextField(labelWithString: "Queue")
    private let sortPopUpButton  = NSPopUpButton()
    private let closeButton      = NSButton()
    private let topSeparator     = NSView()
    private let colHeaderView    = QueueColumnHeaderView()
    private let colSeparator     = NSView()
    let scrollView               = NSScrollView()
    let tableView                = QueuePageTableView()
    private let bottomSeparator  = NSView()
    private let bottomBar        = NSView()
    private let renameButton     = NSButton()
    private let deleteButton     = NSButton()
    private let totalDurationLabel = NSTextField(labelWithString: "Total: 00:00:00")

    // Column identifiers
    private static let colName = NSUserInterfaceItemIdentifier("name")
    private static let colDur  = NSUserInterfaceItemIdentifier("dur")
    private static let colSize = NSUserInterfaceItemIdentifier("size")

    // Pasteboard type for internal row-reorder drag
    private static let draggedRowType = NSPasteboard.PasteboardType("com.dwb.queueRow")

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupViews()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupViews() {
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.98).cgColor

        // ── Header ──────────────────────────────────────────────────────────
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1.0).cgColor
        addSubview(headerView)

        titleLabel.font           = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor      = NSColor.white.withAlphaComponent(0.90)
        titleLabel.drawsBackground = false
        titleLabel.isEditable     = false
        titleLabel.isBordered     = false
        headerView.addSubview(titleLabel)

        sortPopUpButton.font = .systemFont(ofSize: 11, weight: .medium)
        sortPopUpButton.bezelStyle = .rounded
        sortPopUpButton.target = self
        sortPopUpButton.action = #selector(sortModeChanged)
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
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        closeButton.toolTip          = "Close Queue"
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        headerView.addSubview(closeButton)

        // ── Separators ────────────────────────────────────────────────────
        for sep in [topSeparator, colSeparator, bottomSeparator] {
            sep.wantsLayer = true
            sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
            addSubview(sep)
        }

        // ── Column header ─────────────────────────────────────────────────
        addSubview(colHeaderView)

        // ── Table ─────────────────────────────────────────────────────────
        let nameCol = NSTableColumn(identifier: Self.colName)
        nameCol.title  = "File"
        nameCol.resizingMask = [.autoresizingMask]
        nameCol.minWidth = 60

        let durCol  = NSTableColumn(identifier: Self.colDur)
        durCol.title = "Duration"
        durCol.width = 58
        durCol.minWidth = 40
        durCol.maxWidth = 72
        durCol.resizingMask = []

        let sizeCol = NSTableColumn(identifier: Self.colSize)
        sizeCol.title = "Size"
        sizeCol.width = 58
        sizeCol.minWidth = 40
        sizeCol.maxWidth = 72
        sizeCol.resizingMask = []

        tableView.addTableColumn(nameCol)
        tableView.addTableColumn(durCol)
        tableView.addTableColumn(sizeCol)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.headerView   = nil
        tableView.rowHeight    = 26
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.dataSource   = self
        tableView.delegate     = self
        tableView.target       = self
        tableView.action       = #selector(rowClicked)
        tableView.contextMenuProvider = { [weak self] row in
            self?.makeContextMenu(for: row)
        }

        // Enable row reordering via drag-and-drop
        tableView.registerForDraggedTypes([Self.draggedRowType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView       = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers  = true
        scrollView.borderType          = .noBorder
        scrollView.backgroundColor     = .clear
        addSubview(scrollView)

        // ── Bottom bar ────────────────────────────────────────────────────
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1.0).cgColor
        addSubview(bottomBar)

        renameButton.isBordered     = false
        renameButton.bezelStyle     = .regularSquare
        renameButton.imageScaling   = .scaleProportionallyDown
        let pencilCfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        if let img = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Rename") {
            renameButton.image = img.withSymbolConfiguration(pencilCfg) ?? img
        }
        renameButton.contentTintColor = NSColor.white.withAlphaComponent(0.65)
        renameButton.toolTip   = "Rename selected file"
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
        deleteButton.contentTintColor = NSColor.systemRed.withAlphaComponent(0.78)
        deleteButton.toolTip   = "Remove selected file from queue"
        deleteButton.target    = self
        deleteButton.action    = #selector(deleteTapped)
        bottomBar.addSubview(deleteButton)

        totalDurationLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        totalDurationLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        totalDurationLabel.alignment = .right
        totalDurationLabel.lineBreakMode = .byClipping
        bottomBar.addSubview(totalDurationLabel)
    }

    // MARK: - Layout constants

    private let headerH:    CGFloat = 30
    private let colHeaderH: CGFloat = 20
    private let bottomH:    CGFloat = 26

    override func layout() {
        super.layout()
        let b = bounds

        // Header
        headerView.frame = NSRect(x: 0, y: b.height - headerH, width: b.width, height: headerH)
        let closeX = b.width - headerH + 6
        let sortWidth: CGFloat = 158
        sortPopUpButton.frame = NSRect(x: max(92, closeX - sortWidth - 10),
                                       y: 4,
                                       width: sortWidth,
                                       height: headerH - 8)
        titleLabel.frame = NSRect(x: 12,
                                  y: 0,
                                  width: max(0, sortPopUpButton.frame.minX - 20),
                                  height: headerH)
        closeButton.frame = NSRect(x: closeX, y: 4, width: headerH - 10, height: headerH - 8)

        topSeparator.frame = NSRect(x: 0, y: b.height - headerH - 1, width: b.width, height: 1)

        // Column header
        colHeaderView.frame = NSRect(x: 0, y: b.height - headerH - 1 - colHeaderH,
                                     width: b.width, height: colHeaderH)

        colSeparator.frame = NSRect(x: 0, y: b.height - headerH - 1 - colHeaderH - 1,
                                    width: b.width, height: 1)

        // Table scroll view
        let tableTop = b.height - headerH - 1 - colHeaderH - 1
        let tableH   = max(0, tableTop - bottomH - 1)
        scrollView.frame = NSRect(x: 0, y: bottomH + 1, width: b.width, height: tableH)

        bottomSeparator.frame = NSRect(x: 0, y: bottomH, width: b.width, height: 1)

        // Bottom bar
        bottomBar.frame = NSRect(x: 0, y: 0, width: b.width, height: bottomH)
        let btnSz: CGFloat = 18
        renameButton.frame = NSRect(x: 8, y: (bottomH - btnSz) / 2, width: btnSz, height: btnSz)
        deleteButton.frame = NSRect(x: 34, y: (bottomH - btnSz) / 2, width: btnSz, height: btnSz)
        totalDurationLabel.frame = NSRect(x: 60,
                                          y: 0,
                                          width: max(0, b.width - 68),
                                          height: bottomH)

        // Sync column header widths with table columns
        colHeaderView.syncColumns(from: tableView)
    }

    // MARK: - Actions

    @objc private func closeTapped()  { delegate?.queuePageDidRequestClose(self) }

    @objc private func rowClicked() {
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
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : currentDisplayIndex
        guard row >= 0 else { return }
        delegate?.queuePage(self, didRequestDeleteAt: row)
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return contextMenuProvider?(row)
    }
}

// MARK: - NSTableViewDataSource

extension QueuePageView: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    // MARK: Drag source — write dragged row index to pasteboard

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard allowsManualReorder else { return nil }
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
        label.frame = NSRect(x: 4, y: (bounds.height - 13) / 2, width: bounds.width - 8, height: 13)
    }

    func configure(text: String, alignment: NSTextAlignment, isCurrent: Bool) {
        label.stringValue = text
        label.alignment   = alignment
        if isCurrent {
            label.font      = .boldSystemFont(ofSize: 11.5)
            label.textColor = .controlAccentColor
        } else {
            label.font      = .systemFont(ofSize: 11.5)
            label.textColor = NSColor.white.withAlphaComponent(0.80)
        }
    }
}

// MARK: - QueuePageRowView

private final class QueuePageRowView: NSTableRowView {

    var isCurrent: Bool = false

    override func drawBackground(in dirtyRect: NSRect) {
        if isSelected {
            NSColor.white.withAlphaComponent(0.10).setFill()
            bounds.fill()
        } else if isCurrent {
            NSColor.white.withAlphaComponent(0.05).setFill()
            bounds.fill()
        }
    }

    // Use drawBackground for selection so we don't get the system blue.
    override var isEmphasized: Bool { get { false } set {} }
}

// MARK: - QueueColumnHeaderView

/// Draws column header labels aligned with the table's actual column rects.
final class QueueColumnHeaderView: NSView {

    private var columnInfo: [(title: String, x: CGFloat, width: CGFloat)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.14, alpha: 1.0).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    func syncColumns(from tableView: NSTableView) {
        columnInfo = tableView.tableColumns.map { col in
            let idx = tableView.column(withIdentifier: col.identifier)
            let rect = tableView.rect(ofColumn: idx)
            return (col.title, rect.minX, rect.width)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.45)
        ]
        for info in columnInfo {
            let labelRect = NSRect(x: info.x + 4,
                                   y: (bounds.height - 11) / 2,
                                   width: max(0, info.width - 8),
                                   height: 11)
            info.title.draw(in: labelRect, withAttributes: attrs)
        }
    }
}
