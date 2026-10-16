import AppKit
import UniformTypeIdentifiers

final class ViewerWindowController: NSWindowController, NSWindowDelegate, ImageViewDelegate, NSMenuItemValidation {
    let scrollView = NSScrollView()
    let imageView = ImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "Drop an image or folder here, or press ⌘O")

    private(set) var files: [URL] = []
    private(set) var index = 0
    private(set) var currentURL: URL?
    private var loaded: LoadedImage?
    private var image: CGImage?
    private var undoStack: [CGImage] = []
    private var dirty = false
    private var fitToWindow = true
    private var slideshowTimer: Timer?
    private var slideshowInterval: TimeInterval = 3
    private var prefetchCache: [URL: LoadedImage] = [:]

    private lazy var thumbnails = ThumbnailWindowController(viewer: self)
    private let splitView = NSSplitView()
    private let folderTree = FolderTree()
    private let filmStrip = FilmStrip()
    private let videoView = VideoPlayerView()
    private var showingVideo: Bool { !videoView.isHidden }
    private var videoFailed = false
    private let pdfViewer = PDFViewerView()
    private let textViewer = TextViewerView()
    private var showingPDF: Bool { !pdfViewer.isHidden }
    private var showingText: Bool { !textViewer.isHidden }
    private var showingDocument: Bool { showingPDF || showingText }
    private var filmStripHeight: NSLayoutConstraint!
    private var browserVisible: Bool { !folderTree.view.isHidden }
    private static let showTreeKey = "ShowFolderTree"

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "PixView"
        window.minSize = NSSize(width: 360, height: 240)
        window.collectionBehavior = [.fullScreenPrimary]
        window.center()
        window.setFrameAutosaveName("PixViewMain")
        super.init(window: window)
        window.delegate = self
        buildUI()
        updateStatus()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let window else { return }
        let container = DropContainerView()
        container.onDrop = { [weak self] urls in self?.open(urls: urls) }
        window.contentView = container

        scrollView.contentView = CenteringClipView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 40
        scrollView.backgroundColor = NSColor(white: 0.11, alpha: 1)
        scrollView.drawsBackground = true
        scrollView.documentView = imageView
        scrollView.postsFrameChangedNotifications = true
        imageView.delegate = self

        let statusBar = NSView()
        statusBar.wantsLayer = true
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.textColor = NSColor(white: 0.6, alpha: 1)
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3

        // Optional folder tree on the left, image area on the right.
        let mainArea = NSView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(folderTree.view)
        splitView.addArrangedSubview(mainArea)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)
        folderTree.onSelect = { [weak self] url in self?.showFolder(url) }
        folderTree.view.isHidden = !UserDefaults.standard.bool(forKey: Self.showTreeKey)

        filmStrip.onSelect = { [weak self] i in
            guard let self else { return }
            if i != self.index, self.confirmDiscardChanges() { self.show(at: i) } else { self.filmStrip.select(self.index) }
        }

        for v in [splitView, scrollView, statusBar, statusLabel, emptyLabel, filmStrip.view] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        container.addSubview(splitView)
        container.addSubview(statusBar)
        mainArea.addSubview(scrollView)
        mainArea.addSubview(filmStrip.view)
        mainArea.addSubview(videoView)
        for v in [pdfViewer, textViewer] as [NSView] {
            mainArea.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isHidden = true
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: mainArea.topAnchor),
                v.leadingAnchor.constraint(equalTo: mainArea.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: filmStrip.view.topAnchor),
            ])
        }
        pdfViewer.onChange = { [weak self] in self?.updateStatus() }
        mainArea.addSubview(emptyLabel)
        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.isHidden = true
        videoView.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        videoView.onDoubleClick = { [weak self] in self?.window?.toggleFullScreen(nil) }
        videoView.onFailed = { [weak self] error in
            guard let self, let url = self.currentURL else { return }
            self.videoView.unload()
            self.videoFailed = true
            self.emptyLabel.stringValue = "Can’t play “\(url.lastPathComponent)”\n"
                + "macOS doesn’t support this video format or codec."
            self.emptyLabel.isHidden = false
            self.updateStatus()
            // Let a slideshow move on instead of stalling on the broken file.
            if self.slideshowTimer != nil { self.show(at: self.index + 1) }
        }
        videoView.onFinished = { [weak self] in
            guard let self, self.slideshowTimer != nil else { return }
            self.show(at: self.index + 1)
        }
        statusBar.addSubview(statusLabel)
        filmStripHeight = filmStrip.view.heightAnchor.constraint(equalToConstant: 0)

        let treeWidth = folderTree.view.widthAnchor.constraint(equalToConstant: 240)
        treeWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: container.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            folderTree.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            treeWidth,
            mainArea.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            scrollView.topAnchor.constraint(equalTo: mainArea.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: mainArea.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: filmStrip.view.topAnchor),
            filmStrip.view.leadingAnchor.constraint(equalTo: mainArea.leadingAnchor),
            filmStrip.view.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor),
            filmStrip.view.bottomAnchor.constraint(equalTo: mainArea.bottomAnchor),
            filmStripHeight,
            videoView.topAnchor.constraint(equalTo: mainArea.topAnchor),
            videoView.leadingAnchor.constraint(equalTo: mainArea.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor),
            videoView.bottomAnchor.constraint(equalTo: filmStrip.view.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 22),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
            self?.fitToWindow = false
            self?.imageView.needsDisplay = true
            self?.updateStatus()
        }
        nc.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            guard let self, self.fitToWindow else { return }
            self.applyFit()
        }
        updateBrowserLayout()
        window.makeFirstResponder(imageView)
    }

    /// The folder tree and the thumbnail strip are shown and hidden together.
    private func updateBrowserLayout() {
        filmStrip.view.isHidden = !browserVisible
        filmStripHeight.constant = browserVisible ? FilmStrip.height : 0
        if browserVisible { filmStrip.reload(files, selected: index) }
    }

    // MARK: Opening & navigation

    func open(urls: [URL]) {
        guard let first = urls.first?.resolvingSymlinksInPath(), confirmDiscardChanges() else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
        if isDir.boolValue {
            guard loadFolder(first) else {
                showError("No images found", info: "“\(first.lastPathComponent)” doesn’t contain any supported image files.")
                return
            }
        } else if urls.count > 1 {
            files = urls.map { $0.resolvingSymlinksInPath() }
            show(at: 0)
        } else {
            files = ImageIOSupport.listImages(in: first.deletingLastPathComponent())
            if let i = files.firstIndex(of: first) {
                show(at: i)
            } else {
                files.insert(first, at: 0)
                show(at: 0)
            }
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(first)
        showWindow(nil)
        if thumbnails.window?.isVisible == true { thumbnails.reload() }
    }

    /// Shows the first image of `folder`. Returns false (and changes nothing) if it has no images.
    @discardableResult
    private func loadFolder(_ folder: URL) -> Bool {
        let list = ImageIOSupport.listImages(in: folder)
        guard !list.isEmpty else { return false }
        files = list
        show(at: 0)
        return true
    }

    /// Called when a folder is picked in the folder tree.
    private func showFolder(_ folder: URL) {
        guard confirmDiscardChanges() else { return }
        if !loadFolder(folder) {
            clearImage()
            emptyLabel.stringValue = "No pictures, videos or documents in “\(FileManager.default.displayName(atPath: folder.path))”"
            window?.title = FileManager.default.displayName(atPath: folder.path)
        }
        if thumbnails.window?.isVisible == true { thumbnails.reload() }
    }

    @objc func toggleFolderTree(_ sender: Any?) {
        let show = folderTree.view.isHidden
        folderTree.view.isHidden = !show
        splitView.adjustSubviews()
        updateBrowserLayout()
        UserDefaults.standard.set(show, forKey: Self.showTreeKey)
        if show, let folder = currentURL?.deletingLastPathComponent() { folderTree.reveal(folder) }
    }

    func show(at i: Int) {
        guard !files.isEmpty else { clearImage(); return }
        index = ((i % files.count) + files.count) % files.count
        let url = files[index]
        if browserVisible {
            folderTree.reveal(url.deletingLastPathComponent())
            filmStrip.reload(files, selected: index)
        }
        let isVideo = VideoSupport.isVideo(url), isPDF = DocumentSupport.isPDF(url), isText = DocumentSupport.isText(url)
        hideNonImageViews()
        if isVideo || isPDF || isText {
            currentURL = url
            loaded = nil
            undoStack = []
            dirty = false
            window?.representedURL = url
            display(nil, resetZoom: true)
            if isVideo { showVideo(url) } else if isPDF { showPDF(url) } else { showText(url) }
            prefetch()
            thumbnails.select(index: index)
            return
        }
        let li = prefetchCache[url] ?? ImageIOSupport.load(url)
        currentURL = url
        loaded = li
        undoStack = []
        dirty = false
        window?.representedURL = url
        if let li {
            display(li.image, resetZoom: true)
        } else {
            display(nil, resetZoom: true)
            emptyLabel.stringValue = "Cannot open “\(url.lastPathComponent)”"
            emptyLabel.isHidden = false
        }
        prefetch()
        thumbnails.select(index: index)
    }

    private func showVideo(_ url: URL) {
        emptyLabel.isHidden = true
        scrollView.isHidden = true
        videoView.isHidden = false
        videoFailed = false
        videoView.load(url, autoplay: true)
        focusContent(videoView)
        updateStatus()
        // Size and duration are known once the item has loaded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.updateStatus() }
    }

    private func showPDF(_ url: URL) {
        scrollView.isHidden = true
        pdfViewer.isHidden = false
        if pdfViewer.load(url) {
            emptyLabel.isHidden = true
            focusContent(pdfViewer.pdfView)
        } else {
            pdfViewer.isHidden = true
            scrollView.isHidden = false
            emptyLabel.stringValue = "Can’t open “\(url.lastPathComponent)”\nThe PDF is damaged or locked."
            emptyLabel.isHidden = false
        }
        updateStatus()
    }

    private func showText(_ url: URL) {
        scrollView.isHidden = true
        textViewer.isHidden = false
        do {
            try textViewer.load(url)
            emptyLabel.isHidden = true
            focusContent(textViewer.textView)
        } catch {
            textViewer.isHidden = true
            scrollView.isHidden = false
            emptyLabel.stringValue = "Can’t open “\(url.lastPathComponent)”\n\(error.localizedDescription)"
            emptyLabel.isHidden = false
        }
        updateStatus()
    }

    /// Moves keyboard focus to the visible viewer, unless the user is working in the tree or strip.
    private func focusContent(_ view: NSView) {
        let fr = window?.firstResponder as? NSView
        let inMainArea = fr == nil || fr === window?.contentView || fr === imageView || fr === videoView
            || fr!.isDescendant(of: pdfViewer) || fr!.isDescendant(of: textViewer)
        if inMainArea { window?.makeFirstResponder(view) }
    }

    /// Hides the video, PDF and text viewers and goes back to the image view.
    private func hideNonImageViews() {
        let hadFocus = (window?.firstResponder as? NSView).map {
            $0 === videoView || $0.isDescendant(of: pdfViewer) || $0.isDescendant(of: textViewer)
        } ?? false
        if showingVideo { videoView.unload(); videoView.isHidden = true }
        if showingPDF { pdfViewer.unload(); pdfViewer.isHidden = true }
        if showingText { textViewer.unload(); textViewer.isHidden = true }
        scrollView.isHidden = false
        if hadFocus { window?.makeFirstResponder(imageView) }
    }

    private func clearImage() {
        hideNonImageViews()
        files = []
        currentURL = nil
        loaded = nil
        undoStack = []
        dirty = false
        window?.representedURL = nil
        display(nil, resetZoom: true)
        if browserVisible { filmStrip.reload([], selected: 0) }
    }

    /// Re-reads strip thumbnails after the files on disk changed (save, rename, trash).
    private func refreshFilmStrip() {
        if browserVisible { filmStrip.reload(files, selected: index, force: true) }
    }

    private func prefetch() {
        guard files.count > 1 else { prefetchCache = [:]; return }
        let next = files[(index + 1) % files.count]
        guard !VideoSupport.isVideo(next), !DocumentSupport.isDocument(next) else { return }
        let prev = files[(index - 1 + files.count) % files.count]
        let keep: Set<URL> = [files[index], next, prev]
        prefetchCache = prefetchCache.filter { keep.contains($0.key) }
        guard prefetchCache[next] == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let li = ImageIOSupport.load(next) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.files.contains(next) else { return }
                self.prefetchCache[next] = li
            }
        }
    }

    private func navigate(to i: Int) {
        guard files.count > 1, confirmDiscardChanges() else { return }
        show(at: i)
    }

    @objc func nextImage(_ sender: Any?) { navigate(to: index + 1) }
    @objc func previousImage(_ sender: Any?) { navigate(to: index - 1) }
    @objc func firstImage(_ sender: Any?) { navigate(to: 0) }
    @objc func lastImage(_ sender: Any?) { navigate(to: files.count - 1) }

    // MARK: Display & zoom

    private func display(_ img: CGImage?, resetZoom: Bool) {
        image = img
        imageView.image = img
        imageView.selection = nil
        emptyLabel.isHidden = img != nil
        emptyLabel.stringValue = "Drop an image or folder here, or press ⌘O"
        if let img {
            let scale = window?.backingScaleFactor ?? 2
            imageView.frame = NSRect(x: 0, y: 0, width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
            if resetZoom { fitToWindow = true }
            if fitToWindow { applyFit() }
        } else {
            imageView.frame = .zero
        }
        updateStatus()
    }

    private func applyFit() {
        guard image != nil, imageView.frame.width > 0, imageView.frame.height > 0 else { return }
        let avail = scrollView.contentSize
        let doc = imageView.frame.size
        scrollView.magnification = min(avail.width / doc.width, avail.height / doc.height, 1)
        imageView.needsDisplay = true
        updateStatus()
    }

    private func zoom(by factor: CGFloat, at point: NSPoint? = nil) {
        guard image != nil else { return }
        fitToWindow = false
        let clip = scrollView.contentView.bounds
        let center = point ?? NSPoint(x: clip.midX, y: clip.midY)
        let m = min(max(scrollView.magnification * factor, scrollView.minMagnification), scrollView.maxMagnification)
        scrollView.setMagnification(m, centeredAt: center)
        imageView.needsDisplay = true
        updateStatus()
    }

    @objc func zoomIn(_ sender: Any?) {
        if showingPDF { pdfViewer.zoomIn() } else if showingText { textViewer.larger() } else { zoom(by: 1.25) }
    }

    @objc func zoomOut(_ sender: Any?) {
        if showingPDF { pdfViewer.zoomOut() } else if showingText { textViewer.smaller() } else { zoom(by: 0.8) }
    }

    @objc func actualSize(_ sender: Any?) {
        if showingPDF { pdfViewer.actualSize(); return }
        if showingText { textViewer.resetFontSize(); return }
        guard image != nil else { return }
        fitToWindow = false
        let clip = scrollView.contentView.bounds
        scrollView.setMagnification(1, centeredAt: NSPoint(x: clip.midX, y: clip.midY))
        imageView.needsDisplay = true
        updateStatus()
    }

    @objc func fitWindow(_ sender: Any?) {
        if showingPDF { pdfViewer.fit(); return }
        fitToWindow = true
        applyFit()
    }

    private func updateStatus() {
        let name = currentURL?.lastPathComponent ?? (image != nil ? "Clipboard image" : "PixView")
        window?.title = name + (dirty ? " — Edited" : "")
        window?.subtitle = files.count > 1 ? "\(index + 1) / \(files.count)" : ""

        if showingDocument {
            var parts: [String] = []
            if files.count > 1 { parts.append("\(index + 1)/\(files.count)") }
            if showingPDF {
                parts.append("PDF · page \(pdfViewer.currentPage) of \(pdfViewer.pageCount)")
                parts.append("\(pdfViewer.zoomPercent)%")
            } else if let f = textViewer.file {
                parts.append("Text · \(String.localizedName(of: f.encoding))" + (f.truncated ? " · truncated" : ""))
            }
            if let url = currentURL, let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            }
            if slideshowTimer != nil { parts.append("Slideshow") }
            statusLabel.stringValue = parts.joined(separator: "   |   ")
            return
        }
        if showingVideo {
            var parts: [String] = []
            if files.count > 1 { parts.append("\(index + 1)/\(files.count)") }
            let size = videoView.presentationSize
            if videoFailed {
                parts.append("Unsupported video format")
            } else {
                parts.append(size.width > 0 ? "\(Int(size.width)) × \(Int(size.height)) video" : "Video")
            }
            if videoView.duration > 0 { parts.append(VideoSupport.formatTime(videoView.duration)) }
            if let url = currentURL, let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            }
            if slideshowTimer != nil { parts.append("Slideshow") }
            statusLabel.stringValue = parts.joined(separator: "   |   ")
            return
        }
        guard let img = image else { statusLabel.stringValue = ""; return }
        var parts = ["\(img.width) × \(img.height) × \(img.bitsPerPixel) BPP",
                     "\(Int((scrollView.magnification * 100).rounded()))%" + (fitToWindow ? " (fit)" : "")]
        if files.count > 1 { parts.insert("\(index + 1)/\(files.count)", at: 0) }
        if let url = currentURL,
           let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let n = loaded?.frameCount, n > 1 { parts.append("frame 1 of \(n)") }
        if let sel = imageView.selection {
            parts.append("Selection: \(Int(sel.minX)),\(Int(sel.minY)) \(Int(sel.width))×\(Int(sel.height))")
        }
        if dirty { parts.append("Modified") }
        if slideshowTimer != nil { parts.append("Slideshow \(Int(slideshowInterval))s") }
        statusLabel.stringValue = parts.joined(separator: "   |   ")
    }

    // MARK: ImageViewDelegate

    func imageViewSelectionChanged(_ view: ImageView) { updateStatus() }

    func imageViewDoubleClicked(_ view: ImageView) { window?.toggleFullScreen(nil) }

    func imageView(_ view: ImageView, zoomBy factor: CGFloat, at point: NSPoint) { zoom(by: factor, at: point) }

    /// Single-key shortcuts modelled on classic Windows image viewers.
    func imageView(_ view: ImageView, handleKey event: NSEvent) -> Bool { handleKey(event) }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if event.keyCode == 53 { // Escape
            if slideshowTimer != nil { stopSlideshow() }
            else if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
            else { imageView.selection = nil }
            return true
        }
        if showingVideo {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ", "k": videoView.togglePlay(); return true
            case "m": videoView.toggleMute(); return true
            case ",": videoView.skip(by: -10); return true
            case ".": videoView.skip(by: 10); return true
            default: break
            }
        }
        if let special = event.specialKey {
            switch special {
            case .rightArrow, .downArrow, .pageDown: nextImage(nil)
            case .leftArrow, .upArrow, .pageUp, .delete: previousImage(nil)
            case .home: firstImage(nil)
            case .end: lastImage(nil)
            case .deleteForward: moveToTrash(nil)
            case .carriageReturn, .enter: window?.toggleFullScreen(nil)
            default: return false
            }
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": nextImage(nil)
        case "+", "=": zoomIn(nil)
        case "-", "_": zoomOut(nil)
        case "f": fitWindow(nil)
        case "1": actualSize(nil)
        case "l": rotateLeft(nil)
        case "r": rotateRight(nil)
        case "h": flipHorizontal(nil)
        case "v": flipVertical(nil)
        case "i": showInfo(nil)
        case "t": showThumbnails(nil)
        case "b": toggleFolderTree(nil)
        case "w": toggleSlideshow(nil)
        case "g": grayscale(nil)
        case "s": saveDocumentAs(nil)
        default: return false
        }
        return true
    }

    // MARK: Editing

    private func apply(_ op: (CGImage) -> CGImage?) {
        guard let img = image, let out = op(img) else { NSSound.beep(); return }
        undoStack.append(img)
        if undoStack.count > 20 { undoStack.removeFirst() }
        dirty = true
        display(out, resetZoom: false)
    }

    @objc func undoEdit(_ sender: Any?) {
        guard let prev = undoStack.popLast() else { NSSound.beep(); return }
        dirty = !undoStack.isEmpty
        display(prev, resetZoom: false)
    }

    @objc func rotateLeft(_ sender: Any?) { apply { ImageOps.rotate($0, clockwise: false) } }
    @objc func rotateRight(_ sender: Any?) { apply { ImageOps.rotate($0, clockwise: true) } }
    @objc func flipHorizontal(_ sender: Any?) { apply { ImageOps.flip($0, horizontal: true) } }
    @objc func flipVertical(_ sender: Any?) { apply { ImageOps.flip($0, horizontal: false) } }
    @objc func grayscale(_ sender: Any?) { apply(ImageOps.grayscale) }
    @objc func negative(_ sender: Any?) { apply(ImageOps.negative) }
    @objc func autoAdjust(_ sender: Any?) { apply(ImageOps.autoAdjust) }
    @objc func sharpen(_ sender: Any?) { apply(ImageOps.sharpen) }
    @objc func blur(_ sender: Any?) { apply(ImageOps.blur) }

    @objc func cropToSelection(_ sender: Any?) {
        guard let sel = imageView.selection else { NSSound.beep(); return }
        apply { ImageOps.crop($0, to: sel) }
    }

    @objc func selectAllPixels(_ sender: Any?) {
        if showingDocument { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: sender); return }
        guard let img = image else { return }
        imageView.selection = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    }

    @objc func deselect(_ sender: Any?) { imageView.selection = nil }

    @objc func resizeImage(_ sender: Any?) {
        guard let img = image else { return }
        let dialog = ResizeDialog(width: img.width, height: img.height)
        guard let size = dialog.run() else { return }
        apply { ImageOps.resize($0, width: size.width, height: size.height) }
    }

    @objc func colorCorrections(_ sender: Any?) {
        guard let img = image else { return }
        let preview = ImageOps.downscaled(img, maxSide: 1600)
        let dialog = ColorDialog { [weak self] params in
            self?.imageView.image = ImageOps.colorAdjust(preview, params) ?? preview
        }
        let result = dialog.run()
        imageView.image = img
        if let result { apply { ImageOps.colorAdjust($0, result) } }
    }

    // MARK: Clipboard

    @objc func copyImage(_ sender: Any?) {
        // Copy selected text from the PDF or text viewer.
        if showingDocument { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: sender); return }
        guard let img = image else { return }
        let out = imageView.selection.flatMap { ImageOps.crop(img, to: $0) } ?? img
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: out, size: .zero)])
    }

    @objc func pasteImage(_ sender: Any?) {
        guard let data = NSPasteboard.general.data(forType: .tiff) ?? NSPasteboard.general.data(forType: .png),
              let cg = NSBitmapImageRep(data: data)?.cgImage else { NSSound.beep(); return }
        guard confirmDiscardChanges() else { return }
        clearImage()
        dirty = true
        display(cg, resetZoom: true)
    }

    // MARK: File operations

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie, .pdf, .text]
        panel.directoryURL = currentURL?.deletingLastPathComponent()
        if panel.runModal() == .OK { open(urls: panel.urls) }
    }

    private var currentFormat: SaveFormat? {
        guard let id = loaded?.typeIdentifier else { return nil }
        return ImageIOSupport.saveFormats.first { $0.type.identifier == id }
    }

    @objc func saveDocument(_ sender: Any?) { _ = save() }
    @objc func saveDocumentAs(_ sender: Any?) { _ = saveAs() }

    private func save() -> Bool {
        guard let img = image else { return false }
        guard let url = currentURL, let format = currentFormat else { return saveAs() }
        do {
            try ImageIOSupport.save(img, to: url, format: format, quality: 0.92, metadata: loaded?.properties ?? [:])
        } catch {
            showError("Could not save “\(url.lastPathComponent)”", info: error.localizedDescription)
            return false
        }
        prefetchCache[url] = nil
        dirty = false
        updateStatus()
        thumbnails.reload()
        refreshFilmStrip()
        return true
    }

    private func saveAs() -> Bool {
        guard let img = image else { return false }
        let formats = ImageIOSupport.saveFormats
        let initial = formats.firstIndex { $0.type.identifier == currentFormat?.type.identifier } ?? 0
        let panel = NSSavePanel()
        let accessory = SaveAccessory(formats: formats, initial: initial, panel: panel)
        panel.accessoryView = accessory.view
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        let base = currentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        panel.nameFieldStringValue = base + "." + (formats[initial].type.preferredFilenameExtension ?? "jpg")
        if let dir = currentURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url?.resolvingSymlinksInPath() else { return false }

        do {
            try ImageIOSupport.save(img, to: url, format: accessory.selected, quality: accessory.quality,
                                    metadata: loaded?.properties ?? [:])
        } catch {
            showError("Could not save “\(url.lastPathComponent)”", info: error.localizedDescription)
            return false
        }
        prefetchCache[url] = nil
        // Continue browsing from the saved file's folder.
        files = ImageIOSupport.listImages(in: url.deletingLastPathComponent())
        if let i = files.firstIndex(of: url) {
            index = i
        } else {
            files.insert(url, at: 0)
            index = 0
        }
        currentURL = url
        window?.representedURL = url
        loaded = ImageIOSupport.load(url).map {
            LoadedImage(image: img, properties: $0.properties, typeIdentifier: $0.typeIdentifier, frameCount: 1)
        } ?? loaded
        dirty = false
        updateStatus()
        thumbnails.reload()
        refreshFilmStrip()
        return true
    }

    /// Returns false if the user cancelled.
    func confirmDiscardChanges() -> Bool {
        guard dirty, image != nil else { return true }
        stopSlideshow()
        let a = NSAlert()
        a.messageText = "Save changes to “\(currentURL?.lastPathComponent ?? "Untitled")”?"
        a.informativeText = "Your edits will be lost if you don’t save them."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Don’t Save")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: dirty = false; return true
        default: return false
        }
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard let url = currentURL, files.indices.contains(index) else { NSSound.beep(); return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            showError("Could not move “\(url.lastPathComponent)” to the Trash", info: error.localizedDescription)
            return
        }
        prefetchCache[url] = nil
        files.remove(at: index)
        dirty = false
        if files.isEmpty { clearImage() } else { show(at: min(index, files.count - 1)) }
        thumbnails.reload()
        refreshFilmStrip()
    }

    @objc func renameFile(_ sender: Any?) {
        guard let url = currentURL else { NSSound.beep(); return }
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        let a = NSAlert()
        a.messageText = "Rename File"
        a.accessoryView = field
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != url.lastPathComponent, !name.contains("/") else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            showError("Could not rename the file", info: error.localizedDescription)
            return
        }
        prefetchCache[url] = nil
        files[index] = dest
        currentURL = dest
        window?.representedURL = dest
        updateStatus()
        thumbnails.reload()
        refreshFilmStrip()
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func printImage(_ sender: Any?) {
        if showingPDF { pdfViewer.pdfView.print(with: NSPrintInfo.shared, autoRotate: true); return }
        if showingText, let window {
            NSPrintOperation(view: textViewer.textView).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            return
        }
        guard let img = image, let window else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.orientation = img.width > img.height ? .landscape : .portrait
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        let iv = NSImageView(frame: NSRect(origin: .zero, size: info.imageablePageBounds.size))
        iv.image = NSImage(cgImage: img, size: .zero)
        iv.imageScaling = .scaleProportionallyUpOrDown
        NSPrintOperation(view: iv, printInfo: info).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func showInfo(_ sender: Any?) {
        if showingVideo, let url = currentURL { showVideoInfo(url); return }
        if showingDocument, let url = currentURL {
            var rows: [(String, String)] = [("File", url.lastPathComponent), ("Folder", url.deletingLastPathComponent().path)]
            if let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                if let s = rv.fileSize { rows.append(("File size", ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file))) }
                if let d = rv.contentModificationDate { rows.append(("Modified", d.formatted(date: .abbreviated, time: .standard))) }
            }
            if showingPDF, let doc = pdfViewer.pdfView.document { rows += DocumentSupport.pdfInfo(doc) }
            if showingText, let f = textViewer.file { rows += DocumentSupport.textInfo(f) }
            let width = rows.map(\.0.count).max() ?? 0
            let text = rows.map { $0.0.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n")
            showTextPanel(title: showingPDF ? "PDF Information" : "Text File Information", text: text)
            return
        }
        guard let img = image else { NSSound.beep(); return }
        var rows: [(String, String)] = []
        if let url = currentURL {
            rows.append(("File", url.lastPathComponent))
            rows.append(("Folder", url.deletingLastPathComponent().path))
            if let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                if let s = rv.fileSize { rows.append(("File size", ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file) + " (\(s) bytes)")) }
                if let d = rv.contentModificationDate { rows.append(("Modified", d.formatted(date: .abbreviated, time: .standard))) }
            }
        }
        if let id = loaded?.typeIdentifier, let t = UTType(id) {
            rows.append(("Format", t.localizedDescription ?? id))
        }
        let mp = Double(img.width * img.height) / 1_000_000
        rows.append(("Dimensions", "\(img.width) × \(img.height) pixels (\(String(format: "%.2f", mp)) MP)"))
        rows.append(("Bits per pixel", "\(img.bitsPerPixel)"))
        if let n = loaded?.frameCount, n > 1 { rows.append(("Frames/pages", "\(n)")) }

        let p = loaded?.properties ?? [:]
        if let dpi = p[kCGImagePropertyDPIWidth] as? Double { rows.append(("Resolution", "\(Int(dpi)) DPI")) }
        if let model = p[kCGImagePropertyColorModel] as? String { rows.append(("Color model", model)) }
        if let profile = p[kCGImagePropertyProfileName] as? String { rows.append(("Color profile", profile)) }
        if let depth = p[kCGImagePropertyDepth] as? Int { rows.append(("Bits per channel", "\(depth)")) }
        if let o = p[kCGImagePropertyOrientation] as? Int, o != 1 { rows.append(("EXIF orientation", "\(o) (applied)")) }

        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        if !camera.isEmpty { rows.append(("Camera", camera)) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { rows.append(("Lens", lens)) }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String { rows.append(("Date taken", date)) }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            rows.append(("Exposure", t < 1 ? "1/\(Int((1 / t).rounded())) s" : String(format: "%.1f s", t)))
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { rows.append(("Aperture", String(format: "f/%.1f", f))) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { rows.append(("ISO", "\(iso)")) }
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double { rows.append(("Focal length", String(format: "%.0f mm", fl))) }
        if let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let ns = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let ew = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            rows.append(("GPS", String(format: "%.6f° %@, %.6f° %@", lat, ns, lon, ew)))
        }

        let width = rows.map(\.0.count).max() ?? 0
        let text = rows.map { $0.0.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n")
        showTextPanel(title: "Image Information", text: text)
    }

    private func showVideoInfo(_ url: URL) {
        Task { @MainActor in
            var rows: [(String, String)] = [("File", url.lastPathComponent), ("Folder", url.deletingLastPathComponent().path)]
            if let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                if let s = rv.fileSize { rows.append(("File size", ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file))) }
                if let d = rv.contentModificationDate { rows.append(("Modified", d.formatted(date: .abbreviated, time: .standard))) }
            }
            rows += await VideoSupport.info(url)
            let width = rows.map(\.0.count).max() ?? 0
            let text = rows.map { $0.0.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n")
            showTextPanel(title: "Video Information", text: text)
        }
    }

    // MARK: Thumbnails & slideshow

    @objc func showThumbnails(_ sender: Any?) {
        if files.isEmpty {
            openDocument(nil)
            if files.isEmpty { return }
        }
        thumbnails.showWindow(nil)
        thumbnails.reload()
        refreshFilmStrip()
    }

    @objc func toggleSlideshow(_ sender: Any?) {
        if slideshowTimer != nil { stopSlideshow(); return }
        guard files.count > 1, confirmDiscardChanges() else { NSSound.beep(); return }
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: slideshowInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.dirty { self.stopSlideshow(); return }
            if self.showingVideo && self.videoView.isPlaying { return } // advance when it finishes
            self.show(at: self.index + 1)
        }
        updateStatus()
    }

    @objc func setSlideshowInterval(_ sender: NSMenuItem) {
        slideshowInterval = TimeInterval(sender.tag)
        if slideshowTimer != nil {
            stopSlideshow()
            toggleSlideshow(nil)
        }
    }

    private func stopSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        updateStatus()
    }

    // MARK: NSWindowDelegate / validation

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscardChanges() }

    func windowWillClose(_ notification: Notification) {
        stopSlideshow()
        videoView.unload()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        if let img = image { display(img, resetZoom: false) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasImage = image != nil
        switch item.action {
        case #selector(nextImage(_:)), #selector(previousImage(_:)), #selector(firstImage(_:)), #selector(lastImage(_:)):
            return files.count > 1
        case #selector(cropToSelection(_:)), #selector(deselect(_:)):
            return imageView.selection != nil
        case #selector(undoEdit(_:)):
            return !undoStack.isEmpty
        case #selector(moveToTrash(_:)), #selector(renameFile(_:)), #selector(revealInFinder(_:)):
            return currentURL != nil
        case #selector(pasteImage(_:)):
            return NSPasteboard.general.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.tiff.rawValue,
                                                                                NSPasteboard.PasteboardType.png.rawValue])
        case #selector(toggleSlideshow(_:)):
            item.title = slideshowTimer == nil ? "Start Slideshow" : "Stop Slideshow"
            return files.count > 1 || slideshowTimer != nil
        case #selector(setSlideshowInterval(_:)):
            item.state = TimeInterval(item.tag) == slideshowInterval ? .on : .off
            return true
        case #selector(fitWindow(_:)):
            item.state = fitToWindow && !showingDocument ? .on : .off
            return hasImage || showingPDF
        case #selector(toggleFolderTree(_:)):
            item.title = folderTree.view.isHidden ? "Show Folder Tree" : "Hide Folder Tree"
            return true
        case #selector(showInfo(_:)):
            return hasImage || showingVideo || showingDocument
        case #selector(copyImage(_:)), #selector(selectAllPixels(_:)), #selector(printImage(_:)),
             #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualSize(_:)):
            return hasImage || showingDocument
        case #selector(openDocument(_:)), #selector(showThumbnails(_:)):
            return true
        default:
            return hasImage
        }
    }
}
