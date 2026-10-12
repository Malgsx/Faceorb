import Foundation

@inline(__always)
public func cosine(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0
    for i in 0..<min(a.count, b.count) { dot += a[i] * b[i] }
    return dot   // signatures are L2-normalised
}

public func normalized(_ v: [Float]) -> [Float] {
    let n = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
    return n > 0 ? v.map { $0 / n } : v
}

public struct PhotoMatch: Sendable {
    public var photoID: String
    public var score: Float          // best face score in the photo (-1 if no usable face)
    public var bestFaceID: String?
    public var bucket: Bucket
}

public enum Matcher {
    /// Mean of the k highest cosine similarities between `signature` and `refs`.
    static func topKMean(_ signature: [Float], _ refs: [[Float]], k: Int) -> Float {
        guard !refs.isEmpty else { return -1 }
        let sims = refs.map { cosine(signature, $0) }.sorted(by: >)
        let top = sims.prefix(max(1, k))
        return top.reduce(0, +) / Float(top.count)
    }

    /// How much a face looks like the user. Positive references raise it; if a face is
    /// closer to a rejected face than to the user, the gap is subtracted.
    public static func faceScore(_ signature: [Float], positives: [[Float]], negatives: [[Float]], k: Int) -> Float {
        let pos = topKMean(signature, positives, k: k)
        guard !negatives.isEmpty else { return pos }
        let neg = negatives.map { cosine(signature, $0) }.max() ?? -1
        return neg > pos ? pos - (neg - pos) : pos
    }

    public static func match(_ lib: Library) -> [String: PhotoMatch] {
        let positives = lib.references.filter(\.positive).map(\.signature)
        let negatives = lib.references.filter { !$0.positive }.map(\.signature)
        let s = lib.settings
        var best: [String: (Float, String)] = [:]
        if !positives.isEmpty {
            for face in lib.faces {
                guard let sig = face.signature else { continue }
                let score = faceScore(sig, positives: positives, negatives: negatives, k: s.topK)
                if score > (best[face.photoID]?.0 ?? -.infinity) { best[face.photoID] = (score, face.id) }
            }
        }
        var out: [String: PhotoMatch] = [:]
        for photo in lib.photos {
            let (score, faceID) = best[photo.id] ?? (-1, nil)
            let bucket: Bucket
            switch lib.verdicts[photo.id] {
            case .approved: bucket = .mine
            case .rejected: bucket = .others
            case nil:
                bucket = score >= s.autoThreshold ? .mine : score >= s.reviewThreshold ? .review : .others
            }
            out[photo.id] = PhotoMatch(photoID: photo.id, score: score, bestFaceID: faceID, bucket: bucket)
        }
        return out
    }

    /// Records a review decision. The face that made the photo a candidate (or the face the
    /// user pointed at) becomes a positive / negative reference, so the next ranking learns.
    public static func decide(_ lib: inout Library, photoID: String, verdict: Verdict, faceID: String? = nil) {
        record(&lib, photoID: photoID, verdict: verdict, faceID: faceID ?? match(lib)[photoID]?.bestFaceID)
    }

    /// Decides several photos at once (multi-select). Matches once up front, so each photo
    /// learns from the face the user saw highlighted, and a big batch stays fast.
    public static func decide(_ lib: inout Library, photoIDs: [String], verdict: Verdict) {
        let m = match(lib)
        for id in Set(photoIDs) where lib.photos.contains(where: { $0.id == id }) {
            record(&lib, photoID: id, verdict: verdict, faceID: m[id]?.bestFaceID)
        }
    }

    private static func record(_ lib: inout Library, photoID: String, verdict: Verdict, faceID chosen: String?) {
        lib.verdicts[photoID] = verdict
        lib.references.removeAll { ref in
            guard let f = ref.faceID else { return false }
            return f.hasPrefix(photoID + "#") && (ref.origin == .approval || ref.origin == .rejection)
        }
        guard let id = chosen, let face = lib.faces.first(where: { $0.id == id }), let sig = face.signature else { return }
        lib.references.append(Reference(signature: sig, positive: verdict == .approved,
                                        origin: verdict == .approved ? .approval : .rejection, faceID: id))
    }

    public static func undo(_ lib: inout Library, photoIDs: [String]) {
        for id in Set(photoIDs) { undo(&lib, photoID: id) }
    }

    public static func undo(_ lib: inout Library, photoID: String) {
        lib.verdicts[photoID] = nil
        lib.references.removeAll { ($0.faceID?.hasPrefix(photoID + "#") ?? false) && ($0.origin == .approval || $0.origin == .rejection) }
    }
}

/// Groups album faces into "people" so the user can enrol by clicking their own face.
public enum PeopleClusterer {
    public struct Cluster: Identifiable, Sendable {
        public var id: String { faceIDs.first ?? "" }
        public var faceIDs: [String]
        public var photoCount: Int
    }

    /// Greedy single-pass clustering against running centroids, biggest faces first.
    /// Good enough for picking yourself out of a few thousand faces in well under a second.
    public static func cluster(_ faces: [Face], threshold: Float = 0.45, minPhotos: Int = 3) -> [Cluster] {
        let usable = faces.filter { $0.signature != nil }
            .sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height }
        var centroids: [[Float]] = []
        var sums: [[Float]] = []
        var members: [[Face]] = []
        for face in usable {
            let sig = face.signature!
            var bestIdx = -1
            var bestSim = threshold
            for (i, c) in centroids.enumerated() {
                let sim = cosine(sig, c)
                if sim >= bestSim { bestSim = sim; bestIdx = i }
            }
            if bestIdx < 0 {
                centroids.append(sig); sums.append(sig); members.append([face])
            } else {
                for j in sums[bestIdx].indices { sums[bestIdx][j] += sig[j] }
                centroids[bestIdx] = normalized(sums[bestIdx])
                members[bestIdx].append(face)
            }
        }
        return members.map { m in
            Cluster(faceIDs: m.map(\.id), photoCount: Set(m.map(\.photoID)).count)
        }
        .filter { $0.photoCount >= minPhotos }
        .sorted { $0.photoCount > $1.photoCount }
    }

    /// Picks up to `limit` well-spread references from a cluster (largest faces first).
    public static func references(from cluster: Cluster, faces: [Face], limit: Int = 8) -> [Reference] {
        let byID = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0) })
        return cluster.faceIDs.prefix(limit).compactMap { id in
            byID[id]?.signature.map { Reference(signature: $0, positive: true, origin: .picked, faceID: id) }
        }
    }
}
