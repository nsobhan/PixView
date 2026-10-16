import AppKit
import ImageIO
import UniformTypeIdentifiers

struct LoadedImage {
    let image: CGImage
    let properties: [CFString: Any]
    let typeIdentifier: String?
    let frameCount: Int
}

struct SimpleError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct SaveFormat {
    let name: String
    let type: UTType
    let lossy: Bool
}

enum ImageIOSupport {
    /// Every file extension ImageIO can decode on this system (JPEG, PNG, HEIC, RAW, PSD, WebP, ...).
    static let readableExtensions: Set<String> = {
        var exts = Set<String>()
        for id in (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [] {
            if let type = UTType(id) {
                exts.formUnion((type.tags[.filenameExtension] ?? []).map { $0.lowercased() })
            }
        }
        return exts
    }()

    static let saveFormats: [SaveFormat] = {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        var all: [SaveFormat] = [
            SaveFormat(name: "JPEG", type: .jpeg, lossy: true),
            SaveFormat(name: "PNG", type: .png, lossy: false),
            SaveFormat(name: "HEIC", type: .heic, lossy: true),
            SaveFormat(name: "TIFF", type: .tiff, lossy: false),
            SaveFormat(name: "BMP", type: .bmp, lossy: false),
            SaveFormat(name: "GIF", type: .gif, lossy: false),
        ]
        if let jp2 = UTType("public.jpeg-2000") { all.append(SaveFormat(name: "JPEG 2000", type: jp2, lossy: true)) }
        return all.filter { writable.contains($0.type.identifier) }
    }()

    static func isImage(_ url: URL) -> Bool {
        readableExtensions.contains(url.pathExtension.lowercased())
    }

    static func listImages(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { isImage($0) || VideoSupport.isVideo($0) || DocumentSupport.isDocument($0) }
            .map { $0.resolvingSymlinksInPath() }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Decodes the first frame with EXIF orientation already applied.
    static func load(_ url: URL) -> LoadedImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1

        var image: CGImage?
        if orientation != 1, width > 0, height > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        if image == nil {
            image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let image else { return nil }
        return LoadedImage(image: image, properties: props,
                           typeIdentifier: CGImageSourceGetType(src) as String?,
                           frameCount: CGImageSourceGetCount(src))
    }

    /// Thumbnail for an image or (with a play badge) a video.
    static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        if VideoSupport.isVideo(url) { return VideoSupport.thumbnail(url, maxPixel: maxPixel) }
        if DocumentSupport.isDocument(url) { return DocumentSupport.thumbnail(url, maxPixel: maxPixel) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Writes atomically (via a temp file) so overwriting the source file is safe.
    static func save(_ image: CGImage, to url: URL, format: SaveFormat, quality: Double, metadata: [CFString: Any]) throws {
        var output = image
        if format.type == .jpeg || format.type == .bmp, let flat = ImageOps.flattened(image) { output = flat }

        var props = metadata
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyFileSize] {
            props.removeValue(forKey: key)
        }
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = output.width
            exif[kCGImagePropertyExifPixelYDimension] = output.height
            props[kCGImagePropertyExifDictionary] = exif
        }
        if format.lossy { props[kCGImageDestinationLossyCompressionQuality] = quality }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".pixview-\(UUID().uuidString).\(url.pathExtension)")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw SimpleError(message: "Cannot create a \(format.name) file at this location.")
        }
        CGImageDestinationAddImage(dest, output, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tmp)
            throw SimpleError(message: "Encoding the image as \(format.name) failed.")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
