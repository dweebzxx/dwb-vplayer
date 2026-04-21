import Cocoa

/// Compact playback-set list displayed as a transient popover.
/// Shows URLs in current traversal order (shuffle-aware).
/// Clicking a row plays that item immediately.
final class PlaybackQueuePanel: NSObject {

    // MARK: - Public interface

    /// URLs in the current display/traversal order (shuffle-aware).
    var items: [URL] = []

    /// Index in `items` that is currently playing. -1 if nothing playing.
    var currentDisplayIndex: Int = -1

    /// Called when the user selects a row. Passes the display index.
    var onSelectIndex: ((Int) -> Void)?
    var onRenameIndex: ((Int) -> Void)?
    var onRevealIndex: ((Int) -> Void)?
    var onDeleteIndex: ((Int) -> Void)?

    var isShown: Bool { popover.isShown }

    // MARK: - Private

    private let popover    = NSPopover()
    private let tableView  = QueuePanelTableView()
    private let scrollView = NSScrollView()

    // MARK: - Init

    override init() {
        super.init()
        setup()
    }

    // MARK: - Setup

    private func setup() {
        let col = NSTableColumn(identifier: .init("filename"))
        col.minWidth = 180
        col.maxWidth = 500
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.target     = self
        tableView.action     = #selector(rowClicked)
        tableView.contextMenuProvider = { [weak self] row in
            self?.makeContextMenu(for: row)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers  = true
        scrollView.borderType          = .noBorder
        scrollView.backgroundColor     = .clear

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 220))
        container.wantsLayer = true
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)

        let vc = NSViewController()
        vc.view = container

        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 270, height: 220)
        popover.behavior    = .transient
        popover.animates    = true
    }

    // MARK: - Show / toggle

    func show(relativeTo view: NSView) {
        if popover.isShown {
            popover.close()
            return
        }
        tableView.reloadData()
        if currentDisplayIndex >= 0 {
            tableView.scrollRowToVisible(currentDisplayIndex)
        }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    func close() { popover.close() }

    func reloadData() {
        tableView.reloadData()
        if currentDisplayIndex >= 0 {
            tableView.scrollRowToVisible(currentDisplayIndex)
        }
    }

    // MARK: - Row action

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        onSelectIndex?(row)
        popover.close()
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
        onSelectIndex?(row)
        popover.close()
    }

    @objc private func contextReveal(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int else { return }
        onRevealIndex?(row)
    }

    @objc private func contextRename(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int else { return }
        onRenameIndex?(row)
        popover.close()
    }

    @objc private func contextDelete(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int else { return }
        onDeleteIndex?(row)
    }
}

private final class QueuePanelTableView: NSTableView {
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

extension PlaybackQueuePanel: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
}

// MARK: - NSTableViewDelegate

extension PlaybackQueuePanel: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("queueCell")
        var cell = tableView.makeView(withIdentifier: id, owner: nil) as? QueueCellView
        if cell == nil {
            cell = QueueCellView()
            cell?.identifier = id
        }
        cell?.configure(filename: items[row].lastPathComponent,
                        isCurrent: row == currentDisplayIndex)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 24 }
}

// MARK: - QueueCellView

private final class QueueCellView: NSView {

    private let dot   = NSView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(filename: String, isCurrent: Bool) {
        label.stringValue = filename
        if isCurrent {
            label.font      = .boldSystemFont(ofSize: 12)
            label.textColor = .controlAccentColor
            dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            dot.isHidden    = false
        } else {
            label.font      = .systemFont(ofSize: 12)
            label.textColor = .labelColor
            dot.isHidden    = true
        }
    }
}
