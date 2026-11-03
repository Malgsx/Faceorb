import Foundation

/// The home-screen icon for the web app: the chrome orb on a dark square, drawn in code so the
/// web app needs no bundled files. Full-bleed, with the orb inside the maskable safe zone, so
/// Android can crop it to any shape and iOS can round its corners.
enum AppIcon {
    private static let cache = NSCache<NSNumber, NSData>()

    static func png(size: Int) -> Data {
        if let hit = cache.object(forKey: size as NSNumber) { return hit as Data }
        let data = PNG.encode(width: size, height: size, rgba: pixels(size))
        cache.setObject(data as NSData, forKey: size as NSNumber)
        return data
    }

    private static func pixels(_ n: Int) -> [UInt8] {
        let s = Double(n)
        let c = s / 2, r = s * 0.34
        let bands: [Double] = [0.95, 0.45, 0.85, 0.3, 0.9, 0.5, 0.95]
        let shadeCenter = (c - r * 0.35, c - r * 0.4), spot = (c - r * 0.38, c - r * 0.42)
        var out = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                // Background: a dark vertical gradient.
                let t = py / s
                var rgb = (0.17 - 0.11 * t, 0.17 - 0.11 * t, 0.19 - 0.12 * t)
                let dx = px - c, dy = py - c, d = (dx * dx + dy * dy).squareRoot()
                // Soft glow behind the orb.
                let glow = max(0, 1 - abs(d - r) / (r * 0.35)) * 0.12
                rgb = (rgb.0 + glow, rgb.1 + glow, rgb.2 + glow)
                let cover = min(max(r - d + 0.5, 0), 1)
                if cover > 0 {
                    // Chrome: light and dark reflections around the ball.
                    var f = atan2(dy, dx) / (2 * .pi)
                    if f < 0 { f += 1 }
                    let pos = f * Double(bands.count - 1), k = min(Int(pos), bands.count - 2)
                    var g = bands[k] + (bands[k + 1] - bands[k]) * (pos - Double(k))
                    // Blend the reflections together in the middle.
                    let core = 0.95 * max(0, 1 - d / (r * 0.7))
                    g = g * (1 - core) + 0.78 * core
                    // Shading, lit from the top left.
                    let sd = hypot(px - shadeCenter.0, py - shadeCenter.1) / (r * 1.35)
                    let dark = sd < 0.6 ? 0.15 * sd / 0.6 : 0.15 + 0.4 * min((sd - 0.6) / 0.4, 1)
                    g *= 1 - dark
                    // Highlight.
                    let hl = 0.95 * max(0, 1 - hypot(px - spot.0, py - spot.1) / (r * 0.5))
                    g = g * (1 - hl) + hl
                    // Thin dark rim.
                    if d > r - s * 0.006 { g *= 0.6 }
                    rgb = (rgb.0 * (1 - cover) + g * cover, rgb.1 * (1 - cover) + g * cover, rgb.2 * (1 - cover) + g * cover)
                }
                let i = (y * n + x) * 4
                out[i] = UInt8(min(max(rgb.0, 0), 1) * 255)
                out[i + 1] = UInt8(min(max(rgb.1, 0), 1) * 255)
                out[i + 2] = UInt8(min(max(rgb.2, 0), 1) * 255)
                out[i + 3] = 255
            }
        }
        return out
    }
}

/// Minimal PNG writer (8-bit RGBA, no filtering). Compressed with zlib where Foundation offers it.
enum PNG {
    static func encode(width: Int, height: Int, rgba: [UInt8]) -> Data {
        var raw = Data(capacity: (width * 4 + 1) * height)
        for y in 0..<height {
            raw.append(0)   // filter: none
            raw.append(contentsOf: rgba[(y * width * 4)..<((y + 1) * width * 4)])
        }
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.append(be32(width)); ihdr.append(be32(height))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])
        chunk("IHDR", ihdr, into: &png)
        chunk("IDAT", zlib(raw), into: &png)
        chunk("IEND", Data(), into: &png)
        return png
    }

    private static func zlib(_ data: Data) -> Data {
        var out = Data([0x78, 0x01])
        #if canImport(Darwin)
        if let deflated = try? (data as NSData).compressed(using: .zlib) {   // raw DEFLATE
            out[1] = 0x9C
            out.append(deflated as Data)
            out.append(be32(Int(adler32(data))))
            return out
        }
        #endif
        // Stored (uncompressed) DEFLATE blocks.
        var offset = 0
        repeat {
            let len = min(65535, data.count - offset)
            let last: UInt8 = offset + len == data.count ? 1 : 0
            out.append(contentsOf: [last, UInt8(len & 0xFF), UInt8(len >> 8), UInt8(~len & 0xFF), UInt8((~len >> 8) & 0xFF)])
            out.append(data[(data.startIndex + offset)..<(data.startIndex + offset + len)])
            offset += len
        } while offset < data.count
        out.append(be32(Int(adler32(data))))
        return out
    }

    private static func chunk(_ type: String, _ body: Data, into png: inout Data) {
        png.append(be32(body.count))
        let typed = Data(type.utf8) + body
        png.append(typed)
        png.append(be32(Int(crc32(typed))))
    }

    private static func be32(_ v: Int) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        return b << 16 | a
    }
}
