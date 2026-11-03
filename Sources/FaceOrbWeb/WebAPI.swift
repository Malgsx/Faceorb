import FaceOrbCore
import Foundation

/// What the web app needs from whoever owns the library: the menu bar app on a Mac,
/// or `HeadlessBackend` in tests and the simulator.
public protocol FaceOrbBackend: AnyObject, Sendable {
    func snapshot() async -> BackendSnapshot
    /// Returns a short message for the user, if any.
    func perform(_ action: BackendAction) async throws -> String?
    /// Encoded image (data, MIME type) for a photo, long side at most `maxPixel`.
    func image(photoID: String, maxPixel: Int) async -> (Data, String)?
    func enrollSelfie(_ imageData: Data) async throws -> Bool
}

public struct BackendSnapshot: Sendable {
    public var lib: Library
    public var busy: Bool
    public var activity: String
    public var fraction: Double?
    public var error: String?
    /// Nil while phone access is off.
    public var phone: PhoneAccess?
    public init(lib: Library, busy: Bool = false, activity: String = "Ready", fraction: Double? = nil, error: String? = nil,
                phone: PhoneAccess? = nil) {
        self.lib = lib; self.busy = busy; self.activity = activity; self.fraction = fraction; self.error = error; self.phone = phone
    }
}

/// How a phone on the same network reaches the web app.
public struct PhoneAccess: Sendable {
    /// The link (with key) to open on the phone; nil when the Mac isn't on a network.
    public var url: String?
    /// A QR code of `url` as PNG.
    public var qrPNG: Data?
    public init(url: String?, qrPNG: Data?) { self.url = url; self.qrPNG = qrPNG }
}

public enum BackendAction: Sendable {
    case decide(photoID: String, verdict: Verdict, faceID: String?)
    case undo(photoID: String)
    case decideMany(photoIDs: [String], verdict: Verdict)
    case undoMany(photoIDs: [String])
    case enroll(clusterID: String)
    case thresholds(auto: Float, review: Float)
    case autoForget(Bool)
    case forgetOthers, forgetMe, deleteAll, cancel
    /// Removes every album (photos, faces, decisions, copies) so new ones can be added.
    case clearPhotos(keepMe: Bool)
    case importLink(String)
    case importFolder(String)
    case export(ExportOptions, folder: String)
    case deleteLastExport
    /// Opens the web app to phones on the local network, or closes it again.
    case phoneAccess(Bool)
    /// One file from the browser (a photo, or a .zip of photos), added to the album for `batch`.
    case upload(Data, name: String, batch: String, title: String)
    /// The browser finished uploading `batch`: scan the new photos.
    case uploadDone(batch: String)
}

/// JSON API + static web app, protected for a loopback server:
/// - a random token (in the URL the menu bar opens, then a SameSite=Strict cookie),
/// - a Host check against DNS rebinding (with phone access on, this Mac's own network addresses also pass),
/// - a custom header on writes so other web pages can't post to it.
public final class WebAPI: @unchecked Sendable {
    public let backend: FaceOrbBackend
    public let token: String
    public var port: UInt16 = 0
    /// Extra Host values to accept (only for the headless demo behind a trusted proxy; the Mac app never sets it).
    public var extraAllowedHosts: Set<String> = []
    /// Accept requests addressed to this machine's network addresses (phone access).
    public var allowLAN = false
    /// Network addresses `allowLAN` accepts; replaceable in tests.
    var lanAddresses: () -> [String] = HTTPServer.lanAddresses

    public init(backend: FaceOrbBackend, token: String) {
        self.backend = backend
        self.token = token
    }

    public static func makeToken() -> String {
        (0..<32).map { _ in String("abcdefghijkmnopqrstuvwxyz23456789".randomElement()!) }.joined()
    }

    public var launchURL: URL { URL(string: "http://127.0.0.1:\(port)/?t=\(token)")! }

    // MARK: Wire types

    struct PhotoDTO: Encodable {
        var id: String, name: String, bucket: String, score: Float
        var verdict: String?, bestFace: String?, bestBox: NormRect?, album: String
    }
    struct StateDTO: Encodable {
        var busy: Bool, activity: String, fraction: Double?, error: String?
        var enrolled: Bool, counts: [String: Int]
        var settings: MatchSettings
        var stats: [String: Int]
        var albums: [String: String]
        var freeDisk: Int64?
        var phone: PhoneDTO?
        var photos: [PhotoDTO]
    }
    struct FaceDTO: Encodable { var id: String; var box: NormRect; var hasSignature: Bool }
    struct PersonDTO: Encodable {
        var id: String, photoCount: Int, picked: Bool
        var photoID: String, box: NormRect
    }
    struct ActionResult: Encodable { var ok: Bool; var message: String? }
    struct PhoneDTO: Encodable { var url: String? }

    // MARK: Routing

    public func handle(_ req: HTTPServer.Request) async -> HTTPServer.Response {
        guard hostAllowed(req.headers["host"]) else { return .text("Forbidden host", status: 403) }

        // Home-screen icons hold nothing private, and phones fetch them without the key.
        if req.method == "GET", let size = ["/icon-180.png": 180, "/icon-192.png": 192, "/icon-512.png": 512][req.path] {
            return HTTPServer.Response(headers: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"], body: AppIcon.png(size: size))
        }

        let cookieToken = req.headers["cookie"]?.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("faceorb=") }?.dropFirst("faceorb=".count)
        let authorized = cookieToken.map(String.init) == token || req.query["t"] == token
        guard authorized else {
            return .text(Self.lockedPage, status: 403, type: "text/html; charset=utf-8")
        }

        if req.method == "GET" && req.path == "/" {
            // The manifest link carries the key, because browsers may fetch it without cookies.
            var r = HTTPServer.Response.text(WebAppPage.html.replacingOccurrences(of: "{{TOKEN}}", with: token), type: "text/html; charset=utf-8")
            r.headers["Set-Cookie"] = "faceorb=\(token); Path=/; HttpOnly; SameSite=Strict"
            r.headers["Cache-Control"] = "no-store"
            r.headers["Content-Security-Policy"] = "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'"
            if req.query["t"] != nil {   // drop the token from the address bar
                r = HTTPServer.Response(status: 302, headers: ["Location": "/", "Set-Cookie": r.headers["Set-Cookie"]!])
            }
            return r
        }

        if req.method == "POST" {
            guard req.headers["x-faceorb"] == "1" else { return .text("Missing header", status: 403) }
            return await post(req)
        }

        switch req.path {
        case "/manifest.webmanifest":
            // Installed apps start from start_url, which logs them in again with the key: home-screen
            // apps on iOS don't share Safari's cookies.
            let manifest: [String: Any] = [
                "name": "FaceOrb", "short_name": "FaceOrb", "id": "/", "scope": "/",
                "start_url": "/?t=\(token)", "display": "standalone",
                "background_color": "#141416", "theme_color": "#141416",
                "icons": [
                    ["src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any"],
                    ["src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any"],
                    ["src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable"],
                ],
            ]
            let data = (try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return HTTPServer.Response(headers: ["Content-Type": "application/manifest+json", "Cache-Control": "no-store"], body: data)
        case "/qr.png":
            guard let png = await backend.snapshot().phone?.qrPNG else { return .text("Phone access is off", status: 404) }
            return HTTPServer.Response(headers: ["Content-Type": "image/png", "Cache-Control": "no-store"], body: png)
        case "/api/state": return .json(await state())
        case "/api/photo":
            guard let id = req.query["id"] else { return .text("id?", status: 400) }
            let lib = await backend.snapshot().lib
            return .json(lib.faces.filter { $0.photoID == id }.map { FaceDTO(id: $0.id, box: $0.box, hasSignature: $0.signature != nil) })
        case "/api/people":
            let lib = await backend.snapshot().lib
            let picked = Set(lib.references.filter(\.positive).compactMap(\.faceID))
            let faces = Dictionary(uniqueKeysWithValues: lib.faces.map { ($0.id, $0) })
            let people = PeopleClusterer.cluster(lib.faces).compactMap { c -> PersonDTO? in
                guard let f = faces[c.id] else { return nil }
                return PersonDTO(id: c.id, photoCount: c.photoCount, picked: c.faceIDs.contains(where: picked.contains),
                                 photoID: f.photoID, box: f.box)
            }
            return .json(people)
        case "/img":
            guard let id = req.query["id"] else { return .text("id?", status: 400) }
            let px = min(max(Int(req.query["px"] ?? "") ?? 400, 64), 2400)
            guard let (data, type) = await backend.image(photoID: id, maxPixel: px) else { return .text("not found", status: 404) }
            return HTTPServer.Response(headers: ["Content-Type": type, "Cache-Control": "private, max-age=3600"], body: data)
        case "/export.csv":
            let lib = await backend.snapshot().lib
            return HTTPServer.Response(headers: ["Content-Type": "text/csv; charset=utf-8",
                                                 "Content-Disposition": "attachment; filename=\"my-photos.csv\""],
                                       body: Data(Exporter.csv(lib).utf8))
        default:
            return .text("Not found", status: 404)
        }
    }

    private func hostAllowed(_ host: String?) -> Bool {
        guard let host else { return false }
        if host == "127.0.0.1:\(port)" || host == "localhost:\(port)" || extraAllowedHosts.contains(host) { return true }
        return allowLAN && lanAddresses().contains { host == "\($0):\(port)" }
    }

    private func state() async -> StateDTO {
        let snap = await backend.snapshot()
        let lib = snap.lib
        let matches = Matcher.match(lib)
        var counts: [String: Int] = [:]
        let boxes = Dictionary(uniqueKeysWithValues: lib.faces.map { ($0.id, $0.box) })
        let photos: [PhotoDTO] = lib.photos.compactMap { p in
            guard let m = matches[p.id] else { return nil }
            counts[m.bucket.rawValue, default: 0] += 1
            return PhotoDTO(id: p.id, name: p.name, bucket: m.bucket.rawValue, score: m.score,
                            verdict: lib.verdicts[p.id]?.rawValue, bestFace: m.bestFaceID,
                            bestBox: m.bestFaceID.flatMap { boxes[$0] }, album: lib.albums[p.source] ?? p.source)
        }
        .sorted { $0.score > $1.score }
        let stats = [
            "photos": lib.photos.count,
            "faces": lib.faces.count,
            "signatures": lib.faces.filter { $0.signature != nil }.count,
            "references": lib.references.filter(\.positive).count,
            "pending": lib.photos.filter { !$0.analyzed }.count,
        ]
        return StateDTO(busy: snap.busy, activity: snap.activity, fraction: snap.fraction, error: snap.error,
                        enrolled: lib.references.contains(where: \.positive), counts: counts, settings: lib.settings,
                        stats: stats, albums: lib.albums,
                        freeDisk: DiskCheck.freeBytes(at: URL(fileURLWithPath: NSHomeDirectory())),
                        phone: snap.phone.map { PhoneDTO(url: $0.url) }, photos: photos)
    }

    private func post(_ req: HTTPServer.Request) async -> HTTPServer.Response {
        if req.path == "/api/upload" {
            guard let batch = req.query["batch"], Uploads.isValidBatch(batch), let name = req.query["name"], !name.isEmpty,
                  !req.body.isEmpty else { return .text("bad request", status: 400) }
            let title = req.query["title"].flatMap { $0.isEmpty ? nil : String($0.prefix(120)) } ?? "Uploaded photos"
            do {
                return .json(ActionResult(ok: true, message: try await backend.perform(.upload(req.body, name: name, batch: batch, title: title))))
            } catch {
                return .json(ActionResult(ok: false, message: error.localizedDescription), status: 400)
            }
        }
        if req.path == "/api/selfie" {
            do {
                let ok = try await backend.enrollSelfie(req.body)
                return .json(ActionResult(ok: ok, message: ok ? "Learned your face from that photo." : "No clear face in that photo."))
            } catch {
                return .json(ActionResult(ok: false, message: error.localizedDescription), status: 400)
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
        func str(_ k: String) -> String? { body[k] as? String }
        func num(_ k: String) -> Float? { (body[k] as? NSNumber)?.floatValue }
        func ids(_ k: String) -> [String]? {
            guard let list = body[k] as? [String], !list.isEmpty, list.count <= 10_000 else { return nil }
            return list
        }

        let action: BackendAction
        switch req.path {
        case "/api/decide":
            guard let id = str("photoID"), let v = str("verdict").flatMap(Verdict.init(rawValue:)) else { return .text("bad request", status: 400) }
            action = .decide(photoID: id, verdict: v, faceID: str("faceID"))
        case "/api/undo":
            guard let id = str("photoID") else { return .text("bad request", status: 400) }
            action = .undo(photoID: id)
        case "/api/decide-many":
            guard let list = ids("photoIDs"), let v = str("verdict").flatMap(Verdict.init(rawValue:)) else { return .text("bad request", status: 400) }
            action = .decideMany(photoIDs: list, verdict: v)
        case "/api/undo-many":
            guard let list = ids("photoIDs") else { return .text("bad request", status: 400) }
            action = .undoMany(photoIDs: list)
        case "/api/enroll":
            guard let id = str("clusterID") else { return .text("bad request", status: 400) }
            action = .enroll(clusterID: id)
        case "/api/thresholds":
            guard let a = num("auto"), let r = num("review") else { return .text("bad request", status: 400) }
            action = .thresholds(auto: a, review: r)
        case "/api/autoforget": action = .autoForget(body["on"] as? Bool ?? false)
        case "/api/forget-others": action = .forgetOthers
        case "/api/forget-me": action = .forgetMe
        case "/api/delete-all":
            guard body["confirm"] as? Bool == true else { return .text("confirm required", status: 400) }
            action = .deleteAll
        case "/api/clear-photos":
            guard body["confirm"] as? Bool == true else { return .text("confirm required", status: 400) }
            action = .clearPhotos(keepMe: body["keepMe"] as? Bool ?? true)
        case "/api/cancel": action = .cancel
        case "/api/export":
            guard let folder = str("folder"), !folder.isEmpty else { return .text("bad request", status: 400) }
            let opts = (body["options"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { try? JSONDecoder().decode(ExportOptions.self, from: $0) } ?? ExportOptions()
            action = .export(opts, folder: folder)
        case "/api/delete-last-export": action = .deleteLastExport
        case "/api/phone-access": action = .phoneAccess(body["on"] as? Bool ?? false)
        case "/api/upload-done":
            guard let batch = str("batch"), Uploads.isValidBatch(batch) else { return .text("bad request", status: 400) }
            action = .uploadDone(batch: batch)
        case "/api/import":
            guard let link = str("link") else { return .text("bad request", status: 400) }
            action = .importLink(link)
        case "/api/import-folder":
            guard let path = str("path") else { return .text("bad request", status: 400) }
            action = .importFolder(path)
        default: return .text("Not found", status: 404)
        }
        do {
            return .json(ActionResult(ok: true, message: try await backend.perform(action)))
        } catch {
            return .json(ActionResult(ok: false, message: error.localizedDescription), status: 400)
        }
    }

    static let lockedPage = """
    <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>FaceOrb</title>
    <body style="font:15px -apple-system,system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1rem;color:#333">
    <h2>FaceOrb is locked</h2><p>On your Mac, open the web app from the FaceOrb menu bar item (<b>Browser</b>). On a phone, scan the QR code under <b>Phone</b> in the menu bar dropdown. Those links carry a key that keeps other apps, devices and websites out.</p>
    """
}

/// Library owner without macOS frameworks: serves an existing library and its photo files.
/// Used by `faceorb-sim serve` and tests. It can't analyse new photos (that needs Apple Vision).
public actor HeadlessBackend: FaceOrbBackend {
    private var lib: Library
    private let store: LibraryStore?

    public init(lib: Library, store: LibraryStore? = nil) {
        self.lib = lib
        self.store = store
    }

    public func snapshot() -> BackendSnapshot { BackendSnapshot(lib: lib) }

    public func perform(_ action: BackendAction) throws -> String? {
        var message: String?
        switch action {
        case .decide(let id, let v, let face): Matcher.decide(&lib, photoID: id, verdict: v, faceID: face)
        case .undo(let id): Matcher.undo(&lib, photoID: id)
        case .decideMany(let ids, let v): Matcher.decide(&lib, photoIDs: ids, verdict: v)
        case .undoMany(let ids): Matcher.undo(&lib, photoIDs: ids)
        case .enroll(let clusterID):
            guard let c = PeopleClusterer.cluster(lib.faces).first(where: { $0.id == clusterID }) else { return "That person is gone; rescan." }
            lib.references.removeAll { $0.origin == .picked }
            lib.references += PeopleClusterer.references(from: c, faces: lib.faces)
            message = "Matching against the person you picked."
        case .thresholds(let a, let r):
            lib.settings.setThresholds(auto: a, review: r)
        case .autoForget(let on): lib.settings.forgetBystandersAutomatically = on
        case .forgetOthers: message = "Deleted \(Privacy.forgetBystanders(&lib)) face signatures of other people."
        case .forgetMe: Privacy.forgetMe(&lib); message = "Deleted your face references and decisions."
        case .deleteAll:
            lib = Library()
            try store?.deleteEverything()
            message = "All FaceOrb data deleted."
            return message
        case .clearPhotos(let keepMe):
            let removed = Privacy.removeAlbums(&lib, keepMe: keepMe)
            try store?.deleteAlbumCopies()
            message = "Removed \(removed) photos."
        case .cancel: break
        case .upload(let data, let name, let batch, let title):
            // Kept so the photos show up; finding faces in them needs the Mac app.
            guard let store else { throw NSError(domain: "FaceOrb", code: 1, userInfo: [NSLocalizedDescriptionKey: "Uploading needs a library folder."]) }
            let source = Uploads.source(batch: batch)
            let photos = try Uploads.save(data: data, name: name, source: source, into: store.albumFolder(for: source))
            let known = Set(lib.photos.map(\.id))
            lib.photos += photos.filter { !known.contains($0.id) }
            lib.albums[source] = title
        case .uploadDone: message = "Uploaded. Finding faces needs the Mac app."
        case .importLink, .importFolder, .export, .deleteLastExport, .phoneAccess:
            throw NSError(domain: "FaceOrb", code: 1, userInfo: [NSLocalizedDescriptionKey: "Importing and saving photos need the Mac app."])
        }
        try store?.save(lib)
        return message
    }

    public func image(photoID: String, maxPixel: Int) -> (Data, String)? {
        guard let p = lib.photos.first(where: { $0.id == photoID }),
              let data = FileManager.default.contents(atPath: p.localPath) else { return nil }
        let ext = (p.localPath as NSString).pathExtension.lowercased()
        return (data, ext == "png" ? "image/png" : ext == "webp" ? "image/webp" : "image/jpeg")
    }

    public func enrollSelfie(_ imageData: Data) throws -> Bool {
        throw NSError(domain: "FaceOrb", code: 1, userInfo: [NSLocalizedDescriptionKey: "Selfies need the Mac app (face detection uses Apple Vision)."])
    }
}
