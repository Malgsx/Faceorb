// Usage: swift assets/make-web-icons.swift Sources/FaceOrbWeb/Resources
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Pass the icon output directory.")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 20 / 255, green: 20 / 255, blue: 22 / 255, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)

let center = CGPoint(x: size / 2, y: size / 2)
let radius = CGFloat(size) * 0.36
let ball = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
func gray(_ value: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(gray: value, alpha: alpha)
}
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 12), blur: 24, color: gray(0, 0.6))
context.setFillColor(gray(0.7))
context.fillEllipse(in: ball)
context.restoreGState()
context.saveGState()
context.addEllipse(in: ball)
context.clip()

// Match the menu-bar orb's chrome reflections and fixed top-left lighting.
let bands: [CGFloat] = [0.95, 0.45, 0.85, 0.3, 0.9, 0.5, 0.95]
for index in 0..<720 {
    let fraction = CGFloat(index) / 720
    let position = fraction * CGFloat(bands.count - 1)
    let band = min(Int(position), bands.count - 2)
    let mix = position - CGFloat(band)
    context.setFillColor(gray(bands[band] + (bands[band + 1] - bands[band]) * mix))
    let angle = fraction * 2 * .pi
    context.move(to: center)
    context.addArc(center: center, radius: radius + 1, startAngle: angle, endAngle: angle + 2 * .pi / 720 + 0.002, clockwise: false)
    context.closePath()
    context.fillPath()
}
let core = CGGradient(colorsSpace: space, colors: [gray(0.78, 0.95), gray(0.78, 0)] as CFArray, locations: [0, 1])!
context.drawRadialGradient(core, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius * 0.7, options: [])
let shade = CGGradient(colorsSpace: space, colors: [gray(1, 0), gray(0, 0.15), gray(0, 0.55)] as CFArray, locations: [0, 0.6, 1])!
context.drawRadialGradient(
    shade, startCenter: CGPoint(x: center.x - radius * 0.35, y: center.y - radius * 0.4), startRadius: 0,
    endCenter: center, endRadius: radius, options: [])
let shine = CGGradient(colorsSpace: space, colors: [gray(1, 0.95), gray(1, 0)] as CFArray, locations: [0, 1])!
let spot = CGPoint(x: center.x - radius * 0.38, y: center.y - radius * 0.42)
context.drawRadialGradient(shine, startCenter: spot, startRadius: 0, endCenter: spot, endRadius: radius * 0.5, options: [])
context.restoreGState()
context.setStrokeColor(gray(1, 0.2))
context.setLineWidth(2)
context.strokeEllipse(in: ball)
let image = context.makeImage()!

for (name, pixels) in [("apple-touch-icon.png", 180), ("icon-512.png", 512), ("faceorb-icon.png", 1024)] {
    let output = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    output.interpolationQuality = .high
    output.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let bitmap = NSBitmapImageRep(cgImage: output.makeImage()!)
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: directory.appendingPathComponent(name))
}
