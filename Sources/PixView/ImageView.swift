import AppKit

protocol ImageViewDelegate: AnyObject {
    func imageView(_ view: ImageView, handleKey event: NSEvent) -> Bool
    func imageViewSelectionChanged(_ view: ImageView)
    func imageViewDoubleClicked(_ view: ImageView)
    func imageView(_ view: ImageView, zoomBy factor: CGFloat, at point: NSPoint)
}

/// Document view of the scroll view. Draws the image stretched to its bounds; zoom is the
/// scroll view's magnification. Drag = rectangular selection, Option-drag or right-drag = pan.
final class ImageView: NSView {
    weak var delegate: ImageViewDelegate?

    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    /// Selection in image pixel coordinates (top-left origin).
    var selection: CGRect? {
        didSet {
            needsDisplay = true
            delegate?.imageViewSelectionChanged(self)
        }
    }

    private var dragStart: CGPoint?
    private var panStart: (mouse: NSPoint, origin: NSPoint)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var pixelsPerPoint: CGFloat {
        guard let image, bounds.width > 0 else { return 1 }
        return CGFloat(image.width) / bounds.width
    }

    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.interpolationQuality = magnification >= 3 ? .none : .high
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: bounds)
        ctx.restoreGState()

        if let sel = selection {
            let s = 1 / pixelsPerPoint
            let path = NSBezierPath(rect: NSRect(x: sel.minX * s, y: sel.minY * s, width: sel.width * s, height: sel.height * s))
            path.lineWidth = 1 / magnification
            NSColor.black.setStroke()
            path.stroke()
            path.setLineDash([4 / magnification, 4 / magnification], count: 2, phase: 0)
            NSColor.white.setStroke()
            path.stroke()
        }
    }

    private func pixelPoint(for event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let ppp = pixelsPerPoint
        let w = CGFloat(image?.width ?? 0), h = CGFloat(image?.height ?? 0)
        return CGPoint(x: min(max(p.x * ppp, 0), w), y: min(max(p.y * ppp, 0), h))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.option) { beginPan(event); return }
        if event.clickCount == 2 { delegate?.imageViewDoubleClicked(self); return }
        guard image != nil else { return }
        dragStart = pixelPoint(for: event)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        if panStart != nil { continuePan(event); return }
        guard let start = dragStart else { return }
        let cur = pixelPoint(for: event)
        let r = CGRect(x: min(start.x, cur.x), y: min(start.y, cur.y),
                       width: abs(cur.x - start.x), height: abs(cur.y - start.y)).integral
        selection = (r.width >= 2 && r.height >= 2) ? r : nil
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        endPan()
        dragStart = nil
    }

    override func rightMouseDown(with event: NSEvent) { beginPan(event) }
    override func rightMouseDragged(with event: NSEvent) { continuePan(event) }
    override func rightMouseUp(with event: NSEvent) { endPan() }

    private func beginPan(_ event: NSEvent) {
        guard let clip = enclosingScrollView?.contentView else { return }
        panStart = (event.locationInWindow, clip.bounds.origin)
        NSCursor.closedHand.push()
    }

    private func continuePan(_ event: NSEvent) {
        guard let start = panStart, let sv = enclosingScrollView else { return }
        let dx = (event.locationInWindow.x - start.mouse.x) / sv.magnification
        let dy = (event.locationInWindow.y - start.mouse.y) / sv.magnification
        let clip = sv.contentView
        let proposed = NSRect(origin: NSPoint(x: start.origin.x - dx, y: start.origin.y + dy), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        sv.reflectScrolledClipView(clip)
    }

    private func endPan() {
        if panStart != nil { NSCursor.pop() }
        panStart = nil
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.scrollingDeltaY != 0 {
            let factor: CGFloat = event.scrollingDeltaY > 0 ? 1.1 : 1 / 1.1
            delegate?.imageView(self, zoomBy: factor, at: convert(event.locationInWindow, from: nil))
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if delegate?.imageView(self, handleKey: event) != true { super.keyDown(with: event) }
    }
}

/// Keeps the document centered when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Window content view that accepts dropped files and folders.
final class DropContainerView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func urls(from info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let list = urls(from: sender)
        guard !list.isEmpty else { return false }
        onDrop?(list)
        return true
    }
}
