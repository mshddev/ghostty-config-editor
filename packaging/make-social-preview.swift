// Renders the GitHub social-preview card (Open Graph image) for Ghostty Config
// Editor — 1280×640, the size GitHub recommends. It reuses the app icon's exact
// squircle + slider mark and brand purples so the card and the icon read as one
// identity. No external asset needed.
//
// Usage:  swift packaging/make-social-preview.swift assets/social-preview.png
import AppKit

let outPath = CommandLine.arguments.count >= 2 ? CommandLine.arguments[1] : "assets/social-preview.png"

let W = 1280, H = 640
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!

let w = CGFloat(W), h = CGFloat(H)

// Dark, faintly-violet background — the app's own palette, so the vibrant icon
// and white wordmark pop instead of blending into a purple field.
let bgTop = NSColor(srgbRed: 0.094, green: 0.078, blue: 0.129, alpha: 1)   // #18141F
let bgBottom = NSColor(srgbRed: 0.043, green: 0.035, blue: 0.070, alpha: 1) // #0B0912
NSGradient(starting: bgTop, ending: bgBottom)!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

// Soft purple glow behind the icon for depth.
let glowCenter = NSPoint(x: w / 2, y: h * 0.64)
NSGradient(colors: [
    NSColor(srgbRed: 0.49, green: 0.40, blue: 1.0, alpha: 0.30),
    NSColor(srgbRed: 0.49, green: 0.40, blue: 1.0, alpha: 0.0),
])!.draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: h * 0.42, options: [])

// The app icon: squircle with an indigo→violet gradient and three white sliders,
// identical construction to packaging/make-icon.swift.
func drawIcon(x: CGFloat, y: CGFloat, d: CGFloat) {
    let inset = d * 0.055
    let side = d - 2 * inset
    let squircle = NSBezierPath(roundedRect: NSRect(x: x + inset, y: y + inset, width: side, height: side),
                                xRadius: side * 0.225, yRadius: side * 0.225)

    // Drop shadow so the chip lifts off the dark background.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = d * 0.10
    shadow.shadowOffset = NSSize(width: 0, height: -d * 0.04)
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    let top = NSColor(srgbRed: 0.49, green: 0.40, blue: 1.00, alpha: 1.0)   // #7D66FF
    let bottom = NSColor(srgbRed: 0.26, green: 0.16, blue: 0.66, alpha: 1.0) // #4329A8
    NSGradient(starting: top, ending: bottom)!.draw(in: NSRect(x: x, y: y, width: d, height: d), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    func slider(fy: CGFloat, knob: CGFloat) {
        let x0: CGFloat = 0.28, x1: CGFloat = 0.72
        let th = d * 0.05
        let track = NSBezierPath(roundedRect: NSRect(x: x + d * x0, y: y + d * fy - th / 2,
                                                     width: d * (x1 - x0), height: th),
                                 xRadius: th / 2, yRadius: th / 2)
        NSColor.white.withAlphaComponent(0.32).setFill()
        track.fill()
        let r = d * 0.052
        let kx = x + d * (x0 + (x1 - x0) * knob)
        let dot = NSBezierPath(ovalIn: NSRect(x: kx - r, y: y + d * fy - r, width: r * 2, height: r * 2))
        NSColor.white.setFill()
        dot.fill()
    }
    slider(fy: 0.635, knob: 0.62)
    slider(fy: 0.500, knob: 0.34)
    slider(fy: 0.365, knob: 0.72)
}

let iconD: CGFloat = 196
drawIcon(x: (w - iconD) / 2, y: 388, d: iconD)

// Centered text.
func drawCentered(_ s: String, font: NSFont, color: NSColor, baseline y: CGFloat, tracking: CGFloat = 0) {
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if tracking != 0 { attrs[.kern] = tracking }
    let str = NSAttributedString(string: s, attributes: attrs)
    let size = str.size()
    str.draw(at: NSPoint(x: (w - size.width) / 2, y: y))
}

drawCentered("Ghostty Config Editor",
             font: .systemFont(ofSize: 74, weight: .bold),
             color: .white, baseline: 276, tracking: 0.5)

drawCentered("An unofficial, native macOS app for editing your Ghostty config",
             font: .systemFont(ofSize: 28, weight: .regular),
             color: NSColor.white.withAlphaComponent(0.62), baseline: 214)

// A small row of theme swatches — a nod to the live-theme feature and a bit of
// color on an otherwise mono card.
let swatches: [NSColor] = [
    NSColor(srgbRed: 0.98, green: 0.38, blue: 0.42, alpha: 1),
    NSColor(srgbRed: 0.98, green: 0.66, blue: 0.30, alpha: 1),
    NSColor(srgbRed: 0.96, green: 0.86, blue: 0.36, alpha: 1),
    NSColor(srgbRed: 0.44, green: 0.84, blue: 0.52, alpha: 1),
    NSColor(srgbRed: 0.36, green: 0.80, blue: 0.86, alpha: 1),
    NSColor(srgbRed: 0.49, green: 0.55, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.72, green: 0.52, blue: 0.98, alpha: 1),
]
let dotR: CGFloat = 9, gap: CGFloat = 34
let rowW = CGFloat(swatches.count - 1) * gap
var dx = w / 2 - rowW / 2
for c in swatches {
    c.setFill()
    NSBezierPath(ovalIn: NSRect(x: dx - dotR, y: 150 - dotR, width: dotR * 2, height: dotR * 2)).fill()
    dx += gap
}

NSGraphicsContext.restoreGraphicsState()

let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(W)×\(H) social preview to \(outPath)")
