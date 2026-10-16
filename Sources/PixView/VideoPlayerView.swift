import AppKit
import AVKit

/// Video area with a control bar: play/pause, stop, ±10 s, seek bar, time, mute, volume.
final class VideoPlayerView: NSView {
    private let player = AVPlayer()
    private let playerView = AVPlayerView()
    private let bar = NSView()
    private lazy var playButton = button("play.fill", "Play / Pause (Space)", #selector(togglePlay))
    private lazy var stopButton = button("stop.fill", "Stop", #selector(stop))
    private lazy var backButton = button("gobackward.10", "Back 10 seconds (,)", #selector(skipBack))
    private lazy var forwardButton = button("goforward.10", "Forward 10 seconds (.)", #selector(skipForward))
    private lazy var muteButton = button("speaker.wave.2.fill", "Mute (M)", #selector(toggleMute))
    private let seekSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var scrubbing = false

    /// Keys not handled by the player go to the viewer.
    var onKey: ((NSEvent) -> Bool)?
    var onDoubleClick: (() -> Void)?
    /// Called when playback reaches the end.
    var onFinished: (() -> Void)?
    /// Called when the file cannot be decoded (e.g. MPEG-2, MKV, WebM).
    var onFailed: ((Error?) -> Void)?

    var isPlaying: Bool { player.timeControlStatus != .paused }
    var duration: Double {
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite ? d : 0
    }
    var presentationSize: CGSize { player.currentItem?.presentationSize ?? .zero }

    override init(frame: NSRect) {
        super.init(frame: frame)
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect

        bar.wantsLayer = true
        bar.appearance = NSAppearance(named: .darkAqua) // visible slider tracks on the dark bar
        bar.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        seekSlider.target = self
        seekSlider.action = #selector(seek(_:))
        seekSlider.isContinuous = true
        seekSlider.controlSize = .small
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        volumeSlider.controlSize = .small
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = NSColor(white: 0.85, alpha: 1)

        let stack = NSStackView(views: [playButton, stopButton, backButton, forwardButton, seekSlider, timeLabel, muteButton, volumeSlider])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        seekSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for v in [playerView, bar, stack] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(playerView)
        addSubview(bar)
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            seekSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            volumeSlider.widthAnchor.constraint(equalToConstant: 70),
        ])

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] _ in
            self?.updateTime()
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updatePlayButton() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(itemFinished(_:)),
                                               name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        b.toolTip = tip
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    // MARK: Loading

    func load(_ url: URL, autoplay: Bool) {
        let item = AVPlayerItem(url: url)
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                guard let self, item === self.player.currentItem else { return }
                self.onFailed?(item.error)
            }
        }
        player.replaceCurrentItem(with: item)
        seekSlider.doubleValue = 0
        updateTime()
        if autoplay { player.play() }
        updatePlayButton()
    }

    func unload() {
        player.pause()
        itemObservation = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Controls

    @objc func togglePlay() {
        guard player.currentItem != nil else { return }
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, player.currentTime().seconds >= duration - 0.1 { player.seek(to: .zero) }
            player.play()
        }
    }

    @objc func stop() {
        player.pause()
        player.seek(to: .zero)
        updateTime()
    }

    @objc func skipBack() { skip(by: -10) }
    @objc func skipForward() { skip(by: 10) }

    func skip(by seconds: Double) {
        guard duration > 0 else { return }
        let t = min(max(player.currentTime().seconds + seconds, 0), duration)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
    }

    @objc func toggleMute() {
        player.isMuted.toggle()
        let symbol = player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        muteButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mute")
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        player.volume = Float(sender.doubleValue)
        if player.isMuted, sender.doubleValue > 0 { toggleMute() }
    }

    @objc private func seek(_ sender: NSSlider) {
        let type = NSApp.currentEvent?.type
        scrubbing = type == .leftMouseDown || type == .leftMouseDragged
        guard duration > 0 else { return }
        let t = CMTime(seconds: sender.doubleValue * duration, preferredTimescale: 600)
        let tol = scrubbing ? CMTime(seconds: 0.5, preferredTimescale: 600) : .zero
        player.seek(to: t, toleranceBefore: tol, toleranceAfter: tol)
        timeLabel.stringValue = "\(VideoSupport.formatTime(t.seconds)) / \(VideoSupport.formatTime(duration))"
    }

    @objc private func itemFinished(_ note: Notification) {
        guard (note.object as? AVPlayerItem) === player.currentItem else { return }
        updatePlayButton()
        onFinished?()
    }

    private func updateTime() {
        let now = player.currentTime().seconds
        if !scrubbing, duration > 0, now.isFinite { seekSlider.doubleValue = now / duration }
        timeLabel.stringValue = "\(VideoSupport.formatTime(now)) / \(VideoSupport.formatTime(duration))"
    }

    private func updatePlayButton() {
        let symbol = isPlaying ? "pause.fill" : "play.fill"
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Play / Pause")
    }

    // MARK: Events

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }

    /// Clicks on the picture itself land here instead of inside AVPlayerView.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let hit, hit === playerView || hit.isDescendant(of: playerView) { return self }
        return hit
    }
}
