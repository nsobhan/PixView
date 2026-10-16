import AppKit
import PDFKit
import QuickLookThumbnailing

enum DocumentSupport {
    static let pdfExtensions: Set<String> = ["pdf"]
    static let textExtensions: Set<String> = [
        "txt", "text", "log", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "ini", "cfg", "conf",
    ]
    /// Text files larger than this are shown truncated.
    static let maxTextBytes = 10 * 1024 * 1024

    static func isPDF(_ url: URL) -> Bool { pdfExtensions.contains(url.pathExtension.lowercased()) }
    static func isText(_ url: URL) -> Bool { textExtensions.contains(url.pathExtension.lowercased()) }
    static func isDocument(_ url: URL) -> Bool { isPDF(url) || isText(url) }

    /// Quick Look thumbnail (first PDF page / text preview), falling back to the file icon.
    static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: maxPixel, height: maxPixel),
                                                   scale: 1, representationTypes: .all)
        let done = DispatchSemaphore(value: 0)
        var result: CGImage?
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            result = rep?.cgImage
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        return result
    }

    // MARK: Text

    struct TextFile {
        let string: String
        let encoding: String.Encoding
        let truncated: Bool
    }

    static func readText(_ url: URL) throws -> TextFile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = try handle.read(upToCount: maxTextBytes + 1) ?? Data()
        let truncated = data.count > maxTextBytes
        if truncated { data = data.prefix(maxTextBytes) }

        // UTF-8 first (trimming a character cut in half by truncation), then let Foundation guess.
        for trim in 0...(truncated ? 3 : 0) {
            if let s = String(data: data.dropLast(trim), encoding: .utf8) {
                return TextFile(string: s, encoding: .utf8, truncated: truncated)
            }
        }
        var converted: NSString?
        var lossy: ObjCBool = false
        let raw = NSString.stringEncoding(for: data, encodingOptions: [.allowLossyKey: true],
                                          convertedString: &converted, usedLossyConversion: &lossy)
        if raw != 0, let converted {
            return TextFile(string: converted as String, encoding: String.Encoding(rawValue: raw), truncated: truncated)
        }
        return TextFile(string: String(decoding: data, as: UTF8.self), encoding: .utf8, truncated: truncated)
    }

    static func textInfo(_ file: TextFile) -> [(String, String)] {
        let s = file.string
        let newlines = s.utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        let lines = s.isEmpty ? 0 : newlines + (s.utf8.last == 10 ? 0 : 1)
        var rows: [(String, String)] = [
            ("Encoding", String.localizedName(of: file.encoding)),
            ("Lines", lines.formatted()),
            ("Characters", s.count.formatted()),
            ("Line endings", s.contains("\r\n") ? "Windows (CRLF)" : s.contains("\r") ? "Classic Mac (CR)" : "Unix (LF)"),
        ]
        if file.truncated { rows.append(("Note", "Only the first \(maxTextBytes / 1024 / 1024) MB is shown")) }
        return rows
    }

    // MARK: PDF

    static func pdfInfo(_ doc: PDFDocument) -> [(String, String)] {
        var rows: [(String, String)] = [("Pages", "\(doc.pageCount)")]
        if let page = doc.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            rows.append(("Page size", String(format: "%.0f × %.0f pt (%.1f × %.1f in, %.0f × %.0f mm)",
                                             box.width, box.height, box.width / 72, box.height / 72,
                                             box.width / 72 * 25.4, box.height / 72 * 25.4)))
        }
        let attrs = doc.documentAttributes ?? [:]
        let fields: [(PDFDocumentAttribute, String)] = [
            (.titleAttribute, "Title"), (.authorAttribute, "Author"), (.subjectAttribute, "Subject"),
            (.creatorAttribute, "Created with"), (.producerAttribute, "Producer"),
        ]
        for (key, name) in fields {
            if let v = attrs[key] as? String, !v.isEmpty { rows.append((name, v)) }
        }
        if let d = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date {
            rows.append(("Created", d.formatted(date: .abbreviated, time: .shortened)))
        }
        rows.append(("PDF version", "\(doc.majorVersion).\(doc.minorVersion)"))
        rows.append(("Encrypted", doc.isEncrypted ? "yes" : "no"))
        return rows
    }
}

// MARK: - PDF viewer

final class PDFViewerView: NSView {
    let pdfView = PDFView()
    private let pageLabel = NSTextField(labelWithString: "")
    private lazy var continuousButton = NSButton(checkboxWithTitle: "Continuous", target: self, action: #selector(toggleContinuous))
    var onChange: (() -> Void)?

    var currentPage: Int {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return 0 }
        return doc.index(for: page) + 1
    }
    var pageCount: Int { pdfView.document?.pageCount ?? 0 }
    var zoomPercent: Int { Int((pdfView.scaleFactor * 100).rounded()) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = NSColor(white: 0.11, alpha: 1)
        continuousButton.state = .on
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            return b
        }
        let stack = NSStackView(views: [
            button("chevron.left", "Previous page", #selector(previousPage)),
            button("chevron.right", "Next page", #selector(nextPage)),
            pageLabel,
            NSView(),
            continuousButton,
            button("minus.magnifyingglass", "Zoom out", #selector(zoomOut)),
            button("plus.magnifyingglass", "Zoom in", #selector(zoomIn)),
            button("arrow.up.left.and.arrow.down.right", "Fit to window", #selector(fit)),
        ])
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        let bar = NSVisualEffectView()
        bar.material = .titlebar

        for v in [bar, stack, pdfView] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(bar)
        bar.addSubview(stack)
        addSubview(pdfView)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 36),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            pdfView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let nc = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged] {
            nc.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in self?.updateLabel() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Returns false if the file is not a readable PDF (or the user cancelled the password).
    func load(_ url: URL) -> Bool {
        guard let doc = PDFDocument(url: url) else { return false }
        if doc.isLocked, !unlock(doc, name: url.lastPathComponent) { return false }
        pdfView.document = doc
        // Fit the whole first page once the view has its final size.
        DispatchQueue.main.async { [weak self] in
            self?.fit()
            self?.pdfView.goToFirstPage(nil)
        }
        updateLabel()
        return true
    }

    func unload() { pdfView.document = nil }

    private func unlock(_ doc: PDFDocument, name: String) -> Bool {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let alert = NSAlert()
        alert.messageText = "“\(name)” is password protected"
        alert.informativeText = "Enter the password to open it."
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            if doc.unlock(withPassword: field.stringValue) { return true }
            alert.informativeText = "Wrong password. Try again."
            field.stringValue = ""
        }
        return false
    }

    private func updateLabel() {
        pageLabel.stringValue = pageCount > 0 ? "Page \(currentPage) of \(pageCount)   \(zoomPercent)%" : ""
        onChange?()
    }

    @objc func previousPage() { pdfView.goToPreviousPage(nil) }
    @objc func nextPage() { pdfView.goToNextPage(nil) }
    @objc func zoomIn() { pdfView.zoomIn(nil) }
    @objc func zoomOut() { pdfView.zoomOut(nil) }
    /// Scales so a whole page is visible.
    @objc func fit() {
        guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return }
        let box = page.bounds(for: pdfView.displayBox)
        let rotated = page.rotation % 180 != 0
        let w = rotated ? box.height : box.width, h = rotated ? box.width : box.height
        let avail = pdfView.bounds.insetBy(dx: 12, dy: 12)
        guard w > 0, h > 0, avail.width > 0, avail.height > 0 else { pdfView.autoScales = true; return }
        pdfView.autoScales = false
        pdfView.scaleFactor = min(avail.width / w, avail.height / h)
        pdfView.go(to: page)
    }
    func actualSize() { pdfView.scaleFactor = 1 }

    @objc private func toggleContinuous() {
        pdfView.displayMode = continuousButton.state == .on ? .singlePageContinuous : .singlePage
    }
}

// MARK: - Text viewer

final class TextViewerView: NSView {
    private let scroll = NSTextView.scrollableTextView()
    var textView: NSTextView { scroll.documentView as! NSTextView }
    private lazy var wrapButton = NSButton(checkboxWithTitle: "Wrap lines", target: self, action: #selector(toggleWrap))
    private let infoLabel = NSTextField(labelWithString: "")
    private var fontSize: CGFloat = 13
    private(set) var file: DocumentSupport.TextFile?

    override init(frame: NSRect) {
        super.init(frame: frame)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        wrapButton.state = .on
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = .systemFont(ofSize: 11)

        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            return b
        }
        let stack = NSStackView(views: [
            infoLabel, NSView(), wrapButton,
            button("textformat.size.smaller", "Smaller text", #selector(smaller)),
            button("textformat.size.larger", "Larger text", #selector(larger)),
        ])
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        let bar = NSVisualEffectView()
        bar.material = .titlebar

        for v in [bar, stack, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(bar)
        bar.addSubview(stack)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 36),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func load(_ url: URL) throws {
        let f = try DocumentSupport.readText(url)
        file = f
        textView.string = f.string
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.scrollToBeginningOfDocument(nil)
        let lines = DocumentSupport.textInfo(f).first { $0.0 == "Lines" }?.1 ?? "0"
        infoLabel.stringValue = "\(lines) lines · \(String.localizedName(of: f.encoding))" + (f.truncated ? " · truncated" : "")
    }

    func unload() {
        textView.string = ""
        file = nil
    }

    @objc private func toggleWrap() {
        let wrap = wrapButton.state == .on
        let container = textView.textContainer!
        scroll.hasHorizontalScroller = !wrap
        textView.isHorizontallyResizable = !wrap
        if wrap {
            container.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
            container.widthTracksTextView = true
            textView.frame.size.width = scroll.contentSize.width
        } else {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
    }

    @objc func smaller() { setFontSize(fontSize - 1) }
    @objc func larger() { setFontSize(fontSize + 1) }
    func resetFontSize() { setFontSize(13) }

    private func setFontSize(_ size: CGFloat) {
        fontSize = min(max(size, 8), 40)
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
}
