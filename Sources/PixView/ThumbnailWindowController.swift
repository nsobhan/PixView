import AppKit

private let itemID = NSUserInterfaceItemIdentifier("thumb")

final class ThumbnailWindowController: NSWindowController, NSCollectionViewDataSource {
    private weak var viewer: ViewerWindowController?
    private let collection = ThumbCollectionView()
    private var urls: [URL] = []
    private let cache = NSCache<NSURL, NSImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

    init(viewer: ViewerWindowController) {
        self.viewer = viewer
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Thumbnails"
        window.center()
        window.setFrameAutosaveName("PixViewThumbnails")
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 170, height: 190)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.dataSource = self
        collection.register(ThumbnailItem.self, forItemWithIdentifier: itemID)
        collection.onActivate = { [weak self] i in self?.activate(i) }

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        window.contentView = scroll
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        guard let viewer, window?.isVisible == true else { return }
        urls = viewer.files
        cache.removeAllObjects()
        let folder = urls.first?.deletingLastPathComponent().lastPathComponent ?? ""
        window?.title = "Thumbnails — \(folder) (\(urls.count) images)"
        collection.reloadData()
        select(index: viewer.index)
    }

    func select(index: Int) {
        guard window?.isVisible == true, urls.indices.contains(index) else { return }
        let path = IndexPath(item: index, section: 0)
        collection.selectionIndexPaths = [path]
        collection.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
    }

    private func activate(_ i: Int) {
        guard let viewer, urls.indices.contains(i), viewer.confirmDiscardChanges() else { return }
        viewer.show(at: i)
        viewer.showWindow(nil)
    }

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { urls.count }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: itemID, for: indexPath) as! ThumbnailItem
        let url = urls[indexPath.item]
        item.url = url
        item.textField?.stringValue = url.lastPathComponent
        item.onDoubleClick = { [weak self] in self?.activate(indexPath.item) }
        if let img = cache.object(forKey: url as NSURL) {
            item.imageView?.image = img
        } else {
            item.imageView?.image = nil
            queue.addOperation { [weak self] in
                guard let cg = ImageIOSupport.thumbnail(url, maxPixel: 320) else { return }
                let img = NSImage(cgImage: cg, size: .zero)
                DispatchQueue.main.async {
                    self?.cache.setObject(img, forKey: url as NSURL)
                    if item.url == url { item.imageView?.image = img }
                }
            }
        }
        return item
    }
}

final class ThumbCollectionView: NSCollectionView {
    var onActivate: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.specialKey == .carriageReturn || event.specialKey == .enter,
           let i = selectionIndexPaths.first?.item {
            onActivate?(i)
        } else {
            super.keyDown(with: event)
        }
    }
}

final class ThumbnailItem: NSCollectionViewItem {
    var url: URL?
    var onDoubleClick: (() -> Void)?

    override func loadView() {
        let cell = ThumbCell()
        cell.wantsLayer = true
        cell.layer?.cornerRadius = 6
        cell.onDoubleClick = { [weak self] in self?.onDoubleClick?() }

        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyDown
        let tf = NSTextField(labelWithString: "")
        tf.alignment = .center
        tf.lineBreakMode = .byTruncatingMiddle
        tf.font = .systemFont(ofSize: 11)
        for v in [iv, tf] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            iv.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            tf.topAnchor.constraint(equalTo: iv.bottomAnchor, constant: 4),
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
        ])
        tf.setContentCompressionResistancePriority(.required, for: .vertical)
        tf.setContentHuggingPriority(.required, for: .vertical)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view = cell
        imageView = iv
        textField = tf
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil
        }
    }
}

final class ThumbCell: NSView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }
}
