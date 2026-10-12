import AppKit
import FaceOrbCore
import SwiftUI

/// Plain AppKit entry point. A SwiftUI `App` needs at least one scene, and with only a Settings
/// scene SwiftUI opens that window whenever the app is activated without a visible window, which
/// happened every time the dropdown opened. Everything in it lives in the dropdown's Privacy tab.
@main
enum FaceOrbMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = makeMainMenu()
        withExtendedLifetime(delegate) { app.run() }
    }

    /// Never shown (FaceOrb has no menu bar), but its key equivalents make ⌘V/⌘C/⌘X/⌘A/⌘Z
    /// work in text fields, e.g. pasting an album link, and ⌘W close the review window.
    @MainActor private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit FaceOrb", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }
}

/// Draws the menu bar orb: a small chrome ball whose reflections turn with `spin` (0..<1).
/// Not a template image, so it keeps its metal shading; the badge colours are resolved when
/// drawn (cacheMode .never), so they follow light and dark menu bars.
enum OrbIcon {
    static let height: CGFloat = 18
    private static let orb: CGFloat = 16

    /// - progress: nil when idle; .some(nil) while busy without a known fraction; .some(f) for 0...1.
    static func image(progress: Double??, count: Int, update: Bool, spin: Double = 0) -> NSImage {
        let text = count > 99 ? "99+" : count > 0 ? "\(count)" : nil
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        let textSize = text.map { ($0 as NSString).size(withAttributes: [.font: font]) } ?? .zero
        let pill = text == nil ? CGSize.zero : CGSize(width: max(12, textSize.width + 7), height: 12)
        let width = orb + 2 + (text == nil ? 0 : 2 + pill.width)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let center = CGPoint(x: 1 + orb / 2, y: height / 2)
            // Leave room for the progress ring while working.
            let r = progress == nil ? orb / 2 - 0.5 : orb / 2 - 2.5
            let ball = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
            let space = CGColorSpaceCreateDeviceRGB()
            func gray(_ w: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(gray: w, alpha: a) }

            ctx.saveGState()
            ctx.addEllipse(in: ball)
            ctx.clip()
            // Chrome: alternating light and dark reflections around the ball, turned by `spin`.
            let bands: [CGFloat] = [0.95, 0.45, 0.85, 0.3, 0.9, 0.5, 0.95]
            let wedges = 72
            for i in 0..<wedges {
                let f = CGFloat(i) / CGFloat(wedges)
                let pos = f * CGFloat(bands.count - 1), k = min(Int(pos), bands.count - 2), t = pos - CGFloat(k)
                ctx.setFillColor(gray(bands[k] + (bands[k + 1] - bands[k]) * t))
                let a0 = (f + CGFloat(spin)) * 2 * .pi, a1 = a0 + 2 * .pi / CGFloat(wedges) + 0.02
                ctx.move(to: center)
                ctx.addArc(center: center, radius: r + 1, startAngle: a0, endAngle: a1, clockwise: false)
                ctx.closePath()
                ctx.fillPath()
            }
            // Blend the reflections together in the middle, so it reads as a ball rather than a knob.
            let core = CGGradient(colorsSpace: space, colors: [gray(0.78, 0.95), gray(0.78, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(core, startCenter: center, startRadius: 0, endCenter: center, endRadius: r * 0.7, options: [])
            // Shading for a round, lit-from-top-left look.
            let shade = CGGradient(colorsSpace: space, colors: [gray(1, 0), gray(0, 0.15), gray(0, 0.55)] as CFArray,
                                   locations: [0, 0.6, 1])!
            ctx.drawRadialGradient(shade, startCenter: CGPoint(x: center.x - r * 0.35, y: center.y - r * 0.4), startRadius: 0,
                                   endCenter: center, endRadius: r, options: [])
            let shine = CGGradient(colorsSpace: space, colors: [gray(1, 0.95), gray(1, 0)] as CFArray, locations: [0, 1])!
            let spot = CGPoint(x: center.x - r * 0.38, y: center.y - r * 0.42)
            ctx.drawRadialGradient(shine, startCenter: spot, startRadius: 0, endCenter: spot, endRadius: r * 0.5, options: [])
            ctx.restoreGState()
            // A thin dark rim keeps it visible on a light menu bar.
            ctx.setStrokeColor(gray(0, 0.45))
            ctx.setLineWidth(0.75)
            ctx.strokeEllipse(in: ball.insetBy(dx: 0.375, dy: 0.375))

            if let progress {
                let ring = NSBezierPath()
                ring.appendArc(withCenter: center, radius: orb / 2 - 0.75, startAngle: 0, endAngle: 360)
                ring.lineWidth = 1.5
                NSColor.labelColor.withAlphaComponent(0.25).setStroke()
                ring.stroke()
                let arc = NSBezierPath()
                let f = progress.map { min(max($0, 0.04), 1) } ?? 0.3
                arc.appendArc(withCenter: center, radius: orb / 2 - 0.75, startAngle: -90, endAngle: -90 + 360 * f)
                arc.lineWidth = 1.5
                arc.lineCapStyle = .round
                NSColor.controlAccentColor.setStroke()
                arc.stroke()
            }

            // Update ready: an accent dot at the top-right, cut out from the ball so it reads clearly.
            if update {
                let dot = CGPoint(x: center.x + r * 0.72, y: center.y - r * 0.72)
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: CGRect(x: dot.x - 3.2, y: dot.y - 3.2, width: 6.4, height: 6.4))
                ctx.setBlendMode(.normal)
                NSColor.controlAccentColor.setFill()
                ctx.fillEllipse(in: CGRect(x: dot.x - 2.3, y: dot.y - 2.3, width: 4.6, height: 4.6))
            }

            // Review count: a pill in the menu bar's text colour with the number knocked out.
            if let text {
                let rect = CGRect(x: orb + 4, y: (height - pill.height) / 2, width: pill.width, height: pill.height)
                NSColor.labelColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
                ctx.setBlendMode(.destinationOut)
                (text as NSString).draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                                        withAttributes: [.font: font, .foregroundColor: NSColor.black])
                ctx.setBlendMode(.normal)
            }
            return true
        }
        image.cacheMode = NSImage.CacheMode.never
        return image
    }
}
