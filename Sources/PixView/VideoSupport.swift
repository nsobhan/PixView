import AppKit
import AVFoundation
import UniformTypeIdentifiers

enum VideoSupport {
    /// Extensions of movie formats AVFoundation can play here (mp4, mov, m4v, 3gp, ...).
    static let extensions: Set<String> = {
        var exts = Set<String>()
        for type in AVURLAsset.audiovisualTypes() {
            if let ut = UTType(type.rawValue), ut.conforms(to: .movie) {
                exts.formUnion((ut.tags[.filenameExtension] ?? []).map { $0.lowercased() })
            }
        }
        return exts
    }()

    static func isVideo(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// A frame from about 1s in (or the first frame), with a play badge drawn on top.
    static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        func frame(at seconds: Double) -> CGImage? {
            let done = DispatchSemaphore(value: 0)
            var result: CGImage?
            gen.generateCGImageAsynchronously(for: CMTime(seconds: seconds, preferredTimescale: 600)) { img, _, _ in
                result = img
                done.signal()
            }
            done.wait()
            return result
        }
        guard let img = frame(at: 1) ?? frame(at: 0) else { return nil }
        return withPlayBadge(img)
    }

    private static func withPlayBadge(_ img: CGImage) -> CGImage {
        guard let ctx = ImageOps.context(width: img.width, height: img.height, like: img) else { return img }
        let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.draw(img, in: rect)
        let d = CGFloat(min(img.width, img.height)) * 0.32
        let circle = CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillEllipse(in: circle)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
        ctx.move(to: CGPoint(x: circle.minX + d * 0.38, y: circle.minY + d * 0.27))
        ctx.addLine(to: CGPoint(x: circle.minX + d * 0.38, y: circle.maxY - d * 0.27))
        ctx.addLine(to: CGPoint(x: circle.maxX - d * 0.25, y: circle.midY))
        ctx.closePath()
        ctx.fillPath()
        return ctx.makeImage() ?? img
    }

    /// Rows for the Information panel.
    static func info(_ url: URL) async -> [(String, String)] {
        let asset = AVURLAsset(url: url)
        var rows: [(String, String)] = []
        if let d = try? await asset.load(.duration), d.isNumeric {
            rows.append(("Duration", formatTime(d.seconds)))
        }
        if let v = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await v.load(.naturalSize), let t = try? await v.load(.preferredTransform) {
                let s = size.applying(t)
                rows.append(("Dimensions", "\(Int(abs(s.width))) × \(Int(abs(s.height))) pixels"))
            }
            if let fps = try? await v.load(.nominalFrameRate), fps > 0 { rows.append(("Frame rate", String(format: "%.2f fps", fps))) }
            if let rate = try? await v.load(.estimatedDataRate), rate > 0 { rows.append(("Video bitrate", "\(Int(rate / 1000)) kbps")) }
            if let fmt = try? await v.load(.formatDescriptions).first { rows.append(("Video codec", fourCC(CMFormatDescriptionGetMediaSubType(fmt)))) }
        }
        if let a = try? await asset.loadTracks(withMediaType: .audio).first {
            var desc = "yes"
            if let fmt = try? await a.load(.formatDescriptions).first {
                desc = fourCC(CMFormatDescriptionGetMediaSubType(fmt))
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
                    desc += ", \(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch"
                }
            }
            rows.append(("Audio", desc))
        }
        return rows
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
