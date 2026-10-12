import CoreGraphics
import FaceOrbCore
import Foundation
import ImageIO

public enum ImageExporter {
    public enum ExportError: LocalizedError {
        case unreadable(String), unsupported(String), encodeFailed(String), partial(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let n): "\(n) couldn't be read."
            case .unsupported(let f): "This Mac can't write \(f) files."
            case .encodeFailed(let n): "\(n) couldn't be encoded."
            case .partial(let n): "\(n) was only partly written."
            }
        }
    }

    static func typeIdentifier(_ f: ExportOptions.Format) -> String? {
        switch f {
        case .original: nil
        case .jpeg: "public.jpeg"
        case .heic: "public.heic"
        case .png: "public.png"
        case .tiff: "public.tiff"
        }
    }

    public static func canWrite(_ f: ExportOptions.Format) -> Bool {
        guard let id = typeIdentifier(f) else { return true }
        let ids = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return ids.contains(id)
    }

    /// Writes one photo. The file is built under a hidden temporary name in the same folder and
    /// renamed into place only once complete, so a failure never leaves a broken file behind.
    public static func export(_ source: URL, to dest: URL, options: ExportOptions) throws {
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".faceorb-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let data = try encode(source, options: options, name: dest.lastPathComponent)
        try data.write(to: tmp)
        let written = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.intValue ?? -1
        guard written == data.count else { throw ExportError.partial(dest.lastPathComponent) }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    static func encode(_ source: URL, options: ExportOptions, name: String) throws -> Data {
        // Straight copy: same bytes, no extended attributes, nothing re-encoded.
        if options.format == .original && options.maxPixel == nil {
            do { return try Data(contentsOf: source) } catch { throw ExportError.unreadable(name) }
        }
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw ExportError.unreadable(name)
        }
        let typeID = typeIdentifier(options.format) ?? (CGImageSourceGetType(src) as String?) ?? "public.jpeg"
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, typeID as CFString, 1, nil) else {
            throw ExportError.unsupported(options.format.title)
        }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        if options.format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = options.quality }

        if let maxPixel = options.maxPixel {
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
                throw ExportError.unreadable(name)
            }
            // Rotation is already applied to the pixels; keep camera metadata but reset orientation.
            props[kCGImagePropertyOrientation] = 1
            if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
            props[kCGImagePropertyPixelWidth] = nil
            props[kCGImagePropertyPixelHeight] = nil
            CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest), out.length > 0 else { throw ExportError.encodeFailed(name) }
        return out as Data
    }
}
