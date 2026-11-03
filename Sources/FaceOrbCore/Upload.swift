import Foundation

/// Photos added as files rather than by link or folder: picked or dropped in the Mac app, or
/// uploaded from a phone's browser (its photo library, iCloud Drive, Google Drive, …).
/// FaceOrb keeps its own copy, so a cloud file that is later removed from the device still works.
public enum Uploads {
    public enum UploadError: LocalizedError {
        case notAPhoto(String)
        public var errorDescription: String? {
            switch self {
            case .notAPhoto(let name): "\(name) isn't a photo or a .zip of photos."
            }
        }
    }

    /// One album per batch of files added together.
    public static func source(batch: String) -> String { "upload:\(batch)" }

    /// A batch id from the browser: short, and safe as part of a folder name.
    public static func isValidBatch(_ batch: String) -> Bool {
        !batch.isEmpty && batch.count <= 40 && batch.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Copies a photo into `folder`, or unpacks a .zip of photos there, and returns the photos.
    /// `name` is the file's original name (for display); the copy is named by content, so adding
    /// the same file twice keeps one copy.
    public static func save(file: URL, name: String, source: String, into folder: URL) throws -> [Photo] {
        let display = (name as NSString).lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        let head = (try? FileHandle(forReadingFrom: file)).map { h -> Data in defer { try? h.close() }; return h.readData(ofLength: 16) } ?? Data()
        let key = LinkImporter.hash("\(display)|\(size)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        if LinkImporter.isZip(head) {
            let dest = folder.appendingPathComponent(key, isDirectory: true)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            // ditto stops at entries it can't write (a stray __MACOSX file, say) after unpacking the
            // rest, so keep what it unpacked; only an empty result is an error.
            let unzipError: Error?
            do { try LinkImporter.unzip(file, into: dest); unzipError = nil } catch { unzipError = error }
            let base = folder.standardizedFileURL.path
            let photos = FolderImporter.scan(dest)
                .filter { !$0.localPath.contains("/__MACOSX/") }
                .map { p in
                    let rel = String(p.localPath.dropFirst(base.count))
                    return Photo(id: "\(source)\(rel)", name: p.name, source: source, localPath: p.localPath)
                }
            if photos.isEmpty { throw unzipError ?? UploadError.notAPhoto(display) }
            return photos
        }
        let ext = LinkImporter.imageExtension(for: head)
            ?? (FolderImporter.imageExtensions.contains((display as NSString).pathExtension.lowercased()) ? (display as NSString).pathExtension.lowercased() : nil)
        guard let ext else { throw UploadError.notAPhoto(display) }
        let dest = folder.appendingPathComponent("\(key).\(ext)")
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.copyItem(at: file, to: dest)
        }
        return [Photo(id: "\(source)/\(key)", name: display, source: source, localPath: dest.path)]
    }

    /// The same, for bytes uploaded from a browser.
    public static func save(data: Data, name: String, source: String, into folder: URL) throws -> [Photo] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("faceorb-upload-\(UUID().uuidString)")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try save(file: tmp, name: name, source: source, into: folder)
    }
}
