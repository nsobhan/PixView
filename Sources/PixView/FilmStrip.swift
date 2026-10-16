import AppKit

private let stripItemID = NSUserInterfaceItemIdentifier("stripThumb")

/// Horizontal strip of thumbnails for the current folder, shown under the image.
final class FilmStrip: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    static let height: CGFloat = 122

    let view = HorizontalScrollView()
    private let collection = NSCollectionView()
    private(set) var urls: [URL] = []
    var onSelect: ((Int) -> Void)?

    private let cache = NSCache<NSURL, NSImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

    override init() {
        super.init()
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 104, height: 108)
        layout.minimumLineSpacing = 4
        layout.minimumInteritemSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.backgroundColors = [.underPageBackgroundColor]
        collection.dataSource = self
        collection.delegate = self
        collection.register(ThumbnailItem.self, forItemWithIdentifier: stripItemID)

        view.documentView = collection
        view.hasHorizontalScroller = true
        view.autohidesScrollers = true
        view.borderType = .noBorder
    }

    /// Replaces the contents when the list changed (or always, with `force`, e.g. after a save).
    func reload(_ newURLs: [URL], selected: Int, force: Bool = false) {
        if force || newURLs != urls {
            if force { cache.removeAllObjects() }
            urls = newURLs
            collection.reloadData()
        }
        select(selected)
    }

    func select(_ index: Int) {
        guard urls.indices.contains(index) else { collection.selectionIndexPaths = []; return }
        let path = IndexPath(item: index, section: 0)
        guard collection.selectionIndexPaths != [path] else { return }
        collection.selectionIndexPaths = [path]
        collection.scrollToItems(at: [path], scrollPosition: .centeredHorizontally)
    }

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { urls.count }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: stripItemID, for: indexPath) as! ThumbnailItem
        let url = urls[indexPath.item]
        item.url = url
        item.textField?.stringValue = url.lastPathComponent
        item.textField?.font = .systemFont(ofSize: 10)
        item.view.toolTip = url.lastPathComponent
        if let img = cache.object(forKey: url as NSURL) {
            item.imageView?.image = img
        } else {
            item.imageView?.image = nil
            queue.addOperation { [weak self] in
                guard let cg = ImageIOSupport.thumbnail(url, maxPixel: 200) else { return }
                let img = NSImage(cgImage: cg, size: .zero)
                DispatchQueue.main.async {
                    self?.cache.setObject(img, forKey: url as NSURL)
                    if item.url == url { item.imageView?.image = img }
                }
            }
        }
        return item
    }

    /// Only user clicks / arrow keys get here; programmatic selection does not call the delegate.
    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if let i = indexPaths.first?.item { onSelect?(i) }
    }
}

/// Lets a regular mouse wheel scroll the strip sideways.
final class HorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { super.scrollWheel(with: event); return }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        var bounds = contentView.bounds
        bounds.origin.x -= step
        contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(contentView)
    }
}
