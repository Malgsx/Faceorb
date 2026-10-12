import Foundation

/// A rectangle in normalized image coordinates (0...1, origin top-left).
public struct NormRect: Codable, Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct Photo: Codable, Identifiable, Hashable, Sendable {
    public var id: String          // "<source>/<key>", stable across re-imports
    public var name: String
    public var source: String      // e.g. "pixieset:987654321", "link:3f2a9c" or "folder:/Users/me/Pictures/Party"
    public var localPath: String   // file on disk we analyse and show
    public var remoteURL: String?
    public var analyzed: Bool = false

    public init(id: String, name: String, source: String, localPath: String, remoteURL: String? = nil) {
        self.id = id; self.name = name; self.source = source; self.localPath = localPath; self.remoteURL = remoteURL
    }
}

/// One detected face. `signature` is the 128-number SFace embedding (L2-normalised);
/// it is the only biometric data FaceOrb keeps and can be wiped per face.
public struct Face: Codable, Identifiable, Hashable, Sendable {
    public var id: String          // "<photoID>#<index>"
    public var photoID: String
    public var box: NormRect
    public var signature: [Float]?

    public init(id: String, photoID: String, box: NormRect, signature: [Float]?) {
        self.id = id; self.photoID = photoID; self.box = box; self.signature = signature
    }
}

public enum Verdict: String, Codable, Sendable { case approved, rejected }

public enum Bucket: String, Codable, CaseIterable, Sendable {
    case mine, review, others
    public var title: String {
        switch self {
        case .mine: "My photos"
        case .review: "Needs review"
        case .others: "Everyone else"
        }
    }
}

/// A face signature known to be (positive) or not be (negative) the user.
public struct Reference: Codable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable { case selfie, picked, approval, rejection }
    public var signature: [Float]
    public var positive: Bool
    public var origin: Origin
    public var faceID: String?     // album face it came from, if any

    public init(signature: [Float], positive: Bool, origin: Origin, faceID: String? = nil) {
        self.signature = signature; self.positive = positive; self.origin = origin; self.faceID = faceID
    }
}

public struct MatchSettings: Codable, Hashable, Sendable {
    /// Photo score at or above which a photo is auto-filed as "mine".
    public var autoThreshold: Float = 0.50
    /// Photo score at or above which (but below `autoThreshold`) a photo goes to review.
    public var reviewThreshold: Float = 0.32
    /// Score a face against the mean of its k closest positive references, which keeps one
    /// odd side-view approval from dragging look-alikes into review.
    public var topK: Int = 3
    /// Faces narrower than this many pixels (in the analysed image) are ignored.
    public var minFacePixels: Double = 40
    /// After review, drop signatures of faces that are clearly not the user.
    public var forgetBystandersAutomatically: Bool = false
    public init() {}
}

public struct Library: Codable, Sendable {
    public var version = 1
    public var photos: [Photo] = []
    public var faces: [Face] = []
    public var references: [Reference] = []
    public var verdicts: [String: Verdict] = [:]   // photoID -> verdict
    public var settings = MatchSettings()
    public var albums: [String: String] = [:]      // source -> human title
    /// Where each album came from (source -> origin), so it can be found again later.
    public var albumOrigins: [String: AlbumOrigin] = [:]
    /// Folders photos were saved to, newest first.
    public var exports: [ExportRecord] = []
    public init() {}

    static let maxExports = 10

    /// Remembers a save folder, newest first, one entry per folder.
    public mutating func recordExport(folder: String, count: Int, at date: Date = Date()) {
        exports.removeAll { $0.folder == folder }
        exports.insert(ExportRecord(folder: folder, count: count, date: date), at: 0)
        if exports.count > Self.maxExports { exports.removeLast(exports.count - Self.maxExports) }
    }

    /// The folder a folder import came from, or nil for other sources.
    public static func folderPath(forSource source: String) -> String? {
        source.hasPrefix("folder:") ? String(source.dropFirst("folder:".count)) : nil
    }

    // Lenient decoding: a library.json from an older build (missing newer keys) must still load,
    // because LibraryStore.load() falls back to an empty library when decoding fails.
    private enum CodingKeys: String, CodingKey {
        case version, photos, faces, references, verdicts, settings, albums, albumOrigins, exports
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        photos = try c.decodeIfPresent([Photo].self, forKey: .photos) ?? []
        faces = try c.decodeIfPresent([Face].self, forKey: .faces) ?? []
        references = try c.decodeIfPresent([Reference].self, forKey: .references) ?? []
        verdicts = try c.decodeIfPresent([String: Verdict].self, forKey: .verdicts) ?? [:]
        settings = try c.decodeIfPresent(MatchSettings.self, forKey: .settings) ?? MatchSettings()
        albums = try c.decodeIfPresent([String: String].self, forKey: .albums) ?? [:]
        albumOrigins = (try? c.decodeIfPresent([String: AlbumOrigin].self, forKey: .albumOrigins)) ?? [:]
        exports = (try? c.decodeIfPresent([ExportRecord].self, forKey: .exports)) ?? []
    }
}

/// Where an album was imported from.
public struct AlbumOrigin: Codable, Sendable, Equatable {
    /// The link as pasted (folder imports keep their path in the source id).
    public var link: String?
    public var importedAt: Date?
    public init(link: String? = nil, importedAt: Date? = Date()) {
        self.link = link
        self.importedAt = importedAt
    }
}

/// A folder photos were saved to.
public struct ExportRecord: Codable, Sendable, Equatable, Identifiable {
    public var folder: String
    public var count: Int
    public var date: Date
    public var id: String { folder }
    public init(folder: String, count: Int, date: Date) {
        self.folder = folder
        self.count = count
        self.date = date
    }
}
