import AppKit
import CoreGraphics
import FaceOrbCore
import ImageIO

public enum Images {
    /// Decodes an image with EXIF orientation applied, downsampled so the long side is at most `maxPixel`.
    public static func load(_ url: URL, maxPixel: Int = 1600) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    public static func load(data: Data, maxPixel: Int = 1600) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// JPEG for the web app (browsers can't show HEIC/TIFF, and originals can be huge).
    public static func jpegData(_ image: CGImage, quality: Double = 0.82) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Renders into sRGB and strips alpha, giving the packed RGB buffer the aligner expects.
    public static func rgb(_ image: CGImage) -> RGBImage? {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = rgba[i * 4]; rgb[i * 3 + 1] = rgba[i * 4 + 1]; rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return RGBImage(width: w, height: h, pixels: rgb)
    }

    /// A square-ish crop around a face, padded so hair and chin show.
    public static func faceCrop(_ image: CGImage, box: NormRect, padding: Double = 0.35) -> CGImage? {
        let W = Double(image.width), H = Double(image.height)
        let side = max(box.width * W, box.height * H) * (1 + 2 * padding)
        let cx = (box.x + box.width / 2) * W, cy = (box.y + box.height / 2) * H
        let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
        return image.cropping(to: rect)
    }
}

/// In-memory thumbnail cache shared by the grids.
public actor ThumbnailCache {
    public static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.countLimit = 1500 }

    public func thumbnail(path: String, maxPixel: Int = 360) -> NSImage? {
        let key = "\(path)@\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let cg = Images.load(URL(fileURLWithPath: path), maxPixel: maxPixel) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key)
        return img
    }

    public func face(path: String, box: NormRect) -> NSImage? {
        let key = "\(path)#\(box.x),\(box.y)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let cg = Images.load(URL(fileURLWithPath: path), maxPixel: 1600),
              let crop = Images.faceCrop(cg, box: box) else { return nil }
        let img = NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
        cache.setObject(img, forKey: key)
        return img
    }
}
