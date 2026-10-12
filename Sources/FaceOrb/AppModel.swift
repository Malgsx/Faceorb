import AppKit
import FaceOrbCore
import FaceOrbKit
import FaceOrbWeb
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Activity: Equatable {
        case idle
        case importing(done: Int, total: Int)
        case analyzing(done: Int, total: Int)
        case enrolling
        case exporting(done: Int, total: Int)

        var isBusy: Bool { self != .idle }
        var label: String {
            switch self {
            case .idle: "Ready"
            case .importing(let d, let t): "Downloading album… \(d)/\(t)"
            case .analyzing(let d, let t): "Finding faces… \(d)/\(t)"
            case .enrolling: "Learning your face…"
            case .exporting(let d, let t): "Saving photos… \(d)/\(t)"
            }
        }
        var fraction: Double? {
            switch self {
            case .importing(let d, let t), .analyzing(let d, let t), .exporting(let d, let t): t > 0 ? Double(d) / Double(t) : nil
            default: nil
            }
        }
    }

    @Published private(set) var lib: Library
    @Published private(set) var matches: [String: PhotoMatch] = [:]
    @Published private(set) var activity: Activity = .idle
    @Published var lastError: String?
    @Published var notice: String?
    @Published var section: ReviewSection = .bucket(.review)
    /// Last photo decided from the menu bar dropdown, for its Undo button.
    @Published var lastDecided: String?
    @Published private(set) var webURL: URL?

    let store: LibraryStore
    private var embedder: FaceEmbedder?
    private var work: Task<Void, Never>?
    private var webServer: HTTPServer?

    static let webPort: UInt16 = 47615
    @AppStorage("webAppEnabled") var webAppEnabled = true {
        didSet { objectWillChange.send(); webAppEnabled ? startWebApp() : stopWebApp() }
    }

    init(store: LibraryStore = LibraryStore()) {
        self.store = store
        self.lib = store.load()
        rematch()
        if webAppEnabled { startWebApp() }
        warnIfDiskFull()
    }

    /// A nearly full disk makes macOS fail in confusing ways (Finder error -36, apps' databases
    /// reporting "disk I/O error", files that won't delete), so say so plainly.
    func warnIfDiskFull() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let free = DiskCheck.freeBytes(at: home), free < DiskCheck.safetyMargin {
            lastError = "Your Mac is almost out of space (\(DiskCheck.describe(free)) free). Files may fail to save or delete "
                + "until you free some (System Settings > General > Storage)."
        }
    }

    // MARK: Web app

    /// Serves the browser version on 127.0.0.1 only. The key lives in the data folder (0600),
    /// so a bookmarked link keeps working until "Delete all data".
    func startWebApp() {
        guard webServer == nil else { return }
        let api = WebAPI(backend: AppBackend(model: self), token: webToken())
        let server = HTTPServer { await api.handle($0) }
        do {
            api.port = try server.start(preferredPort: Self.webPort)
            webServer = server
            webURL = api.launchURL
        } catch {
            lastError = "Couldn't start the web app: \(error.localizedDescription)"
        }
    }

    func stopWebApp() {
        webServer?.stop()
        webServer = nil
        webURL = nil
    }

    func openWebApp() {
        if webURL == nil { startWebApp() }
        if let webURL { NSWorkspace.shared.open(webURL) }
    }

    private func webToken() -> String {
        let url = store.root.appendingPathComponent("web-token")
        if let t = try? String(contentsOf: url, encoding: .utf8), t.count >= 32 { return t }
        let t = WebAPI.makeToken()
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? t.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return t
    }

    // MARK: Derived state

    var isEnrolled: Bool { lib.references.contains(where: \.positive) }
    var pendingAnalysis: Int { lib.photos.filter { !$0.analyzed }.count }
    var faceCount: Int { lib.faces.count }
    var signatureCount: Int { lib.faces.filter { $0.signature != nil }.count }

    func count(_ bucket: Bucket) -> Int { matches.values.filter { $0.bucket == bucket }.count }

    func photos(in bucket: Bucket) -> [(Photo, PhotoMatch)] {
        lib.photos.compactMap { p in matches[p.id].flatMap { $0.bucket == bucket ? (p, $0) : nil } }
            .sorted { $0.1.score > $1.1.score }
    }

    func faces(in photoID: String) -> [Face] { lib.faces.filter { $0.photoID == photoID } }
    func face(_ id: String) -> Face? { lib.faces.first { $0.id == id } }
    func photo(_ id: String) -> Photo? { lib.photos.first { $0.id == id } }

    var people: [PeopleClusterer.Cluster] { PeopleClusterer.cluster(lib.faces) }

    // MARK: Mutations

    private func commit(_ change: (inout Library) -> Void) {
        change(&lib)
        rematch()
        do { try store.save(lib) } catch { lastError = "Couldn't save: \(error.localizedDescription)" }
    }

    private func rematch() { matches = Matcher.match(lib) }

    private func loadEmbedder() throws -> FaceEmbedder {
        if let embedder { return embedder }
        let e = try FaceEmbedder()
        embedder = e
        return e
    }

    func cancel() {
        work?.cancel()
        work = nil
        activity = .idle
    }

    /// Imports from a link: a Pixieset gallery, a web page with photos, an image, or a .zip.
    func importLink(_ link: String) {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true else {
            lastError = "Paste a full link, starting with https://"
            return
        }
        lastError = nil
        work = Task {
            do {
                let progress: @Sendable (Int, Int) -> Void = { done, total in
                    Task { @MainActor in
                        if case .importing = self.activity { self.activity = .importing(done: done, total: total) }
                    }
                }
                let links = LinkImporter()
                let album = try await links.resolve(url)
                let photos: [Photo], source: String, title: String
                if case .pixieset = album.content {
                    let client = PixiesetClient()
                    let gallery = try await client.resolve(url)
                    // ~400 KB per web-size photo; refuse rather than fill the disk.
                    try DiskCheck.preflight(folder: store.albumFolder(for: gallery.source), needed: Int64(gallery.photos.count) * 450_000)
                    activity = .importing(done: 0, total: gallery.photos.count)
                    photos = try await client.download(gallery, to: store.albumFolder(for: gallery.source), progress: progress)
                    (source, title) = (gallery.source, gallery.title)
                } else {
                    try DiskCheck.preflight(folder: store.albumFolder(for: album.source), needed: album.estimatedBytes)
                    activity = .importing(done: 0, total: 1)
                    photos = try await links.download(album, to: store.albumFolder(for: album.source), progress: progress)
                    (source, title) = (album.source, album.title)
                }
                guard !photos.isEmpty else { throw LinkImporter.ImportError.noPhotos }
                addPhotos(photos, source: source, title: title, origin: AlbumOrigin(link: url.absoluteString))
                await analyzePending()
            } catch is CancellationError {
            } catch {
                lastError = error.localizedDescription
            }
            activity = .idle
        }
    }

    func importFolder(_ folder: URL) {
        lastError = nil
        let photos = FolderImporter.scan(folder)
        guard !photos.isEmpty else { lastError = "No photos found in \(folder.lastPathComponent)."; return }
        addPhotos(photos, source: photos[0].source, title: folder.lastPathComponent, origin: AlbumOrigin())
        work = Task {
            await analyzePending()
            activity = .idle
        }
    }

    /// Scans photos left unscanned by an earlier run (quit mid-scan, or the model failed to load).
    func resumePendingScan() {
        guard !activity.isBusy, pendingAnalysis > 0 else { return }
        work = Task {
            await analyzePending()
            activity = .idle
        }
    }

    private func addPhotos(_ photos: [Photo], source: String, title: String, origin: AlbumOrigin) {
        commit { lib in
            let known = Set(lib.photos.map(\.id))
            lib.photos += photos.filter { !known.contains($0.id) }
            lib.albums[source] = title
            lib.albumOrigins[source] = origin
        }
    }

    // MARK: Albums and save folders, to find them again

    struct AlbumRow: Identifiable {
        var id: String { source }
        var source: String
        var title: String
        /// The folder a folder import came from.
        var folder: URL?
        /// The album link, when it was recorded (imports from before this was kept have none).
        var link: URL?
        var importedAt: Date?
        var photoCount: Int
        /// False when the original folder has been moved or deleted.
        var available: Bool
        /// What to show under the title: the folder path, the link, or where the copies live.
        var detail: String {
            if let folder { return (folder.path as NSString).abbreviatingWithTildeInPath }
            if let link { return link.host.map { $0 + link.path } ?? link.absoluteString }
            return "Downloaded copies on this Mac"
        }
    }

    /// Albums, most recently imported first.
    var albumRows: [AlbumRow] {
        let counts = Dictionary(grouping: lib.photos, by: \.source).mapValues(\.count)
        return lib.albums.map { source, title in
            let origin = lib.albumOrigins[source]
            let folder = Library.folderPath(forSource: source).map { URL(fileURLWithPath: $0, isDirectory: true) }
            return AlbumRow(source: source, title: title, folder: folder, link: origin?.link.flatMap(URL.init(string:)),
                            importedAt: origin?.importedAt, photoCount: counts[source] ?? 0,
                            available: folder.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
        }
        .sorted { ($0.importedAt ?? .distantPast, $1.title) > ($1.importedAt ?? .distantPast, $0.title) }
    }

    /// Opens where an album came from: its folder in Finder, or its web page in the browser.
    /// Older link imports have no saved link, so their downloaded copies are shown instead.
    func openAlbum(_ row: AlbumRow) {
        if let folder = row.folder {
            guard row.available else { lastError = "\(row.title) has been moved or deleted."; return }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else if let link = row.link {
            NSWorkspace.shared.open(link)
        } else {
            revealAlbumCopies(row)
        }
    }

    /// Shows FaceOrb's own downloaded copies of a linked album in Finder.
    func revealAlbumCopies(_ row: AlbumRow) {
        let folder = row.folder ?? store.albumFolder(for: row.source)
        guard FileManager.default.fileExists(atPath: folder.path) else { lastError = "No copies of \(row.title) on this Mac."; return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Imports an album again from where it came from, picking up new photos.
    func reimportAlbum(_ row: AlbumRow) {
        guard !activity.isBusy else { lastError = "FaceOrb is busy. Try again when it finishes."; return }
        if let folder = row.folder {
            guard row.available else { lastError = "\(row.title) has been moved or deleted."; return }
            importFolder(folder)
        } else if let link = row.link {
            importLink(link.absoluteString)
        }
    }

    func copyAlbumLocation(_ row: AlbumRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.folder?.path ?? row.link?.absoluteString ?? row.detail, forType: .string)
    }

    func exportFolderExists(_ record: ExportRecord) -> Bool { FileManager.default.fileExists(atPath: record.folder) }

    func revealExport(_ record: ExportRecord) {
        let url = URL(fileURLWithPath: record.folder, isDirectory: true)
        guard exportFolderExists(record) else { lastError = "\(url.lastPathComponent) has been moved or deleted."; return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func forgetExport(_ record: ExportRecord) {
        commit { $0.exports.removeAll { $0.folder == record.folder } }
    }

    /// Analyses photos in parallel on background threads, saving every batch so a quit
    /// mid-scan loses little.
    func analyzePending() async {
        let pending = lib.photos.filter { !$0.analyzed }
        guard !pending.isEmpty else { return }
        let embedder: FaceEmbedder
        do { embedder = try loadEmbedder() } catch { lastError = error.localizedDescription; return }
        let minPixels = lib.settings.minFacePixels
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        activity = .analyzing(done: 0, total: pending.count)

        var done = 0
        var failed = 0
        var batch: [(String, [Face])] = []
        await withTaskGroup(of: (String, [Face]?).self) { group in
            var next = 0
            func enqueue() {
                guard next < pending.count, !Task.isCancelled else { return }
                let photo = pending[next]; next += 1
                group.addTask(priority: .utility) {
                    // nil leaves the photo unanalysed, so the next run retries it.
                    let faces = try? FaceAnalyzer.analyze(photo: photo, embedder: embedder, minFacePixels: minPixels)
                    return (photo.id, faces)
                }
            }
            for _ in 0..<width { enqueue() }
            while let result = await group.next() {
                if let faces = result.1 { batch.append((result.0, faces)) } else { failed += 1 }
                done += 1
                activity = .analyzing(done: done, total: pending.count)
                if batch.count >= 25 || done == pending.count { flush(&batch) }
                enqueue()
            }
        }
        flush(&batch)
        if failed > 0 && !Task.isCancelled {
            lastError = "\(failed) \(failed == 1 ? "photo" : "photos") couldn't be scanned. FaceOrb will try \(failed == 1 ? "it" : "them") again next time it starts."
        }
        if lib.settings.forgetBystandersAutomatically && isEnrolled { forgetBystanders() }
    }

    private func flush(_ batch: inout [(String, [Face])]) {
        guard !batch.isEmpty else { return }
        let results = batch
        batch.removeAll()
        commit { lib in
            let ids = Set(results.map(\.0))
            lib.faces.removeAll { ids.contains($0.photoID) }
            for (_, faces) in results { lib.faces += faces }
            for i in lib.photos.indices where ids.contains(lib.photos[i].id) { lib.photos[i].analyzed = true }
        }
    }

    // MARK: Enrolment

    func enroll(cluster: PeopleClusterer.Cluster) {
        let refs = PeopleClusterer.references(from: cluster, faces: lib.faces)
        commit { lib in
            lib.references.removeAll { $0.origin == .picked }
            lib.references += refs
        }
        notice = "Matched against \(refs.count) faces of the person you picked."
    }

    func enroll(clusterID: String) -> Bool {
        guard let c = people.first(where: { $0.id == clusterID }) else { return false }
        enroll(cluster: c)
        return true
    }

    /// Selfie bytes from the web app; analysed in memory only.
    func enrollSelfie(data: Data) async throws -> Bool {
        let embedder = try loadEmbedder()
        let sig = try await Task.detached(priority: .userInitiated) {
            try FaceAnalyzer.largestFaceSignature(data: data, embedder: embedder)
        }.value
        guard let sig else { return false }
        commit { $0.references.append(Reference(signature: sig, positive: true, origin: .selfie)) }
        return true
    }

    func enroll(selfies urls: [URL]) {
        activity = .enrolling
        work = Task {
            defer { activity = .idle }
            do {
                let embedder = try loadEmbedder()
                let sigs: [[Float]] = try await Task.detached(priority: .userInitiated) {
                    try urls.compactMap { try FaceAnalyzer.largestFaceSignature(in: $0, embedder: embedder) }
                }.value
                guard !sigs.isEmpty else { lastError = "No clear face found in those photos."; return }
                // Only the 128-number signatures are kept; the selfie files are never copied.
                commit { lib in lib.references += sigs.map { Reference(signature: $0, positive: true, origin: .selfie) } }
                notice = "Learned your face from \(sigs.count) of \(urls.count) selfies."
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: Review

    func decide(_ photoID: String, _ verdict: Verdict, faceID: String? = nil) {
        commit { Matcher.decide(&$0, photoID: photoID, verdict: verdict, faceID: faceID) }
    }

    /// Multi-select: one decision for many photos, saved once.
    func decide(_ photoIDs: [String], _ verdict: Verdict) {
        guard !photoIDs.isEmpty else { return }
        commit { Matcher.decide(&$0, photoIDs: photoIDs, verdict: verdict) }
    }

    func undo(_ photoIDs: [String]) {
        guard !photoIDs.isEmpty else { return }
        commit { Matcher.undo(&$0, photoIDs: photoIDs) }
        if let last = lastDecided, photoIDs.contains(last) { lastDecided = nil }
    }

    func undo(_ photoID: String) {
        commit { Matcher.undo(&$0, photoID: photoID) }
        if lastDecided == photoID { lastDecided = nil }
    }

    /// The photo the dropdown asks about next: the most likely match still in review.
    var nextReview: (Photo, PhotoMatch)? { photos(in: .review).first }

    func setThresholds(auto: Float, review: Float) {
        commit { lib in
            lib.settings.autoThreshold = auto
            lib.settings.reviewThreshold = min(review, auto)
        }
    }

    func setAutoForget(_ on: Bool) { commit { $0.settings.forgetBystandersAutomatically = on } }

    // MARK: Privacy

    func forgetBystanders() {
        var removed = 0
        commit { removed = Privacy.forgetBystanders(&$0) }
        notice = "Deleted \(removed) face signatures of other people."
    }

    func forgetMe() {
        commit { Privacy.forgetMe(&$0) }
        notice = "Deleted your face references and review decisions."
    }

    /// Clears albums (all when `sources` is nil) so new ones can be added from scratch: photos,
    /// faces, decisions and downloaded copies. Keeps who you are unless `keepMe` is false.
    func clearPhotos(sources: Set<String>? = nil, keepMe: Bool = true) {
        cancel()
        var removed = 0
        commit { removed = Privacy.removeAlbums(&$0, sources: sources, keepMe: keepMe) }
        lastDecided = nil
        lastError = nil
        do { try store.deleteAlbumCopies(sources: sources) } catch {
            lastError = "Couldn't delete downloaded copies: \(error.localizedDescription)"
        }
        let what = sources == nil ? "all photos" : "\(removed) photos"
        notice = keepMe ? "Removed \(what). FaceOrb still knows your face." : "Removed \(what) and your face references."
    }

    func removeAlbum(_ row: AlbumRow) { clearPhotos(sources: [row.source]) }

    func deleteEverything() {
        cancel()
        do {
            try store.deleteEverything()
            lib = Library()
            embedder = nil
            rematch()
            if webServer != nil { stopWebApp(); startWebApp() }   // new key; old links stop working
            notice = "All FaceOrb data deleted."
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Export

    func exportCSV(to url: URL) {
        do { try Exporter.csv(lib).write(to: url, atomically: true, encoding: .utf8) } catch { lastError = error.localizedDescription }
    }

    // MARK: Saving photos

    struct ExportResult: Equatable {
        var folder: URL
        var files: [URL]
        var failures: [String]
        /// True only when this save made `folder`, so deleting copies never removes the user's own folder.
        var createdFolder = false
    }

    @Published var showExportSheet = false
    @Published private(set) var lastExport: ExportResult?
    @AppStorage("exportOptions") private var savedOptions = Data()

    var exportOptions: ExportOptions {
        get { (try? JSONDecoder().decode(ExportOptions.self, from: savedOptions)) ?? ExportOptions() }
        set { savedOptions = (try? JSONEncoder().encode(newValue)) ?? Data(); objectWillChange.send() }
    }

    func exportPlan(_ options: ExportOptions) -> [ExportItem] { ExportPlanner.plan(lib, options) }

    /// Saves photos in the chosen format. Checks free space and writability first, writes in the
    /// background, and never leaves half-written files behind.
    func export(_ options: ExportOptions, to base: URL) {
        guard !activity.isBusy else { lastError = "FaceOrb is busy. Try again when it finishes."; return }
        exportOptions = options
        lastError = nil
        let items = exportPlan(options)
        guard !items.isEmpty else { lastError = "There are no photos to save yet."; return }
        guard ImageExporter.canWrite(options.format) else { lastError = "This Mac can't write \(options.format.title) files."; return }
        let subfolder = ExportPlanner.safeName(options.subfolder)
        let folder = subfolder.isEmpty ? base : base.appendingPathComponent(subfolder, isDirectory: true)
        let createdFolder = !FileManager.default.fileExists(atPath: folder.path)
        do {
            try DiskCheck.preflight(folder: folder, needed: ExportPlanner.estimatedBytes(items, options))
        } catch {
            lastError = error.localizedDescription
            return
        }

        activity = .exporting(done: 0, total: items.count)
        work = Task {
            var files: [URL] = [], failures: [String] = []
            for (i, item) in items.enumerated() {
                if Task.isCancelled { break }
                let dest = folder.appendingPathComponent(item.fileName)
                if FileManager.default.fileExists(atPath: dest.path) {
                    failures.append("\(item.fileName): already exists, skipped")
                } else {
                    let src = URL(fileURLWithPath: item.photo.localPath)
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try ImageExporter.export(src, to: dest, options: options)
                        }.value
                        files.append(dest)
                    } catch {
                        failures.append("\(item.fileName): \(error.localizedDescription)")
                        // A full disk fails every file the same way; stop and explain instead.
                        if let free = DiskCheck.freeBytes(at: folder), free < 200_000_000 {
                            failures.append("Stopped: the disk is full.")
                            break
                        }
                    }
                }
                if Task.isCancelled { break }
                activity = .exporting(done: i + 1, total: items.count)
            }
            lastExport = ExportResult(folder: folder, files: files, failures: failures, createdFolder: createdFolder)
            if !files.isEmpty { commit { $0.recordExport(folder: folder.path, count: files.count) } }
            // cancel() already reset activity, and another task may own it now.
            guard !Task.isCancelled else { return }
            activity = .idle
            let real = failures.filter { !$0.hasSuffix("already exists, skipped") }
            if real.isEmpty {
                notice = "Saved \(files.count) photos to \(folder.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } else {
                lastError = "Saved \(files.count), \(real.count) failed. First: \(real[0])"
                warnIfDiskFull()
            }
        }
    }

    /// Deletes the files the last save created (straight away, not via the Trash).
    func deleteLastExport() {
        guard let result = lastExport else { return }
        var failed: [String] = []
        for url in result.files {
            do { try FileManager.default.removeItem(at: url) } catch { failed.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        // Temp files a failed write couldn't clean up (see ImageExporter.export).
        for name in (try? FileManager.default.contentsOfDirectory(atPath: result.folder.path)) ?? []
        where name.hasPrefix(".faceorb-") && name.hasSuffix(".tmp") {
            try? FileManager.default.removeItem(at: result.folder.appendingPathComponent(name))
        }
        if result.createdFolder, (try? FileManager.default.contentsOfDirectory(atPath: result.folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: result.folder)
        }
        lastExport = nil
        if failed.isEmpty {
            notice = "Deleted the \(result.files.count) saved copies."
        } else {
            lastError = "\(failed.count) copies couldn't be deleted. First: \(failed[0])"
            warnIfDiskFull()
        }
    }

    func revealData() { NSWorkspace.shared.activateFileViewerSelecting([store.root]) }
}
