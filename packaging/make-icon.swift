// Generates AppIcon.iconset PNGs for Ghostty Config Manager — no external image
// asset needed. Draws a rounded-squircle with an indigo→violet gradient and a
// bold white ">_" terminal prompt, rendered crisply at every macOS icon size.
//
// Usage:  swift packaging/make-icon.swift <iconset-output-dir>
// Then:   iconutil -c icns <iconset-output-dir> -o packaging/AppIcon.icns
import AppKit

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <iconset-dir>\n".utf8))
    exit(1)
}
let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!

    func pt(_ fx: CGFloat, _ fy: CGFloat) -> NSPoint { NSPoint(x: s * fx, y: s * fy) }

    // Squircle background with a diagonal indigo→violet gradient.
    let inset = s * 0.055
    let side = s - 2 * inset
    let squircle = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: side, height: side),
                                xRadius: side * 0.225, yRadius: side * 0.225)
    let top = NSColor(srgbRed: 0.49, green: 0.40, blue: 1.00, alpha: 1.0)   // #7D66FF
    let bottom = NSColor(srgbRed: 0.26, green: 0.16, blue: 0.66, alpha: 1.0) // #4329A8
    NSGradient(starting: top, ending: bottom)!.draw(in: squircle, angle: -90)

    // ">_" prompt in white, with a soft drop shadow for depth.
    let glow = NSShadow()
    glow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    glow.shadowBlurRadius = s * 0.02
    glow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    glow.set()

    NSColor.white.setStroke()
    let lineWidth = s * 0.072

    let chevron = NSBezierPath()
    chevron.lineWidth = lineWidth
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.move(to: pt(0.33, 0.65))
    chevron.line(to: pt(0.54, 0.50))
    chevron.line(to: pt(0.33, 0.35))
    chevron.stroke()

    let cursor = NSBezierPath()
    cursor.lineWidth = lineWidth
    cursor.lineCapStyle = .round
    cursor.move(to: pt(0.58, 0.355))
    cursor.line(to: pt(0.72, 0.355))
    cursor.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),   ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),   ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

var cache: [Int: Data] = [:]
for (name, px) in entries {
    let data = cache[px] ?? render(px)
    cache[px] = data
    try data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
print("wrote \(entries.count) icon PNGs to \(outDir)")
