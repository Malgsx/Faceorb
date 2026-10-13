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
    /// Original photo bytes for saving to the browser's device.
    func download(photoID: String) async -> PhotoDownload?
    func enrollSelfie(_ imageData: Data) async throws -> Bool
}

public struct PhotoDownload: Sendable {
    public var data: Data
    public var name: String
    public var contentType: String

    public init(data: Data, name: String, contentType: String) {
        self.data = data; self.name = name; self.contentType = contentType
    }
}

public extension FaceOrbBackend {
    func download(photoID: String) async -> PhotoDownload? {
        guard let photo = await snapshot().lib.photos.first(where: { $0.id == photoID }) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> PhotoDownload? in
            guard let data = FileManager.default.contents(atPath: photo.localPath) else { return nil }
            let ext = (photo.localPath as NSString).pathExtension.lowercased()
            let types = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
                         "heic": "image/heic", "heif": "image/heif", "tif": "image/tiff",
                         "tiff": "image/tiff", "webp": "image/webp", "gif": "image/gif",
                         "bmp": "image/bmp", "avif": "image/avif"]
            let name = (photo.name as NSString).lastPathComponent
            return PhotoDownload(data: data, name: name.isEmpty ? "photo.\(ext)" : name,
                                 contentType: types[ext] ?? "application/octet-stream")
        }.value
    }
}

public struct BackendSnapshot: Sendable {
    public var lib: Library
    public var busy: Bool
    public var activity: String
    public var fraction: Double?
    public var error: String?
    public init(lib: Library, busy: Bool = false, activity: String = "Ready", fraction: Double? = nil, error: String? = nil) {
        self.lib = lib; self.busy = busy; self.activity = activity; self.fraction = fraction; self.error = error
    }
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
}

/// JSON API + static web app, protected for a loopback server:
/// - a random token (in the URL the menu bar opens, then a SameSite=Strict cookie),
/// - a Host check against DNS rebinding,
/// - a custom header on writes so other web pages can't post to it.
public final class WebAPI: @unchecked Sendable {
    public let backend: FaceOrbBackend
    public let token: String
    public var port: UInt16 = 0
    /// Extra Host values for the headless demo; the Mac app uses a separate phone-access policy.
    public var extraAllowedHosts: Set<String> = []
    private let phoneLock = NSLock()
    private var phoneAccess: PhoneAccessConfiguration?

    public init(backend: FaceOrbBackend, token: String) {
        self.backend = backend
        self.token = token
    }

    public func configurePhoneAccess(_ configuration: PhoneAccessConfiguration?) {
        phoneLock.withLock { phoneAccess = configuration }
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
        var photos: [PhotoDTO]
    }
    struct FaceDTO: Encodable { var id: String; var box: NormRect; var hasSignature: Bool }
    struct PersonDTO: Encodable {
        var id: String, photoCount: Int, picked: Bool
        var photoID: String, box: NormRect
    }
    struct ActionResult: Encodable { var ok: Bool; var message: String? }

    // MARK: Routing

    public func handle(_ req: HTTPServer.Request) async -> HTTPServer.Response {
        let phone = phoneLock.withLock { phoneAccess }
        var response = await handle(req, phone: phone)
        if req.headers["host"].map({ phone?.origin.accepts(host: $0) == true }) == true || response.headers["Cache-Control"] == nil {
            response.headers["Cache-Control"] = "no-store"
        }
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response
    }

    private func handle(_ req: HTTPServer.Request, phone: PhoneAccessConfiguration?) async -> HTTPServer.Response {
        let isPhone = !hostAllowed(req.headers["host"]) && (req.headers["host"].map { phone?.origin.accepts(host: $0) == true } ?? false)
        guard isPhone || hostAllowed(req.headers["host"]) else { return .text("Forbidden host", status: 403) }
        // Only a locally configured proxy can deliver these hosts. Never infer trust from forwarded headers.
        if isPhone && req.headers["x-forwarded-proto"] != "https" {
            return .text("HTTPS proxy required", status: 403)
        }
        if isPhone && req.headers["tailscale-funnel-request"] != nil {
            return .text("Public Tailscale Funnel is not supported. Use private Serve.", status: 403)
        }

        // Branding and clean PWA metadata are public; library access still requires a cookie.
        if let icon = WebAppIcon.response(for: req) { return icon }

        let cookieName = isPhone ? "__Host-faceorb-phone" : "faceorb"
        let key = isPhone ? phone!.token : token
        let cookieToken = req.headers["cookie"]?.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(cookieName + "=") }?.dropFirst(cookieName.count + 1)
        if isPhone && req.method == "GET" && req.path == "/api/phone-status" {
            return .json(["instance": phone!.connectionID])
        }
        let tokenLink = (!isPhone || (req.method == "GET" && req.path == "/")) && req.query["t"] == key
        let authorized = cookieToken.map(String.init) == key || tokenLink
        guard authorized else {
            return .text(isPhone ? Self.phoneLockedPage : Self.lockedPage, status: 403, type: "text/html; charset=utf-8")
        }

        if req.method == "GET" && req.path == "/" {
            var r = HTTPServer.Response.text(WebAppPage.html, type: "text/html; charset=utf-8")
            r.headers["Set-Cookie"] = "\(cookieName)=\(key); Path=/; HttpOnly; SameSite=Strict" + (isPhone ? "; Secure" : "")
            r.headers["Cache-Control"] = "no-store"
            r.headers["Referrer-Policy"] = "no-referrer"
            r.headers["Content-Security-Policy"] = "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'"
            if req.query["t"] != nil {   // drop the token from the address bar
                r.status = 302
                r.headers["Location"] = "/"
                r.body = Data()
            }
            return r
        }

        if req.method == "POST" {
            guard req.headers["x-faceorb"] == "1" else { return .text("Missing header", status: 403) }
            if isPhone {
                guard let origin = req.headers["origin"], phone!.origin.accepts(origin: origin) else {
                    return .text("Forbidden origin", status: 403)
                }
            } else if let origin = req.headers["origin"], origin != "http://\(req.headers["host"]!)" {
                return .text("Forbidden origin", status: 403)
            }
            return await post(req)
        }

        switch req.path {
        case "/api/state": return .json(await state())
        case "/api/photo":
            guard let id = req.query["id"] else { return .text("id?", status: 400) }
            let lib = await backend.snapshot().lib
            return .json(lib.faces.filter { $0.photoID == id }.map { FaceDTO(id: $0.id, box: $0.box, hasSignature: $0.signature != nil) })
        case "/api/people":
            let lib = await backend.snapshot().lib
            let picked = Set(lib.references.compactMap(\.faceID))
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
        case "/download":
            guard req.method == "GET" else { return .text("GET required", status: 400) }
            guard let id = req.query["id"] else { return .text("id?", status: 400) }
            guard let file = await backend.download(photoID: id) else { return .text("Photo unavailable", status: 404) }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            let name = file.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "photo"
            let fallback = file.name.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
            return HTTPServer.Response(headers: ["Content-Type": file.contentType,
                                                 "Content-Disposition": "attachment; filename=\"\(fallback)\"; filename*=UTF-8''\(name)",
                                                 "Cache-Control": "no-store"], body: file.data)
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
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)" || extraAllowedHosts.contains(host)
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
                        freeDisk: DiskCheck.freeBytes(at: URL(fileURLWithPath: NSHomeDirectory())), photos: photos)
    }

    private func post(_ req: HTTPServer.Request) async -> HTTPServer.Response {
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
    <!doctype html><meta charset="utf-8"><title>FaceOrb</title>
    \(WebAppIcon.head)
    <body style="font:15px -apple-system,system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1rem;color:#333">
    <h2>FaceOrb is locked</h2><p>Open the web app from the FaceOrb menu bar item (<b>Browser</b>). Its private link carries the key that keeps other apps and websites out.</p>
    """

    static let phoneLockedPage = """
    <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>FaceOrb</title>
    \(WebAppIcon.head)
    <body style="font:17px -apple-system,system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1rem;color:#333">
    <h2>Connect your phone</h2><p>On your Mac, open FaceOrb &rarr; <b>Phone</b>, then scan the private QR code or open its private link in Safari. If access was revoked, ask the Mac owner for a new link.</p>
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
            lib.settings.autoThreshold = a
            lib.settings.reviewThreshold = min(r, a)
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
        case .importLink, .importFolder, .export, .deleteLastExport:
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
