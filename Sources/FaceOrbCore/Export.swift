import Foundation

/// How "Save my photos" writes files.
public struct ExportOptions: Codable, Sendable, Equatable {
    public enum Format: String, Codable, CaseIterable, Sendable {
        case original, jpeg, heic, png, tiff

        public var title: String {
            switch self {
            case .original: "Original (as downloaded)"
            case .jpeg: "JPEG"
            case .heic: "HEIC (smaller, Apple devices)"
            case .png: "PNG (lossless, large)"
            case .tiff: "TIFF (lossless, very large)"
            }
        }
        /// nil = keep the source file's extension.
        public var fileExtension: String? {
            switch self {
            case .original: nil
            case .jpeg: "jpg"
            case .heic: "heic"
            case .png: "png"
            case .tiff: "tiff"
            }
        }
        public var isLossy: Bool { self == .jpeg || self == .heic }
        /// Rough size relative to a web JPEG, for the free-space check.
        var sizeFactor: Double {
            switch self {
            case .original, .jpeg: 1.1
            case .heic: 0.7
            case .png: 3.5
            case .tiff: 6
            }
        }
    }

    public enum Scope: String, Codable, CaseIterable, Sendable {
        case mine, mineAndReview
        public var title: String { self == .mine ? "My photos" : "My photos + Needs review" }
    }

    public enum Naming: String, Codable, CaseIterable, Sendable {
        case original, numbered
        public var title: String { self == .original ? "Keep original names" : "Number them (Album-001…)" }
    }

    public var format: Format = .original
    public var quality: Double = 0.9          // JPEG / HEIC
    public var maxPixel: Int? = nil           // long edge; nil = full size
    public var scope: Scope = .mine
    public var naming: Naming = .original
    public var subfolder: String = "FaceOrb - My photos"   // empty = straight into the chosen folder

    public init() {}

    enum CodingKeys: String, CodingKey { case format, quality, maxPixel, scope, naming, subfolder }

    /// Missing keys fall back to defaults (the web app sends only what it shows).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Format.self, forKey: .format) ?? .original
        quality = min(max(try c.decodeIfPresent(Double.self, forKey: .quality) ?? 0.9, 0.3), 1)
        maxPixel = try c.decodeIfPresent(Int.self, forKey: .maxPixel).flatMap { $0 > 0 ? min(max($0, 320), 16384) : nil }
        scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .mine
        naming = try c.decodeIfPresent(Naming.self, forKey: .naming) ?? .original
        subfolder = ExportPlanner.safeName(try c.decodeIfPresent(String.self, forKey: .subfolder) ?? "FaceOrb - My photos")
    }

    public static let sizeChoices: [(String, Int?)] = [
        ("Full size", nil), ("4096 px", 4096), ("2048 px (good for sharing)", 2048), ("1080 px (social)", 1080),
    ]
}

public struct ExportItem: Sendable, Hashable {
    public var photo: Photo
    public var fileName: String
}

public enum ExportPlanner {
    /// Which photos to write and what to call them. Names are unique and safe for any file system.
    public static func plan(_ lib: Library, _ options: ExportOptions) -> [ExportItem] {
        let matches = Matcher.match(lib)
        let photos = lib.photos.filter { p in
            guard let b = matches[p.id]?.bucket else { return false }
            return b == .mine || (options.scope == .mineAndReview && b == .review)
        }
        var used = Set<String>()
        var items: [ExportItem] = []
        let width = max(3, String(photos.count).count)
        for (i, p) in photos.enumerated() {
            let sourceExt = (p.localPath as NSString).pathExtension.lowercased()
            let ext = options.format.fileExtension ?? (sourceExt.isEmpty ? "jpg" : sourceExt)
            var stem: String
            switch options.naming {
            case .original: stem = ((p.name as NSString).deletingPathExtension)
            case .numbered:
                let album = lib.albums[p.source].map(safeName) ?? "Photo"
                let n = String(i + 1)
                stem = "\(album.prefix(40))-\(String(repeating: "0", count: max(0, width - n.count)))\(n)"
            }
            stem = safeName(stem)
            if stem.isEmpty { stem = "photo" }
            var name = "\(stem).\(ext)", k = 2
            while used.contains(name.lowercased()) { name = "\(stem) \(k).\(ext)"; k += 1 }
            used.insert(name.lowercased())
            items.append(ExportItem(photo: p, fileName: name))
        }
        return items
    }

    /// Strips characters that Finder, exFAT or cloud drives reject.
    public static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = s.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return String(cleaned.prefix(120))
    }

    /// Bytes the export will probably need, from the source file sizes.
    public static func estimatedBytes(_ items: [ExportItem], _ options: ExportOptions) -> Int64 {
        let total = items.reduce(Int64(0)) { sum, item in
            let size = (try? FileManager.default.attributesOfItem(atPath: item.photo.localPath)[.size] as? NSNumber)?.int64Value ?? 500_000
            return sum + size
        }
        var factor = options.format.sizeFactor
        if let px = options.maxPixel, px < 1600 { factor *= Double(px * px) / Double(1600 * 1600) }
        return Int64(Double(total) * factor)
    }
}

public enum DiskCheck {
    /// Free space on the volume holding `url`, as macOS reports it for user files.
    public static func freeBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        #if os(macOS)
        if let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let n = v.volumeAvailableCapacityForImportantUsage, n > 0 { return n }
        #endif
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: probe.path),
           let n = attrs[.systemFreeSize] as? NSNumber { return n.int64Value }
        return nil
    }

    public static func describe(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public enum Problem: Error, LocalizedError {
        case lowSpace(free: Int64, needed: Int64)
        case notWritable(String)
        public var errorDescription: String? {
            switch self {
            case .lowSpace(let free, let needed):
                "Your Mac only has \(DiskCheck.describe(free)) free and this needs about \(DiskCheck.describe(needed)) plus room to spare. "
                    + "When a Mac's disk is full, files can't be written or even deleted properly (Finder error -36). "
                    + "Free some space first (Apple menu > System Settings > General > Storage)."
            case .notWritable(let why): "FaceOrb can't write to that folder: \(why)"
            }
        }
    }

    /// Keeps at least this much free after an operation so macOS and other apps keep working.
    public static let safetyMargin: Int64 = 2_000_000_000

    /// Throws if writing `needed` bytes into `folder` would leave the disk dangerously full,
    /// or if the folder can't take a small test file.
    public static func preflight(folder: URL, needed: Int64) throws {
        if let free = freeBytes(at: folder), free < needed + safetyMargin {
            throw Problem.lowSpace(free: free, needed: needed)
        }
        let probe = folder.appendingPathComponent(".faceorb-write-test-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
        } catch {
            try? FileManager.default.removeItem(at: probe)
            throw Problem.notWritable(error.localizedDescription)
        }
    }
}
