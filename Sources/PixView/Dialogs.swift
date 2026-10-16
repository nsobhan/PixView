import AppKit

private func label(_ s: String) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.alignment = .right
    return l
}

// MARK: Resize

final class ResizeDialog: NSObject, NSTextFieldDelegate {
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let percentField = NSTextField()
    private let keepAspect = NSButton(checkboxWithTitle: "Keep aspect ratio", target: nil, action: nil)
    private let origW: Int, origH: Int

    init(width: Int, height: Int) {
        origW = width
        origH = height
    }

    func run() -> (width: Int, height: Int)? {
        widthField.stringValue = "\(origW)"
        heightField.stringValue = "\(origH)"
        percentField.stringValue = "100"
        keepAspect.state = .on
        for f in [widthField, heightField, percentField] {
            f.delegate = self
            f.widthAnchor.constraint(equalToConstant: 90).isActive = true
        }
        let grid = NSGridView(views: [
            [label("Width:"), widthField, NSTextField(labelWithString: "px")],
            [label("Height:"), heightField, NSTextField(labelWithString: "px")],
            [label("Scale:"), percentField, NSTextField(labelWithString: "%")],
            [NSGridCell.emptyContentView, keepAspect],
        ])
        grid.frame = NSRect(x: 0, y: 0, width: 260, height: 110)

        let alert = NSAlert()
        alert.messageText = "Resize Image"
        alert.informativeText = "Current size: \(origW) × \(origH) pixels"
        alert.accessoryView = grid
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = widthField
        guard alert.runModal() == .alertFirstButtonReturn,
              let w = Int(widthField.stringValue), let h = Int(heightField.stringValue),
              w > 0, h > 0, w <= 30000, h <= 30000 else { return nil }
        return (w, h)
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField, let v = Double(field.stringValue), v > 0 else { return }
        let ratio = Double(origH) / Double(origW)
        if field === percentField {
            widthField.stringValue = "\(max(1, Int((Double(origW) * v / 100).rounded())))"
            heightField.stringValue = "\(max(1, Int((Double(origH) * v / 100).rounded())))"
        } else if keepAspect.state == .on {
            if field === widthField {
                heightField.stringValue = "\(max(1, Int((v * ratio).rounded())))"
                percentField.stringValue = String(format: "%.1f", v / Double(origW) * 100)
            } else if field === heightField {
                widthField.stringValue = "\(max(1, Int((v / ratio).rounded())))"
                percentField.stringValue = String(format: "%.1f", v / Double(origH) * 100)
            }
        }
    }
}

// MARK: Color corrections

final class ColorDialog: NSObject {
    private var params = ColorParams()
    private let onChange: (ColorParams) -> Void
    private var sliders: [NSSlider] = []
    private var valueLabels: [NSTextField] = []

    init(onChange: @escaping (ColorParams) -> Void) {
        self.onChange = onChange
    }

    func run() -> ColorParams? {
        let specs: [(String, Double, Double, Double)] = [
            ("Brightness:", -0.5, 0.5, 0),
            ("Contrast:", 0.25, 2, 1),
            ("Saturation:", 0, 2, 1),
            ("Gamma:", 0.3, 3, 1),
        ]
        var rows: [[NSView]] = []
        for (i, spec) in specs.enumerated() {
            let s = NSSlider(value: spec.3, minValue: spec.1, maxValue: spec.2, target: self, action: #selector(changed(_:)))
            s.tag = i
            s.isContinuous = false
            s.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let v = NSTextField(labelWithString: String(format: "%.2f", spec.3))
            v.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            sliders.append(s)
            valueLabels.append(v)
            rows.append([label(spec.0), s, v])
        }
        let grid = NSGridView(views: rows)
        grid.frame = NSRect(x: 0, y: 0, width: 340, height: 120)

        let alert = NSAlert()
        alert.messageText = "Color Corrections"
        alert.informativeText = "Changes are previewed in the main window."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? params : nil
    }

    @objc private func changed(_ sender: NSSlider) {
        let v = sender.doubleValue
        valueLabels[sender.tag].stringValue = String(format: "%.2f", v)
        switch sender.tag {
        case 0: params.brightness = v
        case 1: params.contrast = v
        case 2: params.saturation = v
        default: params.gamma = v
        }
        onChange(params)
    }
}

// MARK: Save panel accessory

final class SaveAccessory: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 64))
    private let popup = NSPopUpButton()
    private let slider = NSSlider(value: 90, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "90")
    private let formats: [SaveFormat]
    private weak var panel: NSSavePanel?

    var selected: SaveFormat { formats[max(popup.indexOfSelectedItem, 0)] }
    var quality: Double { slider.doubleValue / 100 }

    init(formats: [SaveFormat], initial: Int, panel: NSSavePanel) {
        self.formats = formats
        self.panel = panel
        super.init()
        popup.addItems(withTitles: formats.map(\.name))
        popup.selectItem(at: initial)
        popup.target = self
        popup.action = #selector(formatChanged)
        slider.target = self
        slider.action = #selector(qualityChanged)

        let grid = NSGridView(views: [
            [label("Format:"), popup],
            [label("Quality:"), slider, qualityLabel],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        formatChanged()
    }

    @objc private func formatChanged() {
        slider.isEnabled = selected.lossy
        qualityLabel.textColor = selected.lossy ? .labelColor : .disabledControlTextColor
        panel?.allowedContentTypes = [selected.type]
    }

    @objc private func qualityChanged() {
        qualityLabel.stringValue = "\(Int(slider.doubleValue))"
    }
}

// MARK: Helpers

func showError(_ message: String, info: String = "") {
    let a = NSAlert()
    a.alertStyle = .warning
    a.messageText = message
    a.informativeText = info
    a.runModal()
}

func showTextPanel(title: String, text: String) {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 320))
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    let tv = NSTextView(frame: scroll.bounds)
    tv.isEditable = false
    tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    tv.string = text
    tv.autoresizingMask = [.width]
    scroll.documentView = tv
    let a = NSAlert()
    a.messageText = title
    a.accessoryView = scroll
    a.runModal()
}
