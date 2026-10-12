import Foundation

/// Packed 8-bit RGB pixels, row-major, origin top-left.
public struct RGBImage: Sendable {
    public let width: Int, height: Int
    public var pixels: [UInt8]   // width * height * 3
    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 3)
        self.width = width; self.height = height; self.pixels = pixels
    }
}

public struct Point2: Codable, Hashable, Sendable {
    public var x: Double, y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// Five facial landmarks in pixel coordinates (origin top-left), in image order:
/// eye on the image's left, eye on the image's right, nose tip, mouth corner left, mouth corner right.
public struct FiveLandmarks: Sendable {
    public var points: [Point2]
    public init(leftEye: Point2, rightEye: Point2, nose: Point2, mouthLeft: Point2, mouthRight: Point2) {
        points = [leftEye, rightEye, nose, mouthLeft, mouthRight]
    }
}

/// 2x3 affine matrix [a -b tx; b a ty].
public struct Similarity: Sendable, Equatable {
    public var a: Double, b: Double, tx: Double, ty: Double
}

public enum FaceAligner {
    public static let size = 112
    /// ArcFace / SFace 112x112 landmark template (same as OpenCV FaceRecognizerSF.alignCrop).
    public static let template: [Point2] = [
        Point2(38.2946, 51.6963), Point2(73.5318, 51.5014), Point2(56.0252, 71.7366),
        Point2(41.5493, 92.3655), Point2(70.7299, 92.2041),
    ]

    /// Least-squares similarity transform (rotation + uniform scale + translation) src -> dst.
    public static func similarity(from src: [Point2], to dst: [Point2]) -> Similarity {
        let n = Double(src.count)
        let msx = src.map(\.x).reduce(0, +) / n, msy = src.map(\.y).reduce(0, +) / n
        let mdx = dst.map(\.x).reduce(0, +) / n, mdy = dst.map(\.y).reduce(0, +) / n
        var num = 0.0, cross = 0.0, den = 0.0
        for (s, d) in zip(src, dst) {
            let sx = s.x - msx, sy = s.y - msy, dx = d.x - mdx, dy = d.y - mdy
            num += sx * dx + sy * dy
            cross += sx * dy - sy * dx
            den += sx * sx + sy * sy
        }
        let a = den > 0 ? num / den : 1, b = den > 0 ? cross / den : 0
        return Similarity(a: a, b: b, tx: mdx - (a * msx - b * msy), ty: mdy - (b * msx + a * msy))
    }

    /// Warps the face to 112x112 and returns the SFace input tensor: Float32, NCHW, RGB, 0...255.
    public static func alignedTensor(_ image: RGBImage, landmarks: FiveLandmarks) -> [Float] {
        let m = similarity(from: landmarks.points, to: template)
        // Invert [a -b; b a] analytically.
        let det = m.a * m.a + m.b * m.b
        let ia = m.a / det, ib = -m.b / det
        let s = size, plane = s * s
        var out = [Float](repeating: 0, count: 3 * plane)
        let w = image.width, h = image.height
        image.pixels.withUnsafeBufferPointer { px in
            for oy in 0..<s {
                for ox in 0..<s {
                    let u = Double(ox) - m.tx, v = Double(oy) - m.ty
                    let sx = ia * u - ib * v
                    let sy = ib * u + ia * v
                    let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
                    let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
                    var acc: (Float, Float, Float) = (0, 0, 0)
                    for (dx, dy, wgt) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] {
                        let x = x0 + dx, y = y0 + dy
                        guard x >= 0, x < w, y >= 0, y < h, wgt != 0 else { continue }
                        let i = (y * w + x) * 3
                        acc.0 += Float(px[i]) * wgt
                        acc.1 += Float(px[i + 1]) * wgt
                        acc.2 += Float(px[i + 2]) * wgt
                    }
                    let o = oy * s + ox
                    out[o] = acc.0; out[plane + o] = acc.1; out[2 * plane + o] = acc.2
                }
            }
        }
        return out
    }
}
