// Headless harness for FaceOrbCore (runs on Linux and macOS).
//   faceorb-sim pixieset <share-link>              list a public Pixieset gallery
//   faceorb-sim match <faces.json> [cluster-index]   cluster faces, enrol one person, bucket photos
//   faceorb-sim serve <faces.json> <album-dir> [port]   run the web app on that data (no enrolment yet)
// faces.json comes from reference/embed_reference.py (same alignment + SFace model as the app).
import Foundation
import FaceOrbCore
import FaceOrbWeb

struct RefFace: Decodable { var photo: String; var box: [Double]; var embedding: [Float] }

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: faceorb-sim pixieset <url> | match <faces.json> [cluster-index]")
    exit(2)
}

switch args[1] {
case "pixieset":
    let gallery = try await PixiesetClient().resolve(URL(string: args[2])!)
    print("title: \(gallery.title)\nsource: \(gallery.source)\nphotos: \(gallery.photos.count)")
    if let first = gallery.photos.first { print("first: \(first.name) -> \(first.webURL?.absoluteString ?? "-")") }

case "match":
    let raw = try JSONDecoder().decode([RefFace].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    var lib = Library()
    var counts: [String: Int] = [:]
    for f in raw {
        let i = counts[f.photo, default: 0]; counts[f.photo] = i + 1
        // Box only matters for cluster ordering here; scale is arbitrary.
        lib.faces.append(Face(id: "\(f.photo)#\(i)", photoID: f.photo,
                              box: NormRect(x: f.box[0], y: f.box[1], width: f.box[2], height: f.box[3]), signature: f.embedding))
    }
    let photoIDs = Set(raw.map(\.photo))
    lib.photos = photoIDs.sorted().map { Photo(id: $0, name: $0, source: "sim", localPath: $0) }

    let t0 = Date()
    let clusters = PeopleClusterer.cluster(lib.faces)
    print(String(format: "faces %d, photos-with-faces %d, people clusters (>=3 photos) %d in %.2fs",
                 lib.faces.count, photoIDs.count, clusters.count, Date().timeIntervalSince(t0)))
    for (i, c) in clusters.prefix(8).enumerated() { print("  cluster \(i): \(c.photoCount) photos, \(c.faceIDs.count) faces") }

    let pick = args.count > 3 ? Int(args[3])! : 0
    let cluster = clusters[pick]
    lib.references = PeopleClusterer.references(from: cluster, faces: lib.faces)
    let clusterPhotos = Set(cluster.faceIDs.map { $0.split(separator: "#")[0] }.map(String.init))

    func report(_ label: String) {
        let m = Matcher.match(lib)
        let by = Dictionary(grouping: m.values, by: \.bucket).mapValues(\.count)
        let mine = Set(m.values.filter { $0.bucket == .mine }.map(\.photoID))
        let review = Set(m.values.filter { $0.bucket == .review }.map(\.photoID))
        print("\(label): mine \(by[.mine] ?? 0), review \(by[.review] ?? 0), others \(by[.others] ?? 0)"
              + " | cluster photos covered by mine \(clusterPhotos.intersection(mine).count)/\(clusterPhotos.count),"
              + " by mine+review \(clusterPhotos.intersection(mine.union(review)).count)/\(clusterPhotos.count)")
    }
    print("\nenrolled with cluster \(pick) (\(lib.references.count) reference faces)")
    report("initial")

    if let dump = ProcessInfo.processInfo.environment["FACEORB_DUMP"] {
        // For eyeballing: reference faces and the initial review queue (best face per photo).
        let m0 = Matcher.match(lib)
        let review = m0.values.filter { $0.bucket == .review }.sorted { $0.score > $1.score }
        let out: [String: [String]] = ["references": lib.references.compactMap(\.faceID),
                                       "review": review.compactMap(\.bestFaceID),
                                       "mine_lowest": m0.values.filter { $0.bucket == .mine }.sorted { $0.score < $1.score }.prefix(16).compactMap(\.bestFaceID)]
        try JSONEncoder().encode(out).write(to: URL(fileURLWithPath: dump))
    }

    // Simulated reviewer: answers the top of the queue one photo at a time (as the app does,
    // re-ranking after every decision), using cluster membership as stand-in ground truth.
    var decisions = 0, approvals = 0
    while let item = Matcher.match(lib).values.filter({ $0.bucket == .review }).max(by: { $0.score < $1.score }) {
        let yes = clusterPhotos.contains(item.photoID)
        Matcher.decide(&lib, photoID: item.photoID, verdict: yes ? .approved : .rejected)
        decisions += 1; approvals += yes ? 1 : 0
    }
    report("after \(decisions) one-at-a-time decisions (\(approvals) yes, \(decisions - approvals) no)")
    let removed = Privacy.forgetBystanders(&lib)
    print("forget bystanders: removed \(removed) signatures, kept \(lib.faces.filter { $0.signature != nil }.count)")
    report("after forgetting")

case "serve":
    let raw = try JSONDecoder().decode([RefFace].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    let album = URL(fileURLWithPath: args[3])
    var lib = Library()
    var counts: [String: Int] = [:]
    for f in raw {
        let i = counts[f.photo, default: 0]; counts[f.photo] = i + 1
        // Reference boxes are in pixels of the 1600px copies; the app stores normalised boxes.
        let size = imageSize(album.appendingPathComponent("\(f.photo).jpg")) ?? (1600, 1067)
        lib.faces.append(Face(id: "\(f.photo)#\(i)", photoID: f.photo,
                              box: NormRect(x: f.box[0] / size.0, y: f.box[1] / size.1, width: f.box[2] / size.0, height: f.box[3] / size.1),
                              signature: f.embedding))
    }
    let files = (try FileManager.default.contentsOfDirectory(atPath: album.path)).filter { $0.hasSuffix(".jpg") }.sorted()
    lib.photos = files.map { name in
        var p = Photo(id: String(name.dropLast(4)), name: name, source: "pixieset:sample", localPath: album.appendingPathComponent(name).path)
        p.analyzed = true
        return p
    }
    lib.albums["pixieset:sample"] = "Sample album"
    let api = WebAPI(backend: HeadlessBackend(lib: lib), token: ProcessInfo.processInfo.environment["FACEORB_TOKEN"] ?? WebAPI.makeToken())
    if let host = ProcessInfo.processInfo.environment["FACEORB_ALLOWED_HOST"] { api.extraAllowedHosts = [host] }
    let server = HTTPServer { await api.handle($0) }
    api.port = try server.start(preferredPort: args.count > 4 ? UInt16(args[4])! : 0)
    print("FaceOrb web app: \(api.launchURL.absoluteString)")
    while true { sleep(3600) }

default:
    print("unknown command \(args[1])"); exit(2)
}

/// Reads JPEG pixel size from the SOF marker (enough for the sample album; avoids an image library).
func imageSize(_ url: URL) -> (Double, Double)? {
    guard let d = try? Data(contentsOf: url) else { return nil }
    let b = [UInt8](d)
    var i = 2
    while i + 9 < b.count {
        guard b[i] == 0xFF else { i += 1; continue }
        let marker = b[i + 1]
        let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
        if (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker) {
            let h = Int(b[i + 5]) << 8 | Int(b[i + 6]), w = Int(b[i + 7]) << 8 | Int(b[i + 8])
            return (Double(w), Double(h))
        }
        i += 2 + len
    }
    return nil
}
