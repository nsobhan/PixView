<p align="center">
  <img src="docs/icon.png" width="128" alt="PixView icon">
</p>

<h1 align="center">PixView</h1>

<p align="center">
  A fast, keyboard-driven picture, video, PDF and text viewer for macOS.<br>
  Native Swift + AppKit, no dependencies.
</p>

---

PixView is built for quickly flipping through a folder of files: open one picture and the arrow keys take you
through everything else in the same folder. It started as a Mac take on the workflow of classic Windows image
viewers such as IrfanView. It is an independent implementation written from scratch, and is not affiliated with
or derived from IrfanView.

## Features

### Pictures
- Opens every format macOS can decode: JPEG, PNG, HEIC/HEIF, WebP, TIFF, GIF, BMP, PSD, JPEG 2000, camera RAW
  and more (about 70 extensions)
- Photos are shown the right way up, using the EXIF orientation
- Zoom with keys, trackpad pinch or ⌘-scroll; pan with Option-drag or right-drag; fit-to-window or 100% pixels
- **Editing:** crop to selection, rotate, flip, resize, brightness / contrast / saturation / gamma with live
  preview, auto-adjust, grayscale, negative, sharpen, blur, and 20 levels of undo
- **Saving:** JPEG, PNG, HEIC, TIFF, BMP, GIF and JPEG 2000, with a quality slider. Camera metadata (EXIF, GPS) is kept.
- Image information panel with camera, lens, exposure, ISO and GPS details

### Videos
- Plays any format macOS supports: MP4, MOV (including HEVC/H.265 from iPhones), M4V, 3GP, MPEG-TS and more
- Control bar: **Play / Pause, Stop, back / forward 10 s, seek bar, time, mute, volume**
- Video information: duration, resolution, frame rate, codec, bitrate and audio format
- Files macOS can't decode (MPEG-2, some AVI) show a clear "can't play" message instead of a black screen

### PDFs
- Page navigation, zoom, fit page, and continuous or single-page scrolling
- Select and copy text; print
- Password-protected PDFs prompt for the password
- Document information: page count and size, title, author, creator, PDF version

### Text files
- `.txt`, `.log`, `.md`, `.csv`, `.tsv`, `.json`, `.xml`, `.yaml`, `.ini`, `.conf`
- Detects the text encoding (UTF-8, Windows / Latin-1, …) and handles any script and emoji
- Word-wrap toggle, adjustable text size, find (⌘F)
- Files over 10 MB open quickly, showing only the first 10 MB

### Browsing
- **Folder tree** sidebar (Home, Desktop, Documents, Downloads, Pictures and all mounted drives)
- **Thumbnail strip** along the bottom showing everything in the current folder
- **Thumbnails window** with a large grid
- **Slideshow** with adjustable timing (1–30 s); a playing video is allowed to finish before it moves on
- Full screen, drag and drop, "Open With" from Finder, rename, move to Trash, reveal in Finder

## Requirements

- macOS 13 Ventura or later (Apple silicon or Intel)
- To build: Xcode or the Xcode Command Line Tools (Swift 5.9+)

## Build and install

```bash
git clone <this-repo-url>
cd PixView
./build.sh              # builds build/PixView.app
./build.sh --install    # builds and copies it into /Applications
```

The app is signed for local use only (ad hoc). If you copy it to another Mac, macOS may say it "can't be
opened". Right-click the app and choose **Open** the first time.

To make PixView open pictures by default, select a file in Finder, press ⌘I, choose PixView under **Open with**,
then click **Change All…**.

## Keyboard shortcuts

Single-key shortcuts work while the picture or video has focus. Press **Help → Keyboard Shortcuts** in the app
for the full list.

| Navigation | |
|---|---|
| → ↓ Space Page Down | Next file |
| ← ↑ Backspace Page Up | Previous file |
| Home / End | First / last file in folder |
| ⌘[ / ⌘] | Previous / next file (works everywhere) |
| B or ⌃⌘S | Show / hide folder tree and thumbnail strip |
| T | Thumbnails window |
| W | Start / stop slideshow |
| Return or double-click | Full screen |
| Esc | Stop slideshow / leave full screen / clear selection |

| View | |
|---|---|
| + / − (⌘+ / ⌘−) | Zoom in / out (text size for text files) |
| F (⌘9) | Fit to window |
| 1 (⌘0) | Actual size |
| ⌘-scroll, pinch | Zoom at the pointer |
| Option-drag, right-drag | Pan |

| Video | |
|---|---|
| Space / K | Play / pause |
| , / . | Back / forward 10 seconds |
| M | Mute |

| Editing | |
|---|---|
| Drag | Select a rectangle |
| ⌘Y | Crop to selection |
| L / R | Rotate left / right |
| H / V | Flip horizontal / vertical |
| G | Grayscale |
| ⌘R | Resize |
| ⌘K | Color corrections |
| ⌘Z | Undo |
| ⌘C / ⌘V | Copy (selection) / paste image |

| File | |
|---|---|
| ⌘O | Open a file or folder |
| ⌘S | Save |
| S (⇧⌘S) | Save As |
| I (⌘I) | File information |
| ⌘⌫ or ⌦ | Move to Trash |
| ⇧⌘R | Rename |
| ⌘P | Print |
| ⌘F / ⌘G | Find / find next (text files) |

## Known limitations

- MKV, WebM and MPEG-2 videos are not supported, because macOS has no built-in decoder for them
- Animated GIFs and multi-page TIFFs show only the first frame
- Edits are done at 8 bits per channel, so saving a 16-bit image reduces its colour depth
- There is no batch conversion yet

## Project layout

```
PixView/
├── Package.swift               Swift package (one executable target)
├── build.sh                    Builds the .app bundle; --install copies it to /Applications
├── Resources/
│   ├── Info.plist              Bundle info and the file types PixView can open
│   └── AppIcon.icns
└── Sources/PixView/
    ├── main.swift, AppDelegate.swift      App startup and menus
    ├── ViewerWindowController.swift       Main window: navigation, editing, saving, status bar
    ├── ImageView.swift                    Image canvas: zoom, pan, selection, drag and drop
    ├── ImageIOSupport.swift               Folder listing, image loading/saving, thumbnails
    ├── ImageOps.swift                     Rotate, flip, crop, resize and Core Image filters
    ├── Dialogs.swift                      Resize, color, Save As and info dialogs
    ├── FolderTree.swift                   Folder tree sidebar
    ├── FilmStrip.swift                    Bottom thumbnail strip
    ├── ThumbnailWindowController.swift    Thumbnails window
    ├── VideoSupport.swift                 Video formats, thumbnails and info
    ├── VideoPlayerView.swift              Video player and control bar
    └── DocumentSupport.swift              PDF and text viewers
```
