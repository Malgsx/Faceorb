import CoreGraphics
import FaceOrbCore
import Foundation
import Vision
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#else
import onnxruntime_objc
#endif

/// A face found by Apple Vision, with the five points SFace alignment needs.
public struct DetectedFace: Sendable {
    public var box: NormRect
    public var landmarks: FiveLandmarks
    public var pixelWidth: Double
}

public enum FaceDetector {
    /// Runs Vision's face landmarks request (it detects faces too) entirely on-device.
    public static func detect(_ image: CGImage) throws -> [DetectedFace] {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let W = Double(image.width), H = Double(image.height)
        let size = CGSize(width: W, height: H)

        return (request.results ?? []).compactMap { obs -> DetectedFace? in
            guard let lm = obs.landmarks else { return nil }
            // Vision uses a bottom-left origin; flip to top-left pixel coordinates.
            func points(_ region: VNFaceLandmarkRegion2D?) -> [Point2] {
                (region?.pointsInImage(imageSize: size) ?? []).map { Point2(Double($0.x), H - Double($0.y)) }
            }
            func centroid(_ p: [Point2]) -> Point2? {
                p.isEmpty ? nil : Point2(p.map(\.x).reduce(0, +) / Double(p.count), p.map(\.y).reduce(0, +) / Double(p.count))
            }
            guard let eyeA = points(lm.leftPupil).first ?? centroid(points(lm.leftEye)),
                  let eyeB = points(lm.rightPupil).first ?? centroid(points(lm.rightEye)),
                  let nose = centroid(points(lm.nose)) else { return nil }
            let lips = points(lm.outerLips)
            guard let mouthL = lips.min(by: { $0.x < $1.x }), let mouthR = lips.max(by: { $0.x < $1.x }) else { return nil }
            // Template order is by position in the image, not the subject's left/right.
            let (eyeL, eyeR) = eyeA.x <= eyeB.x ? (eyeA, eyeB) : (eyeB, eyeA)

            let bb = obs.boundingBox
            let box = NormRect(x: Double(bb.minX), y: 1 - Double(bb.maxY), width: Double(bb.width), height: Double(bb.height))
            return DetectedFace(box: box,
                                landmarks: FiveLandmarks(leftEye: eyeL, rightEye: eyeR, nose: nose, mouthLeft: mouthL, mouthRight: mouthR),
                                pixelWidth: Double(bb.width) * W)
        }
    }
}

/// SFace (OpenCV Zoo, Apache-2.0) via ONNX Runtime: 112x112 aligned face -> 128-d signature.
public final class FaceEmbedder: @unchecked Sendable {
    public static let modelFile = "face_recognition_sface_2021dec.onnx"
    private let env: ORTEnv
    private let session: ORTSession

    public enum EmbedderError: LocalizedError {
        case modelMissing, noOutput
        public var errorDescription: String? {
            switch self {
            case .modelMissing: "The face model (\(FaceEmbedder.modelFile)) is missing from the app bundle. Rebuild with scripts/build-app.sh."
            case .noOutput: "The face model returned no output."
            }
        }
    }

    public static func locateModel() -> URL? {
        if let url = Bundle.main.url(forResource: modelFile, withExtension: nil) { return url }
        let support = LibraryStore.defaultRoot.appendingPathComponent("models/\(modelFile)")
        return FileManager.default.fileExists(atPath: support.path) ? support : nil
    }

    public init(modelURL: URL? = FaceEmbedder.locateModel()) throws {
        guard let modelURL else { throw EmbedderError.modelMissing }
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
    }

    public func embed(_ tensor: [Float]) throws -> [Float] {
        let data = tensor.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.size) }
        let input = try ORTValue(tensorData: data, elementType: .float, shape: [1, 3, 112, 112])
        let outputs = try session.run(withInputs: ["data": input], outputNames: ["fc1"], runOptions: nil)
        guard let out = outputs["fc1"] else { throw EmbedderError.noOutput }
        let raw = try out.tensorData() as Data
        let floats = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return normalized(floats)
    }
}

public enum FaceAnalyzer {
    /// Detects every face in a photo and computes its signature. Pixels never leave the Mac.
    public static func analyze(photo: Photo, embedder: FaceEmbedder, minFacePixels: Double) throws -> [Face] {
        guard let cg = Images.load(URL(fileURLWithPath: photo.localPath)), let rgb = Images.rgb(cg) else { return [] }
        return try detectAndEmbed(cg, rgb: rgb, embedder: embedder, minFacePixels: minFacePixels)
            .enumerated().map { i, f in Face(id: "\(photo.id)#\(i)", photoID: photo.id, box: f.0.box, signature: f.1) }
    }

    /// For selfies: the largest face in each image, nothing else is kept.
    public static func largestFaceSignature(in url: URL, embedder: FaceEmbedder) throws -> [Float]? {
        guard let cg = Images.load(url), let rgb = Images.rgb(cg) else { return nil }
        return try detectAndEmbed(cg, rgb: rgb, embedder: embedder, minFacePixels: 60)
            .max { $0.0.pixelWidth < $1.0.pixelWidth }?.1
    }

    /// Same, for image bytes uploaded from the web app. Nothing is written to disk.
    public static func largestFaceSignature(data: Data, embedder: FaceEmbedder) throws -> [Float]? {
        guard let cg = Images.load(data: data), let rgb = Images.rgb(cg) else { return nil }
        return try detectAndEmbed(cg, rgb: rgb, embedder: embedder, minFacePixels: 60)
            .max { $0.0.pixelWidth < $1.0.pixelWidth }?.1
    }

    static func detectAndEmbed(_ cg: CGImage, rgb: RGBImage, embedder: FaceEmbedder, minFacePixels: Double) throws -> [(DetectedFace, [Float])] {
        try FaceDetector.detect(cg)
            .filter { $0.pixelWidth >= minFacePixels }
            .map { face in
                let signature = try embedder.embed(FaceAligner.alignedTensor(rgb, landmarks: face.landmarks))
                return (face, signature)
            }
    }
}
