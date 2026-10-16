import AppKit

/// A directory in the sidebar tree. Children (subfolders only) are read lazily on first access.
final class FolderNode {
    let url: URL
    let name: String
    let symbol: String
    private var loadedChildren: [FolderNode]?

    init(url: URL, name: String? = nil, symbol: String = "folder") {
        self.url = url.standardizedFileURL
        self.name = name ?? FileManager.default.displayName(atPath: url.path)
        self.symbol = symbol
    }

    var children: [FolderNode] {
        if let loadedChildren { return loadedChildren }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        let nodes = items
            .filter { u in
                let v = try? u.resourceValues(forKeys: keys)
                return v?.isDirectory == true && v?.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { FolderNode(url: $0) }
        loadedChildren = nodes
        return nodes
    }

    /// Shows a disclosure triangle without reading the folder, so collapsed rows never
    /// touch privacy-protected locations (Desktop, Documents, …) until the user opens them.
    var mayHaveChildren: Bool { loadedChildren.map { !$0.isEmpty } ?? true }

    func reload() { loadedChildren = nil }

    /// Child named `name`, adding it if it is a hidden folder that the listing skipped.
    func child(named name: String) -> FolderNode? {
        if let c = children.first(where: { $0.url.lastPathComponent == name }) { return c }
        let u = url.appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let node = FolderNode(url: u)
        loadedChildren?.append(node)
        return node
    }
}

/// Optional folder-tree sidebar. Selecting a folder calls `onSelect`.
final class FolderTree: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let view = NSScrollView()
    let outline = NSOutlineView()
    var onSelect: ((URL) -> Void)?

    private var roots: [FolderNode] = []
    private var revealing = false
    private var lastRevealed: URL?
    private let cellID = NSUserInterfaceItemIdentifier("folderCell")

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = true
        outline.dataSource = self
        outline.delegate = self

        let menu = NSMenu()
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh", action: #selector(refreshClicked), keyEquivalent: "").target = self
        outline.menu = menu

        view.documentView = outline
        view.hasVerticalScroller = true
        view.autohidesScrollers = true
        view.drawsBackground = false
        reloadRoots()
    }

    private func reloadRoots() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var list = [FolderNode(url: home, symbol: "house")]
        let places: [(FileManager.SearchPathDirectory, String)] = [
            (.desktopDirectory, "menubar.dock.rectangle"), (.documentDirectory, "doc"),
            (.downloadsDirectory, "arrow.down.circle"), (.picturesDirectory, "photo"),
        ]
        for (dir, symbol) in places {
            if let u = fm.urls(for: dir, in: .userDomainMask).first, fm.fileExists(atPath: u.path) {
                list.append(FolderNode(url: u, symbol: symbol))
            }
        }
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey],
                                           options: [.skipHiddenVolumes]) ?? []
        for v in volumes {
            let name = (try? v.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            list.append(FolderNode(url: v, name: name, symbol: v.path == "/" ? "internaldrive" : "externaldrive"))
        }
        roots = list
        outline.reloadData()
    }

    /// Expands the tree down to `folder` and selects it, without firing `onSelect`.
    func reveal(_ folder: URL) {
        let target = folder.standardizedFileURL
        guard target != lastRevealed else { return }
        let parts = target.pathComponents
        // Deepest root that contains the target (e.g. ~/Pictures beats ~ beats /).
        guard let root = roots
            .filter({ parts.starts(with: $0.url.pathComponents) })
            .max(by: { $0.url.pathComponents.count < $1.url.pathComponents.count }) else { return }

        revealing = true
        defer { revealing = false }
        var node = root
        for comp in parts.dropFirst(root.url.pathComponents.count) {
            let countBefore = node.children.count
            guard let next = node.child(named: comp) else { break }
            if node.children.count != countBefore { outline.reloadItem(node, reloadChildren: true) }
            outline.expandItem(node)
            node = next
        }
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
        lastRevealed = target
    }

    private var clickedNode: FolderNode? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return outline.item(atRow: row) as? FolderNode
    }

    @objc private func revealClicked() {
        if let n = clickedNode { NSWorkspace.shared.activateFileViewerSelecting([n.url]) }
    }

    @objc private func refreshClicked() {
        guard let n = clickedNode else { reloadRoots(); return }
        n.reload()
        outline.reloadItem(n, reloadChildren: true)
    }

    // MARK: Data source / delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FolderNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FolderNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FolderNode)?.mayHaveChildren ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView ?? makeCell()
        cell.textField?.stringValue = node.name
        cell.imageView?.image = NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil)
        cell.toolTip = node.url.path
        return cell
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = cellID
        let iv = NSImageView()
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingTail
        for v in [iv, tf] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.imageView = iv
        cell.textField = tf
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        // Drop the triangle from folders that turned out to have no subfolders.
        if let node = notification.userInfo?["NSObject"] as? FolderNode, node.children.isEmpty {
            outline.reloadItem(node)
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !revealing, let node = outline.item(atRow: outline.selectedRow) as? FolderNode else { return }
        lastRevealed = node.url
        onSelect?(node.url)
    }
}
