import Foundation

/// Everything FaceOrb keeps lives in one folder (default
/// ~/Library/Application Support/FaceOrb): `library.json` plus downloaded album copies under `albums/`.
/// Nothing is sent anywhere; deleting the folder removes every face signature.
public final class LibraryStore: @unchecked Sendable {
    public let root: URL
    public var libraryURL: URL { root.appendingPathComponent("library.json") }
    public var albumsURL: URL { root.appendingPathComponent("albums", isDirectory: true) }

    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".faceorb")
        return base.appendingPathComponent("FaceOrb", isDirectory: true)
    }

    public init(root: URL = LibraryStore.defaultRoot) {
        self.root = root
    }

    public func load() -> Library {
        guard let data = try? Data(contentsOf: libraryURL),
              let lib = try? JSONDecoder().decode(Library.self, from: data) else { return Library() }
        return lib
    }

    public func save(_ lib: Library) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(lib)
        try data.write(to: libraryURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: libraryURL.path)
    }

    public func albumFolder(for source: String) -> URL {
        albumsURL.appendingPathComponent(source.replacingOccurrences(of: ":", with: "_"), isDirectory: true)
    }

    /// Deletes FaceOrb's downloaded copies of these albums (all of them when nil). Folder imports
    /// are indexed in place, so the user's own files are never touched.
    public func deleteAlbumCopies(sources: Set<String>? = nil) throws {
        let fm = FileManager.default
        let folders = sources.map { $0.map(albumFolder(for:)) } ?? [albumsURL]
        for folder in folders where fm.fileExists(atPath: folder.path) {
            try fm.removeItem(at: folder)
        }
    }

    /// Deletes all signatures, decisions and downloaded album copies. Folder imports are
    /// indexed in place, so the user's own files are never touched.
    public func deleteEverything() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }
}

public enum Privacy {
    /// Drops signatures of faces that are clearly someone else (photo filed as "others" and
    /// face not used as a reference). Face boxes stay so photos still show as analysed.
    /// Returns how many signatures were removed.
    @discardableResult
    public static func forgetBystanders(_ lib: inout Library) -> Int {
        guard lib.references.contains(where: \.positive) else { return 0 }
        let matches = Matcher.match(lib)
        let positives = lib.references.filter(\.positive).map(\.signature)
        let negatives = lib.references.filter { !$0.positive }.map(\.signature)
        let keep = Set(lib.references.compactMap(\.faceID))
        var removed = 0
        for i in lib.faces.indices {
            guard let sig = lib.faces[i].signature, !keep.contains(lib.faces[i].id) else { continue }
            let photoBucket = matches[lib.faces[i].photoID]?.bucket
            let faceScore = Matcher.faceScore(sig, positives: positives, negatives: negatives, k: lib.settings.topK)
            // Keep faces that could still be the user (they may matter after a threshold change).
            if photoBucket == .others || faceScore < lib.settings.reviewThreshold {
                lib.faces[i].signature = nil
                removed += 1
            }
        }
        // Faces the user explicitly rejected stay as (few) negative references: dropping them
        // would let look-alikes they already ruled out drift back into "My photos".
        return removed
    }

    /// Removes albums (all of them when `sources` is nil): their photos, faces, decisions and
    /// "not me" references. What FaceOrb learned about the user stays, since positive references
    /// carry their own signature, so a new album sorts right away; set `keepMe` false to drop that too.
    /// Returns how many photos were removed.
    @discardableResult
    public static func removeAlbums(_ lib: inout Library, sources: Set<String>? = nil, keepMe: Bool = true) -> Int {
        let gone = Set(lib.photos.filter { sources?.contains($0.source) ?? true }.map(\.id))
        let goneFaces = Set(lib.faces.filter { gone.contains($0.photoID) }.map(\.id))
        lib.photos.removeAll { gone.contains($0.id) }
        lib.faces.removeAll { goneFaces.contains($0.id) }
        for id in gone { lib.verdicts[id] = nil }
        for source in sources ?? Set(lib.albums.keys) {
            lib.albums[source] = nil
            lib.albumOrigins[source] = nil
        }
        // Rejections are other people's signatures; drop those that came from the removed photos.
        lib.references.removeAll { !$0.positive && $0.faceID.map(goneFaces.contains) == true }
        for i in lib.references.indices where lib.references[i].faceID.map(goneFaces.contains) == true {
            lib.references[i].faceID = nil
        }
        if !keepMe { forgetMe(&lib) }
        return gone.count
    }

    /// Removes everything learned about the user (references and decisions), keeping the album.
    public static func forgetMe(_ lib: inout Library) {
        lib.references.removeAll()
        lib.verdicts.removeAll()
    }
}

public enum Exporter {
    public static func csv(_ lib: Library, bucket: Bucket? = .mine) -> String {
        let matches = Matcher.match(lib)
        var rows = ["name,bucket,score,decision,path,url"]
        for p in lib.photos {
            guard let m = matches[p.id], bucket == nil || m.bucket == bucket else { continue }
            let fields = [p.name, m.bucket.rawValue, String(format: "%.3f", m.score),
                          lib.verdicts[p.id]?.rawValue ?? "auto", p.localPath, p.remoteURL ?? ""]
            rows.append(fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}
