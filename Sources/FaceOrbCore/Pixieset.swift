import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Imports a public Pixieset client gallery.
///
/// Pixieset has no public API for client galleries. This uses the same JSON listing the
/// gallery web page calls (`/client/loadphotos/`), only for galleries viewable without a
/// password, downloads the 1600px web copies (not originals), and paces requests.
/// It can break whenever Pixieset changes their page, so a folder import is always offered too.
public struct PixiesetClient: Sendable {
    public struct Gallery: Sendable {
        public var title: String
        public var baseURL: URL
        public var collectionKey: String
        public var collectionID: String
        public var photos: [RemotePhoto]
        public var source: String { "pixieset:\(collectionID)" }
    }

    public struct RemotePhoto: Codable, Sendable, Hashable {
        public var id: Int64
        public var name: String
        public var pathXlarge: String?
        public var pathXxlarge: String?
        public var pathMedium: String?
        public var webURL: URL? {
            (pathXxlarge ?? pathXlarge ?? pathMedium).flatMap { URL(string: $0.hasPrefix("//") ? "https:" + $0 : $0) }
        }
    }

    public enum ImportError: LocalizedError {
        case notPixieset, notPublic, listingFailed(String)
        public var errorDescription: String? {
            switch self {
            case .notPixieset: "That link doesn't look like a Pixieset gallery."
            case .notPublic: "This gallery needs a password or email sign-in. Download it as a ZIP from Pixieset and import the folder instead."
            case .listingFailed(let s): "Pixieset refused the photo list (\(s))."
            }
        }
    }

    public var session: URLSession
    public var userAgent = "FaceOrb/0.1 (personal photo sorting)"

    public init(session: URLSession = .shared) { self.session = session }

    private func get(_ url: URL, ajax: Bool = false) async throws -> (Data, URL) {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if ajax { req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With") }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImportError.listingFailed("HTTP \(http.statusCode)")
        }
        return (data, resp.url ?? url)
    }

    static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func allMatches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: 1), in: s).map { String(s[$0]) }
        }
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (k, v) in [("&#039;", "'"), ("&#39;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out
    }

    /// Parses the gallery page's inline config. Exposed for tests.
    static func parsePage(_ html: String) -> (key: String?, id: String?, slugs: [String], title: String?) {
        let key = firstMatch(#"'collectionUrlKey':'([^']+)'"#, in: html)
        let id = firstMatch(#"'collectionId':(\d+)"#, in: html)
        var slugs: [String] = []
        if let range = html.range(of: "'allGalleries':") {
            let tail = html[range.upperBound...]
            let segment = tail.split(separator: "]", maxSplits: 1).first.map(String.init) ?? ""
            slugs = allMatches(#"'slug':'([^']+)'"#, in: segment)
        }
        let title = firstMatch(#"<title>\s*([^<]+?)\s*</title>"#, in: html).map(decodeEntities)
        return (key, id, slugs.isEmpty ? ["photos"] : slugs, title)
    }

    public func resolve(_ shareLink: URL) async throws -> Gallery {
        let (data, finalURL) = try await get(shareLink)
        var html = String(decoding: data, as: UTF8.self)
        var page = Self.parsePage(html)
        guard let key = page.key, var base = URL(string: "/", relativeTo: finalURL)?.absoluteURL else { throw ImportError.notPixieset }
        if page.id == nil {
            // Single-photo share links land on a photo page; the gallery lives at /<key>/.
            let (d2, u2) = try await get(base.appendingPathComponent(key + "/"))
            html = String(decoding: d2, as: UTF8.self)
            page = Self.parsePage(html)
            base = URL(string: "/", relativeTo: u2)?.absoluteURL ?? base
        }
        guard let cid = page.id else { throw ImportError.notPublic }

        struct Listing: Decodable { var status: String; var content: String? }
        var photos: [RemotePhoto] = []
        for slug in page.slugs {
            var comps = URLComponents(url: base.appendingPathComponent("client/loadphotos/"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [.init(name: "cuk", value: key), .init(name: "cid", value: cid),
                                .init(name: "gs", value: slug), .init(name: "page", value: "0"), .init(name: "all", value: "1")]
            let (d, _) = try await get(comps.url!, ajax: true)
            let listing = try JSONDecoder().decode(Listing.self, from: d)
            guard listing.status == "success" else { throw ImportError.listingFailed(listing.status) }
            if let content = listing.content, !content.isEmpty {
                photos += try JSONDecoder().decode([RemotePhoto].self, from: Data(content.utf8))
            }
        }
        return Gallery(title: page.title ?? key, baseURL: base, collectionKey: key, collectionID: cid, photos: photos)
    }

    /// Downloads web-size copies into `folder`, skipping files already present.
    public func download(_ gallery: Gallery, to folder: URL, concurrency: Int = 4,
                         progress: @Sendable @escaping (Int, Int) -> Void) async throws -> [Photo] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let items = gallery.photos
        let total = items.count
        var result: [Photo] = []
        try await withThrowingTaskGroup(of: Photo?.self) { group in
            var next = 0, done = 0
            func enqueue() {
                guard next < items.count else { return }
                let item = items[next]; next += 1
                group.addTask {
                    guard let url = item.webURL else { return nil }
                    let dest = folder.appendingPathComponent("\(item.id).jpg")
                    if !FileManager.default.fileExists(atPath: dest.path) {
                        var lastError: Error?
                        for attempt in 0..<3 {
                            do {
                                let (data, _) = try await get(url)
                                try data.write(to: dest, options: .atomic)
                                lastError = nil
                                break
                            } catch {
                                lastError = error
                                try await Task.sleep(nanoseconds: UInt64(500_000_000 << attempt))
                            }
                        }
                        if let lastError { throw lastError }
                        try await Task.sleep(nanoseconds: 100_000_000)   // be polite to the host
                    }
                    return Photo(id: "\(gallery.source)/\(item.id)", name: item.name, source: gallery.source,
                                 localPath: dest.path, remoteURL: url.absoluteString)
                }
            }
            for _ in 0..<concurrency { enqueue() }
            while let photo = try await group.next() {
                if let photo { result.append(photo) }
                done += 1
                progress(done, total)
                enqueue()
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public enum FolderImporter {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff"]

    /// Indexes images in place (no copy).
    public static func scan(_ folder: URL) -> [Photo] {
        let source = "folder:\(folder.standardizedFileURL.path)"
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var photos: [Photo] = []
        for case let url as URL in walker where imageExtensions.contains(url.pathExtension.lowercased()) {
            let rel = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
            photos.append(Photo(id: "\(source)\(rel)", name: url.lastPathComponent, source: source, localPath: url.path))
        }
        return photos.sorted { $0.localPath.localizedStandardCompare($1.localPath) == .orderedAscending }
    }
}
