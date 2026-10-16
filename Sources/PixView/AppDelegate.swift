import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var viewer = ViewerWindowController()
    private var pendingURLs: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        viewer.showWindow(nil)
        launched = true

        // Paths passed on the command line: `PixView.app/Contents/MacOS/PixView photo.jpg`
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let cli = args.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        let toOpen = pendingURLs + cli
        if !toOpen.isEmpty { viewer.open(urls: toOpen) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if launched { viewer.open(urls: urls) } else { pendingURLs += urls }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        viewer.confirmDiscardChanges() ? .terminateNow : .terminateCancel
    }

    @objc func showShortcuts(_ sender: Any?) {
        showTextPanel(title: "Keyboard Shortcuts", text: """
        Navigation
          → ↓ Space PageDown     Next image
          ← ↑ Backspace PageUp   Previous image
          Home / End             First / last image in folder
          T                      Thumbnails
          B  (⌃⌘S)               Show / hide folder tree
          W                      Start / stop slideshow
          Return, double-click   Full screen
          Esc                    Stop slideshow / leave full screen / deselect

        Video
          Space / K              Play / pause
          , / .                  Back / forward 10 seconds
          M                      Mute
          Buttons                Play/Pause, Stop, ±10 s, seek bar, volume

        PDF & text files
          Toolbar                Pages, zoom, continuous scroll / wrap lines, text size
          ⌘+ / ⌘- / ⌘0           Zoom PDF or change text size
          ⌘C, ⌘A, ⌘F             Copy, select all, find (text files)
          ⌘[ / ⌘]                Previous / next file

        View
          + / -  (⌘+ / ⌘-)       Zoom in / out
          ⌘-scroll, pinch        Zoom at pointer
          F  (⌘9)                Fit to window
          1  (⌘0)                Actual pixels (100%)
          Option-drag, right-drag  Pan

        Edit
          Drag                   Select a rectangle
          ⌘Y                     Crop to selection
          L / R                  Rotate left / right
          H / V                  Flip horizontal / vertical
          G                      Grayscale
          ⌘R                     Resize
          ⌘Z                     Undo
          ⌘C / ⌘V                Copy (selection) / paste image

        File
          ⌘O                     Open file or folder (drag & drop works too)
          ⌘S                     Save (overwrite, same format)
          S  (⇧⌘S)               Save As (JPEG, PNG, HEIC, TIFF, BMP, GIF…)
          I  (⌘I)                Image information / EXIF
          ⌘⌫  or  ⌦              Move to Trash
          ⇧⌘R                    Rename
        """)
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let v = viewer

        func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
                  target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target ?? v
            i.tag = tag
            return i
        }
        @discardableResult func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            main.addItem(top)
            return top
        }
        let sep = { NSMenuItem.separator() }
        let app = NSApp!

        submenu("PixView", [
            item("About PixView", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: app),
            sep(),
            item("Hide PixView", #selector(NSApplication.hide(_:)), "h", target: app),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: app),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: app),
            sep(),
            item("Quit PixView", #selector(NSApplication.terminate(_:)), "q", target: app),
        ])

        submenu("File", [
            item("Open…", #selector(ViewerWindowController.openDocument(_:)), "o"),
            item("Thumbnails", #selector(ViewerWindowController.showThumbnails(_:)), "t"),
            sep(),
            item("Save", #selector(ViewerWindowController.saveDocument(_:)), "s"),
            item("Save As…", #selector(ViewerWindowController.saveDocumentAs(_:)), "s", [.command, .shift]),
            sep(),
            item("Image Information", #selector(ViewerWindowController.showInfo(_:)), "i"),
            item("Rename…", #selector(ViewerWindowController.renameFile(_:)), "r", [.command, .shift]),
            item("Reveal in Finder", #selector(ViewerWindowController.revealInFinder(_:)), "r", [.command, .option]),
            item("Move to Trash", #selector(ViewerWindowController.moveToTrash(_:)), "\u{8}"),
            sep(),
            item("Print…", #selector(ViewerWindowController.printImage(_:)), "p"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", target: nil),
        ]).submenu?.items.last?.target = nil

        // Find goes to whichever text view has focus, so these have no fixed target.
        let find = item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f",
                        tag: Int(NSTextFinder.Action.showFindInterface.rawValue))
        let findNext = item("Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g",
                            tag: Int(NSTextFinder.Action.nextMatch.rawValue))
        find.target = nil
        findNext.target = nil

        submenu("Edit", [
            item("Undo", #selector(ViewerWindowController.undoEdit(_:)), "z"),
            sep(),
            item("Copy", #selector(ViewerWindowController.copyImage(_:)), "c"),
            item("Paste", #selector(ViewerWindowController.pasteImage(_:)), "v"),
            sep(),
            item("Select All", #selector(ViewerWindowController.selectAllPixels(_:)), "a"),
            item("Deselect", #selector(ViewerWindowController.deselect(_:)), "d"),
            item("Crop to Selection", #selector(ViewerWindowController.cropToSelection(_:)), "y"),
            sep(),
            find,
            findNext,
        ])

        submenu("Image", [
            item("Rotate Left", #selector(ViewerWindowController.rotateLeft(_:)), "l"),
            item("Rotate Right", #selector(ViewerWindowController.rotateRight(_:)), "l", [.command, .shift]),
            item("Flip Horizontal", #selector(ViewerWindowController.flipHorizontal(_:)), "h", [.command, .control]),
            item("Flip Vertical", #selector(ViewerWindowController.flipVertical(_:)), "v", [.command, .control]),
            sep(),
            item("Resize…", #selector(ViewerWindowController.resizeImage(_:)), "r"),
            item("Color Corrections…", #selector(ViewerWindowController.colorCorrections(_:)), "k"),
            item("Auto Adjust Colors", #selector(ViewerWindowController.autoAdjust(_:)), "u"),
            sep(),
            item("Grayscale", #selector(ViewerWindowController.grayscale(_:)), "g"),
            item("Negative", #selector(ViewerWindowController.negative(_:)), "i", [.command, .shift]),
            item("Sharpen", #selector(ViewerWindowController.sharpen(_:)), "e", [.command, .shift]),
            item("Blur", #selector(ViewerWindowController.blur(_:)), "b", [.command, .shift]),
        ])

        let intervals = [1, 2, 3, 5, 10, 30].map {
            item("\($0) seconds", #selector(ViewerWindowController.setSlideshowInterval(_:)), tag: $0)
        }
        let intervalItem = NSMenuItem(title: "Slideshow Interval", action: nil, keyEquivalent: "")
        intervalItem.submenu = NSMenu(title: "Slideshow Interval")
        intervals.forEach { intervalItem.submenu?.addItem($0) }

        let fullScreen = item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], target: nil)
        fullScreen.target = nil

        submenu("View", [
            item("Zoom In", #selector(ViewerWindowController.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(ViewerWindowController.zoomOut(_:)), "-"),
            item("Actual Size", #selector(ViewerWindowController.actualSize(_:)), "0"),
            item("Fit to Window", #selector(ViewerWindowController.fitWindow(_:)), "9"),
            sep(),
            item("Show Folder Tree", #selector(ViewerWindowController.toggleFolderTree(_:)), "s", [.command, .control]),
            sep(),
            item("Next Image", #selector(ViewerWindowController.nextImage(_:)), "]"),
            item("Previous Image", #selector(ViewerWindowController.previousImage(_:)), "["),
            item("First Image", #selector(ViewerWindowController.firstImage(_:)), "[", [.command, .shift]),
            item("Last Image", #selector(ViewerWindowController.lastImage(_:)), "]", [.command, .shift]),
            sep(),
            item("Start Slideshow", #selector(ViewerWindowController.toggleSlideshow(_:)), "w", [.command, .option]),
            intervalItem,
            sep(),
            fullScreen,
        ])

        let windowMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil),
            item("Zoom", #selector(NSWindow.performZoom(_:)), target: nil),
        ]).submenu
        windowMenu?.items.forEach { $0.target = nil }
        NSApp.windowsMenu = windowMenu

        let help = submenu("Help", [item("Keyboard Shortcuts", #selector(showShortcuts(_:)), "?", target: self)]).submenu
        NSApp.helpMenu = help
        return main
    }
}
