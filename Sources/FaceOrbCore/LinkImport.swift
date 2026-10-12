import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Imports photos from any link: a web page with photos on it, a direct image link, or a .zip
/// of photos. Dropbox share links are switched to their download form, and Pixieset galleries
/// (including photographers' own domains) are recognised so PixiesetClient can take over.
///
/// Pages that need a sign-in or build their gallery with JavaScript (Google Photos, iCloud)
/// show no photos to a plain download; for those, download the album and import the folder.
public struct LinkImporter: Sendable {
    public enum Content: Sendable {
        case pixieset
        /// Photos to download, then ones to try if none of those turn out to be photos.
        case images([URL], fallback: [URL] = [])
        case zip(URL)          // already downloaded to a temporary file
    }

    public struct Album: Sendable {
        public var title: String
        public var source: String
        public var content: Content
        /// Rough download size, for the disk space check.
        public var estimatedBytes: Int64
    }

    public enum ImportError: LocalizedError {
        case noPhotos, httpStatus(Int), unzipFailed
        public var errorDescription: String? {
            switch self {
            case .noPhotos: "No photos found at that link. If the album needs a sign-in or is on Google Photos or iCloud, download it and choose the folder instead."
            case .httpStatus(let code): "The link answered with an error (HTTP \(code))."
            case .unzipFailed: "Couldn't open the .zip file."
            }
        }
    }

    public var session: URLSession
    public var userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) FaceOrb/0.1 (personal photo sorting)"
    /// Smaller downloads are icons, logos and thumbnails, not photos.
    public var minimumPhotoBytes = 20_000

    public init(session: URLSession = .shared) { self.session = session }

    /// A stable album id for a link, so importing it again adds to the same album.
    public static func source(for link: URL) -> String { "link:\(hash(link.absoluteString))" }

    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// Dropbox "?dl=0" links open a preview page; "?dl=1" returns the file, or a .zip of a folder.
    static func directDownloadURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(), host == "dropbox.com" || host.hasSuffix(".dropbox.com"),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.queryItems = (comps.queryItems ?? []).filter { $0.name != "dl" && $0.name != "raw" } + [.init(name: "dl", value: "1")]
        return comps.url ?? url
    }

    /// The file type of downloaded bytes, or nil if they aren't a photo FaceOrb can read.
    static func imageExtension(for data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 12 else { return nil }
        if b[0] == 0xFF, b[1] == 0xD8 { return "jpg" }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b[0...3].elementsEqual([0x52, 0x49, 0x46, 0x46]), b[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) { return "webp" }
        if b[0...3].elementsEqual([0x49, 0x49, 0x2A, 0x00]) || b[0...3].elementsEqual([0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if b[4...7].elementsEqual([0x66, 0x74, 0x79, 0x70]) {   // "ftyp": HEIC/HEIF/AVIF family
            let brand = String(decoding: b[8...11], as: UTF8.self)
            if ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"].contains(brand) { return "heic" }
        }
        return nil
    }

    static func isZip(_ data: Data) -> Bool { data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04]) }

    /// Photo addresses on a web page. When the page links to full-size images (a gallery of
    /// thumbnails), only those links are used, so each photo isn't downloaded twice; the images
    /// shown on the page are the fallback, for sites whose ".jpg" links lead to web pages.
    static func imageURLs(inPage html: String, base: URL) -> (primary: [URL], fallback: [URL]) {
        let ext = #"\.(?:jpe?g|png|heic|heif|webp|tiff?)(?:[?#][^"'\s]*)?"#
        let linked = PixiesetClient.allMatches(#"(?i)<a\b[^>]*?\bhref\s*=\s*["']([^"']+?"# + ext + #")["']"#, in: html)

        var embedded: [String] = []
        for tag in PixiesetClient.allMatches(#"(?i)(<(?:img|source)\b[^>]*>)"#, in: html) {
            for attr in ["srcset", "data-srcset"] {
                if let set = PixiesetClient.firstMatch(#"(?i)\b"# + attr + #"\s*=\s*["']([^"']+)["']"#, in: tag) {
                    embedded += largestInSrcset(set).map { [$0] } ?? []
                }
            }
            for attr in ["data-full", "data-large", "data-original", "data-lazy-src", "data-src", "src"] {
                if let v = PixiesetClient.firstMatch(#"(?i)\b"# + attr + #"\s*=\s*["']([^"']+)["']"#, in: tag) { embedded.append(v) }
            }
        }
        embedded += PixiesetClient.allMatches(#"(?i)<meta\b[^>]*?property\s*=\s*["']og:image["'][^>]*?content\s*=\s*["']([^"']+)["']"#, in: html)

        func clean(_ list: [String]) -> [URL] {
            var seen = Set<String>()
            return list.compactMap { raw -> URL? in
                let s = PixiesetClient.decodeEntities(raw.trimmingCharacters(in: .whitespaces))
                guard !s.hasPrefix("data:"), let url = URL(string: s, relativeTo: base)?.absoluteURL,
                      url.scheme == "https" || url.scheme == "http" else { return nil }
                guard !["svg", "gif", "ico"].contains(url.pathExtension.lowercased()) else { return nil }
                return seen.insert(url.absoluteString).inserted ? url : nil
            }
        }
        let shown = clean(embedded), links = clean(linked)
        return links.isEmpty ? (shown, []) : (links, shown)
    }

    /// The widest candidate in a srcset ("a.jpg 400w, b.jpg 1600w"); the last one if none has a width.
    static func largestInSrcset(_ set: String) -> String? {
        let candidates = set.split(separator: ",").map { $0.split(separator: " ", omittingEmptySubsequences: true) }
            .filter { !$0.isEmpty }
        let best = candidates.max { a, b in width(a) < width(b) } ?? candidates.last
        return best.map { String($0[0]) }
    }

    private static func width(_ candidate: [Substring]) -> Double {
        guard candidate.count > 1 else { return 0 }
        return Double(candidate[1].dropLast()) ?? 0
    }

    static func pageTitle(_ html: String) -> String? {
        let raw = PixiesetClient.firstMatch(#"<meta\b[^>]*?property\s*=\s*["']og:title["'][^>]*?content\s*=\s*["']([^"']+)["']"#, in: html)
            ?? PixiesetClient.firstMatch(#"<title[^>]*>\s*([^<]+?)\s*</title>"#, in: html)
        return raw.map(PixiesetClient.decodeEntities)
    }

    private func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    /// Downloads to a temporary file, so a large .zip never sits in memory.
    private func fetch(_ url: URL) async throws -> (file: URL, response: URLResponse) {
        #if canImport(Darwin)
        let (tmp, resp) = try await session.download(for: request(url))
        // The system deletes its temporary file when this returns, so keep our own copy.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("faceorb-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: tmp, to: file)
        #else
        let (data, resp) = try await session.data(for: request(url))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("faceorb-\(UUID().uuidString)")
        try data.write(to: file)
        #endif
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: file)
            throw ImportError.httpStatus(http.statusCode)
        }
        return (file, resp)
    }

    public func resolve(_ link: URL) async throws -> Album {
        let (file, resp) = try await fetch(Self.directDownloadURL(link))
        let finalURL = resp.url ?? link
        let source = Self.source(for: link)
        let fallbackTitle = finalURL.host ?? link.absoluteString
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        let head = (try? FileHandle(forReadingFrom: file)).map { h -> Data in defer { try? h.close() }; return h.readData(ofLength: 16) } ?? Data()

        if Self.isZip(head) {
            let name = resp.suggestedFilename.map { ($0 as NSString).deletingPathExtension }
            return Album(title: name ?? fallbackTitle, source: source, content: .zip(file), estimatedBytes: size * 2)
        }
        if Self.imageExtension(for: head) != nil {
            try? FileManager.default.removeItem(at: file)
            return Album(title: resp.suggestedFilename ?? fallbackTitle, source: source, content: .images([finalURL]), estimatedBytes: size)
        }

        let html = String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
        try? FileManager.default.removeItem(at: file)
        let title = Self.pageTitle(html) ?? fallbackTitle
        if PixiesetClient.parsePage(html).key != nil {
            return Album(title: title, source: source, content: .pixieset, estimatedBytes: 0)
        }
        let images = Self.imageURLs(inPage: html, base: finalURL)
        guard !images.primary.isEmpty else { throw ImportError.noPhotos }
        return Album(title: title, source: source, content: .images(images.primary, fallback: images.fallback),
                     estimatedBytes: Int64(images.primary.count) * 1_500_000)
    }

    /// Downloads the album's photos into `folder`, skipping ones already there, and returns them.
    public func download(_ album: Album, to folder: URL, concurrency: Int = 4,
                         progress: @Sendable @escaping (Int, Int) -> Void) async throws -> [Photo] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch album.content {
        case .pixieset:
            return []
        case .zip(let file):
            defer { try? FileManager.default.removeItem(at: file) }
            progress(0, 1)
            try Self.unzip(file, into: folder)
            progress(1, 1)
            return FolderImporter.scan(folder)
                .filter { !$0.localPath.contains("/__MACOSX/") }
                .map { p in
                    let rel = String(p.localPath.dropFirst(folder.standardizedFileURL.path.count))
                    return Photo(id: "\(album.source)\(rel)", name: p.name, source: album.source, localPath: p.localPath)
                }
        case .images(let urls, let fallback):
            do {
                return try await downloadImages(urls, album: album, to: folder, concurrency: concurrency, progress: progress)
            } catch ImportError.noPhotos where !fallback.isEmpty {
                return try await downloadImages(fallback, album: album, to: folder, concurrency: concurrency, progress: progress)
            }
        }
    }

    private func downloadImages(_ urls: [URL], album: Album, to folder: URL, concurrency: Int,
                                progress: @Sendable @escaping (Int, Int) -> Void) async throws -> [Photo] {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let minimum = urls.count > 1 ? minimumPhotoBytes : 0
        var result: [(Int, Photo)] = []
        try await withThrowingTaskGroup(of: (Int, Photo)?.self) { group in
            var next = 0, done = 0
            func enqueue() {
                guard next < urls.count else { return }
                let index = next, url = urls[next]; next += 1
                group.addTask {
                    let key = Self.hash(url.absoluteString)
                    let name = url.lastPathComponent.removingPercentEncoding.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 } ?? "Photo \(index + 1)"
                    if let file = existing.first(where: { ($0 as NSString).deletingPathExtension == key }) {
                        let path = folder.appendingPathComponent(file).path
                        return (index, Photo(id: "\(album.source)/\(key)", name: name, source: album.source, localPath: path, remoteURL: url.absoluteString))
                    }
                    var data = Data()
                    for attempt in 0..<3 {
                        do {
                            let (d, resp) = try await session.data(for: request(url))
                            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
                            data = d
                            break
                        } catch {
                            if attempt == 2 { return nil }   // one broken image shouldn't stop the album
                            try await Task.sleep(nanoseconds: UInt64(500_000_000 << attempt))
                        }
                    }
                    guard data.count >= minimum, let ext = Self.imageExtension(for: data) else { return nil }
                    let dest = folder.appendingPathComponent("\(key).\(ext)")
                    try data.write(to: dest, options: .atomic)
                    try await Task.sleep(nanoseconds: 100_000_000)   // be polite to the host
                    return (index, Photo(id: "\(album.source)/\(key)", name: name, source: album.source, localPath: dest.path, remoteURL: url.absoluteString))
                }
            }
            for _ in 0..<concurrency { enqueue() }
            while let item = try await group.next() {
                if let item { result.append(item) }
                done += 1
                progress(done, urls.count)
                enqueue()
            }
        }
        guard !result.isEmpty else { throw ImportError.noPhotos }
        return result.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func unzip(_ file: URL, into folder: URL) throws {
        let p = Process()
        #if os(macOS)
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", file.path, folder.path]
        #else
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-o", "-q", file.path, "-d", folder.path]
        #endif
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ImportError.unzipFailed }
    }
}
