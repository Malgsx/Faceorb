import XCTest
@testable import FaceOrbCore

final class AlignmentTests: XCTestCase {
    struct Fixture: Decodable {
        var width: Int, height: Int, pixels: [UInt8], landmarks: [[Double]]
        var similarity: [Double], samples: [[Double]], sum: Double
    }

    /// Fixture produced by the Python reference pipeline whose embeddings match
    /// OpenCV's FaceRecognizerSF.alignCrop + feature() at cosine 0.9999.
    func testMatchesReferenceWarp() throws {
        let url = Bundle.module.url(forResource: "alignment", withExtension: "json", subdirectory: "Fixtures")!
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let pts = f.landmarks.map { Point2($0[0], $0[1]) }
        let m = FaceAligner.similarity(from: pts, to: FaceAligner.template)
        XCTAssertEqual(m.a, f.similarity[0], accuracy: 1e-9)
        XCTAssertEqual(m.b, f.similarity[1], accuracy: 1e-9)
        XCTAssertEqual(m.tx, f.similarity[2], accuracy: 1e-9)
        XCTAssertEqual(m.ty, f.similarity[3], accuracy: 1e-9)

        let img = RGBImage(width: f.width, height: f.height, pixels: f.pixels)
        let lm = FiveLandmarks(leftEye: pts[0], rightEye: pts[1], nose: pts[2], mouthLeft: pts[3], mouthRight: pts[4])
        let t = FaceAligner.alignedTensor(img, landmarks: lm)
        XCTAssertEqual(t.count, 3 * 112 * 112)
        for s in f.samples {
            let (c, y, x) = (Int(s[0]), Int(s[1]), Int(s[2]))
            XCTAssertEqual(Double(t[c * 112 * 112 + y * 112 + x]), s[3], accuracy: 1e-3, "c\(c) y\(y) x\(x)")
        }
        XCTAssertEqual(t.reduce(0.0) { $0 + Double($1) }, f.sum, accuracy: f.sum * 1e-5)
    }
}

final class MatcherTests: XCTestCase {
    func vec(_ angle: Float) -> [Float] { [cos(angle), sin(angle), 0, 0] }

    func library() -> Library {
        var lib = Library()
        // Photos p0..p3. "me" is near angle 0; a look-alike near 1.0 rad; a stranger at 2.5 rad.
        let faces: [(String, Float)] = [("p0", 0.05), ("p1", 0.9), ("p2", 2.5), ("p3", 1.05), ("p3", 2.6)]
        for (i, (p, a)) in faces.enumerated() {
            lib.faces.append(Face(id: "\(p)#\(i)", photoID: p, box: NormRect(x: 0, y: 0, width: 0.1, height: 0.1), signature: vec(a)))
        }
        lib.photos = ["p0", "p1", "p2", "p3"].map { Photo(id: $0, name: $0, source: "t", localPath: $0) }
        lib.references = [Reference(signature: vec(0), positive: true, origin: .selfie)]
        return lib
    }

    func testBuckets() {
        let m = Matcher.match(library())
        XCTAssertEqual(m["p0"]?.bucket, .mine)       // cos(0.05) ~ 0.999
        XCTAssertEqual(m["p1"]?.bucket, .mine)       // cos(0.9)  ~ 0.62
        XCTAssertEqual(m["p3"]?.bucket, .review)     // cos(1.05) ~ 0.50, just under 0.50
        XCTAssertEqual(m["p2"]?.bucket, .others)
        XCTAssertEqual(m["p3"]?.bestFaceID, "p3#3")
    }

    func testThresholdsAndFeedback() {
        var lib = library()
        lib.settings.autoThreshold = 0.8
        lib.settings.reviewThreshold = 0.4
        var m = Matcher.match(lib)
        XCTAssertEqual(m["p0"]?.bucket, .mine)
        XCTAssertEqual(m["p1"]?.bucket, .review)     // 0.62
        XCTAssertEqual(m["p3"]?.bucket, .review)     // 0.50
        XCTAssertEqual(m["p2"]?.bucket, .others)

        // Rejecting the look-alike in p1 should push the similar face in p3 out of review.
        Matcher.decide(&lib, photoID: "p1", verdict: .rejected)
        m = Matcher.match(lib)
        XCTAssertEqual(m["p1"]?.bucket, .others)
        XCTAssertEqual(m["p3"]?.bucket, .others)
        XCTAssertEqual(lib.references.filter { !$0.positive }.count, 1)

        Matcher.undo(&lib, photoID: "p1")
        m = Matcher.match(lib)
        XCTAssertEqual(m["p3"]?.bucket, .review)
        XCTAssertTrue(lib.references.allSatisfy(\.positive))
    }

    func testOldLibraryStillLoadsAndHistoryIsKept() throws {
        // A library.json written before albumOrigins/exports existed must keep its data.
        var old = library()
        old.albums = ["folder:/Users/x/Pics": "Pics"]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "albumOrigins")
        json.removeValue(forKey: "exports")
        let lib = try JSONDecoder().decode(Library.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(lib.photos.count, old.photos.count)
        XCTAssertEqual(lib.faces.count, old.faces.count)
        XCTAssertEqual(lib.albums, old.albums)
        XCTAssertTrue(lib.albumOrigins.isEmpty)
        XCTAssertEqual(Library.folderPath(forSource: "folder:/Users/x/Pics"), "/Users/x/Pics")
        XCTAssertNil(Library.folderPath(forSource: "pixieset:1"))

        var h = Library()
        for i in 0..<12 { h.recordExport(folder: "/f\(i)", count: i, at: Date(timeIntervalSince1970: Double(i))) }
        h.recordExport(folder: "/f5", count: 99)
        XCTAssertEqual(h.exports.count, 10)
        XCTAssertEqual(h.exports.first?.folder, "/f5")
        XCTAssertEqual(h.exports.first?.count, 99)
        XCTAssertEqual(h.exports.filter { $0.folder == "/f5" }.count, 1)

        h.albumOrigins["pixieset:1"] = AlbumOrigin(link: "https://pixies.et/x")
        let round = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(round.exports, h.exports)
        XCTAssertEqual(round.albumOrigins["pixieset:1"]?.link, "https://pixies.et/x")
    }

    func testDecideMany() {
        var lib = library()
        lib.settings.autoThreshold = 0.8
        lib.settings.reviewThreshold = 0.4
        // Same outcome as deciding one by one, ignoring duplicates and unknown ids.
        var single = lib
        Matcher.decide(&single, photoID: "p1", verdict: .rejected)
        Matcher.decide(&single, photoID: "p3", verdict: .rejected)
        Matcher.decide(&lib, photoIDs: ["p1", "p3", "p1", "nope"], verdict: .rejected)
        XCTAssertEqual(lib.verdicts, ["p1": .rejected, "p3": .rejected])
        XCTAssertEqual(Set(lib.references.compactMap(\.faceID)), Set(single.references.compactMap(\.faceID)))
        XCTAssertEqual(lib.references.filter { !$0.positive }.count, 2)

        Matcher.undo(&lib, photoIDs: ["p1", "p3"])
        XCTAssertTrue(lib.verdicts.isEmpty)
        XCTAssertTrue(lib.references.allSatisfy(\.positive))
    }

    func testRemoveAlbumsKeepsMe() {
        var lib = library()
        lib.photos[2].source = "u"   // p2 lives in a second album
        lib.albums = ["t": "Party", "u": "Wedding"]
        lib.albumOrigins = ["t": AlbumOrigin(link: "https://pixies.et/x")]
        lib.exports = [ExportRecord(folder: "/out", count: 1, date: Date())]
        Matcher.decide(&lib, photoID: "p0", verdict: .approved)
        Matcher.decide(&lib, photoID: "p2", verdict: .rejected)

        // One album: only its photos, faces, decisions and "not me" references go.
        var one = lib
        XCTAssertEqual(Privacy.removeAlbums(&one, sources: ["u"]), 1)
        XCTAssertEqual(one.photos.map(\.id), ["p0", "p1", "p3"])
        XCTAssertFalse(one.faces.contains { $0.photoID == "p2" })
        XCTAssertEqual(one.verdicts, ["p0": .approved])
        XCTAssertEqual(one.albums, ["t": "Party"])
        XCTAssertTrue(one.references.allSatisfy(\.positive))
        XCTAssertTrue(one.references.contains { $0.faceID == "p0#0" }, "references into kept albums keep their link")

        // Everything: a clean slate that still knows the user, so a new album sorts right away.
        var all = lib
        XCTAssertEqual(Privacy.removeAlbums(&all), 4)
        XCTAssertTrue(all.photos.isEmpty && all.faces.isEmpty && all.verdicts.isEmpty && all.albums.isEmpty && all.albumOrigins.isEmpty)
        XCTAssertEqual(all.references.count, 2, "the selfie and the approval stay")
        XCTAssertTrue(all.references.allSatisfy { $0.positive && $0.faceID == nil })
        XCTAssertEqual(all.exports.count, 1, "save folders are the user's own and stay listed")
        all.photos = [Photo(id: "n0", name: "n0", source: "v", localPath: "n0")]
        all.faces = [Face(id: "n0#0", photoID: "n0", box: NormRect(x: 0, y: 0, width: 0.1, height: 0.1), signature: vec(0.02))]
        XCTAssertEqual(Matcher.match(all)["n0"]?.bucket, .mine)

        var fresh = lib
        Privacy.removeAlbums(&fresh, keepMe: false)
        XCTAssertTrue(fresh.references.isEmpty)
    }

    func testDeleteAlbumCopiesOnlyTouchesItsOwnFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        for s in ["pixieset:1", "pixieset:2"] {
            try FileManager.default.createDirectory(at: store.albumFolder(for: s), withIntermediateDirectories: true)
        }
        try store.save(Library())
        try store.deleteAlbumCopies(sources: ["pixieset:1", "folder:/nope"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.albumFolder(for: "pixieset:1").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.albumFolder(for: "pixieset:2").path))
        try store.deleteAlbumCopies()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.albumsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.libraryURL.path), "library.json stays")
    }

    func testForgetBystanders() {
        var lib = library()
        let removed = Privacy.forgetBystanders(&lib)
        XCTAssertEqual(removed, 2)   // the two strangers (p2, p3's second face)
        XCTAssertNotNil(lib.faces.first { $0.photoID == "p0" }?.signature)
        XCTAssertNil(lib.faces.first { $0.photoID == "p2" }?.signature)
        XCTAssertEqual(Matcher.match(lib)["p0"]?.bucket, .mine)
    }

    func testClustering() {
        var faces: [Face] = []
        for i in 0..<5 { faces.append(Face(id: "a\(i)#0", photoID: "a\(i)", box: NormRect(x: 0, y: 0, width: 0.2, height: 0.2), signature: vec(Float(i) * 0.02))) }
        for i in 0..<3 { faces.append(Face(id: "b\(i)#0", photoID: "b\(i)", box: NormRect(x: 0, y: 0, width: 0.1, height: 0.1), signature: vec(2 + Float(i) * 0.02))) }
        faces.append(Face(id: "c#0", photoID: "c", box: NormRect(x: 0, y: 0, width: 0.1, height: 0.1), signature: vec(-1.5)))
        let clusters = PeopleClusterer.cluster(faces)
        XCTAssertEqual(clusters.map(\.photoCount), [5, 3])
    }

    func testCSVEscaping() {
        var lib = library()
        lib.photos[0].name = "a \"quoted\", name.jpg"
        let csv = Exporter.csv(lib)
        XCTAssertTrue(csv.contains("\"a \"\"quoted\"\", name.jpg\",\"mine\""))
    }
}

final class PixiesetParsingTests: XCTestCase {
    func testParsesInlineConfig() {
        let html = """
        <html><head><title> Sam&#039;s 40th Birthday </title></head><script>
        window.data = {'collectionUrlKey':'sams40thbirthday','collectionId':987654321,
        'allGalleries':[{'id':1,'slug':'photos','name':'Photos'},{'id':2,'slug':'dancing','name':'Dancing'}],'other':[{'slug':'nope'}]};
        </script></html>
        """
        let p = PixiesetClient.parsePage(html)
        XCTAssertEqual(p.key, "sams40thbirthday")
        XCTAssertEqual(p.id, "987654321")
        XCTAssertEqual(p.slugs, ["photos", "dancing"])
        XCTAssertEqual(p.title, "Sam's 40th Birthday")
    }

    func testPasswordGateHasNoCollectionID() {
        let p = PixiesetClient.parsePage("<script>{'collectionUrlKey':'secret'}</script>")
        XCTAssertEqual(p.key, "secret")
        XCTAssertNil(p.id)
        XCTAssertEqual(p.slugs, ["photos"])
    }
}

import FaceOrbWeb
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class WebAPITests: XCTestCase {
    func request(_ path: String, method: String = "GET", query: [String: String] = [:], headers: [String: String] = [:], body: String = "") -> HTTPServer.Request {
        HTTPServer.Request(method: method, path: path, query: query, headers: headers, body: Data(body.utf8))
    }

    func testAuthHostAndCSRFGuards() async throws {
        var lib = Library()
        lib.photos = [Photo(id: "p", name: "p.jpg", source: "t", localPath: "/nonexistent")]
        let api = WebAPI(backend: HeadlessBackend(lib: lib), token: "secret")
        api.port = 4000
        let host = ["host": "127.0.0.1:4000"]

        var r = await api.handle(request("/api/state", headers: host))
        XCTAssertEqual(r.status, 403, "no token")
        r = await api.handle(request("/api/state", headers: ["host": "evil.example:4000", "cookie": "faceorb=secret"]))
        XCTAssertEqual(r.status, 403, "DNS rebinding host")
        r = await api.handle(request("/", query: ["t": "secret"], headers: host))
        XCTAssertEqual(r.status, 302)
        XCTAssertTrue(r.headers["Set-Cookie"]!.contains("SameSite=Strict"))
        r = await api.handle(request("/api/state", headers: host.merging(["cookie": "a=b; faceorb=secret"], uniquingKeysWith: { $1 })))
        XCTAssertEqual(r.status, 200)

        let auth = host.merging(["cookie": "faceorb=secret"], uniquingKeysWith: { $1 })
        r = await api.handle(request("/api/decide", method: "POST", headers: auth, body: #"{"photoID":"p","verdict":"approved"}"#))
        XCTAssertEqual(r.status, 403, "missing X-FaceOrb header")
        r = await api.handle(request("/api/decide", method: "POST", headers: auth.merging(["x-faceorb": "1"], uniquingKeysWith: { $1 }), body: #"{"photoID":"p","verdict":"approved"}"#))
        XCTAssertEqual(r.status, 200)
        r = await api.handle(request("/api/state", headers: auth))
        let state = try JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        XCTAssertEqual((state["counts"] as! [String: Int])["mine"], 1)
    }

    func testDecideManyAndUndoMany() async throws {
        var lib = Library()
        lib.photos = ["a", "b", "c"].map { Photo(id: $0, name: "\($0).jpg", source: "t", localPath: "/nonexistent") }
        let api = WebAPI(backend: HeadlessBackend(lib: lib), token: "k")
        api.port = 4000
        let auth = ["host": "127.0.0.1:4000", "cookie": "faceorb=k", "x-faceorb": "1"]
        func counts() async throws -> [String: Int] {
            let r = await api.handle(request("/api/state", headers: auth))
            return (try JSONSerialization.jsonObject(with: r.body) as! [String: Any])["counts"] as! [String: Int]
        }

        var r = await api.handle(request("/api/decide-many", method: "POST", headers: auth, body: #"{"photoIDs":["a","b"],"verdict":"approved"}"#))
        XCTAssertEqual(r.status, 200)
        var c = try await counts()
        XCTAssertEqual(c["mine"], 2)
        r = await api.handle(request("/api/decide-many", method: "POST", headers: auth, body: #"{"photoIDs":["c"],"verdict":"rejected"}"#))
        XCTAssertEqual(r.status, 200)
        r = await api.handle(request("/api/undo-many", method: "POST", headers: auth, body: #"{"photoIDs":["a","b","c"]}"#))
        XCTAssertEqual(r.status, 200)
        c = try await counts()
        XCTAssertEqual(c["mine"] ?? 0, 0)

        r = await api.handle(request("/api/decide-many", method: "POST", headers: auth, body: #"{"photoIDs":[],"verdict":"approved"}"#))
        XCTAssertEqual(r.status, 400, "empty list")
        r = await api.handle(request("/api/decide-many", method: "POST", headers: auth, body: #"{"photoIDs":["a"],"verdict":"maybe"}"#))
        XCTAssertEqual(r.status, 400, "bad verdict")
        r = await api.handle(request("/api/decide-many", method: "POST", headers: ["host": "127.0.0.1:4000", "cookie": "faceorb=k"], body: #"{"photoIDs":["a"],"verdict":"approved"}"#))
        XCTAssertEqual(r.status, 403, "CSRF guard still applies")
    }

    func testClearPhotosEndpoint() async throws {
        var lib = Library()
        lib.photos = ["a", "b"].map { Photo(id: $0, name: "\($0).jpg", source: "t", localPath: "/nonexistent") }
        lib.references = [Reference(signature: [1, 0], positive: true, origin: .selfie)]
        let api = WebAPI(backend: HeadlessBackend(lib: lib), token: "k")
        api.port = 4000
        let auth = ["host": "127.0.0.1:4000", "cookie": "faceorb=k", "x-faceorb": "1"]
        var r = await api.handle(request("/api/clear-photos", method: "POST", headers: auth, body: "{}"))
        XCTAssertEqual(r.status, 400, "needs confirm")
        r = await api.handle(request("/api/clear-photos", method: "POST", headers: auth, body: #"{"confirm":true}"#))
        XCTAssertEqual(r.status, 200)
        r = await api.handle(request("/api/state", headers: auth))
        let state = try JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        XCTAssertEqual((state["stats"] as! [String: Any])["photos"] as? Int, 0)
        XCTAssertEqual(state["enrolled"] as? Bool, true, "start over keeps the user's face")
    }

    func testServerRoundTrip() async throws {
        let api = WebAPI(backend: HeadlessBackend(lib: Library()), token: "tok")
        let server = HTTPServer { await api.handle($0) }
        api.port = try server.start()
        defer { server.stop() }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(api.port)/api/state?t=tok")!)
        req.setValue("1", forHTTPHeaderField: "X-FaceOrb")
        let (data, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

final class ExportTests: XCTestCase {
    func lib() -> Library {
        var lib = Library()
        lib.photos = [
            Photo(id: "a", name: "DSC01.jpg", source: "s", localPath: "/x/DSC01.jpg"),
            Photo(id: "b", name: "DSC01.jpg", source: "s", localPath: "/y/DSC01.jpg"),   // same name, other folder
            Photo(id: "c", name: "bad:name?.jpeg", source: "s", localPath: "/x/c.jpeg"),
            Photo(id: "d", name: "review.jpg", source: "s", localPath: "/x/d.jpg"),
        ]
        lib.albums["s"] = "Sam's 40th / party"
        lib.verdicts = ["a": .approved, "b": .approved, "c": .approved]
        lib.faces = [Face(id: "d#0", photoID: "d", box: NormRect(x: 0, y: 0, width: 0.1, height: 0.1), signature: [1, 0])]
        lib.references = [Reference(signature: [0.4, 0.9165], positive: true, origin: .selfie)]   // cos 0.4 -> review
        return lib
    }

    func testNamesAreUniqueAndSafe() {
        var o = ExportOptions()
        var names = ExportPlanner.plan(lib(), o).map(\.fileName)
        XCTAssertEqual(names, ["DSC01.jpg", "DSC01 2.jpg", "bad-name-.jpeg"])
        o.format = .heic
        o.naming = .numbered
        o.scope = .mineAndReview
        names = ExportPlanner.plan(lib(), o).map(\.fileName)
        XCTAssertEqual(names, ["Sam's 40th - party-001.heic", "Sam's 40th - party-002.heic",
                               "Sam's 40th - party-003.heic", "Sam's 40th - party-004.heic"])
    }

    func testOptionsDecodeWithDefaultsAndClamps() throws {
        let o = try JSONDecoder().decode(ExportOptions.self, from: Data(#"{"format":"png","maxPixel":0,"quality":5,"subfolder":"a/b"}"#.utf8))
        XCTAssertEqual(o.format, .png)
        XCTAssertNil(o.maxPixel)
        XCTAssertEqual(o.quality, 1)
        XCTAssertEqual(o.subfolder, "a-b")
        XCTAssertEqual(o.scope, .mine)
    }

    func testPreflight() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("faceorb-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNoThrow(try DiskCheck.preflight(folder: dir, needed: 1000))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [], "probe file cleaned up")
        XCTAssertThrowsError(try DiskCheck.preflight(folder: dir, needed: Int64.max / 4)) { error in
            XCTAssertTrue(error.localizedDescription.contains("free"))
        }
    }
}

final class LinkImportTests: XCTestCase {
    let base = URL(string: "https://example.com/album/")!

    func testGalleryPrefersFullSizeLinksAndKeepsShownImagesAsFallback() {
        let html = """
        <img src="logo.svg"><img src="data:image/png;base64,AA">
        <a href="full/1.jpg"><img src="thumbs/1.jpg"></a>
        <a href='/full/2.JPG?v=2'><img src="thumbs/2.jpg"></a>
        """
        let urls = LinkImporter.imageURLs(inPage: html, base: base)
        XCTAssertEqual(urls.primary.map(\.absoluteString),
                       ["https://example.com/album/full/1.jpg", "https://example.com/full/2.JPG?v=2"])
        XCTAssertEqual(urls.fallback.map(\.absoluteString),
                       ["https://example.com/album/thumbs/1.jpg", "https://example.com/album/thumbs/2.jpg"])
    }

    func testPageWithoutLinksUsesLargestSrcsetCandidate() {
        let html = #"<img srcset="a-small.jpg 400w, a-big.jpg 1600w" src="a-small.jpg"><img data-src="b.jpg" src="spacer.gif">"#
        let urls = LinkImporter.imageURLs(inPage: html, base: base)
        XCTAssertEqual(urls.primary.map(\.lastPathComponent), ["a-big.jpg", "a-small.jpg", "b.jpg"])
        XCTAssertTrue(urls.fallback.isEmpty)
    }

    func testDropboxLinksBecomeDownloads() {
        let url = LinkImporter.directDownloadURL(URL(string: "https://www.dropbox.com/scl/fo/abc/xyz?rlkey=k&dl=0")!)
        XCTAssertEqual(url.absoluteString, "https://www.dropbox.com/scl/fo/abc/xyz?rlkey=k&dl=1")
        let other = URL(string: "https://example.com/a?dl=0")!
        XCTAssertEqual(LinkImporter.directDownloadURL(other), other)
    }

    func testRecognisesPhotoAndZipBytes() {
        XCTAssertEqual(LinkImporter.imageExtension(for: Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0, count: 8))), "jpg")
        XCTAssertEqual(LinkImporter.imageExtension(for: Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 0, count: 8))), "png")
        XCTAssertEqual(LinkImporter.imageExtension(for: Data([0, 0, 0, 0x18] + Array("ftypheic".utf8))), "heic")
        XCTAssertNil(LinkImporter.imageExtension(for: Data("<!doctype html>".utf8)))
        XCTAssertTrue(LinkImporter.isZip(Data([0x50, 0x4B, 0x03, 0x04, 0])))
    }

    func testSourceIsStablePerLink() {
        let a = URL(string: "https://example.com/album")!
        XCTAssertEqual(LinkImporter.source(for: a), LinkImporter.source(for: a))
        XCTAssertNotEqual(LinkImporter.source(for: a), LinkImporter.source(for: URL(string: "https://example.com/other")!))
        XCTAssertTrue(LinkImporter.source(for: a).hasPrefix("link:"))
    }
}
