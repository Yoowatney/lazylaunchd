// Generates assets/icon.icns. Run via assets/make-icon.sh - you only need this
// when changing the icon; the built .icns is committed so a plain install doesn't
// have to render anything.
//
// Draws the macOS app-icon shape (squircle-ish rounded rect) with a gradient and a
// play glyph, at every size iconutil expects.

import AppKit

let sizes: [(px: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./icon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for (px, name) in sizes {
    let size = CGFloat(px)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    // macOS icons sit inside the canvas rather than filling it.
    let inset = size * 0.085
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let body = NSBezierPath(roundedRect: rect,
                            xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.53, green: 0.31, blue: 0.92, alpha: 1),
    ])?.draw(in: body, angle: -90)

    // Top edge highlight, which is what makes a flat rectangle read as an app icon.
    NSGraphicsContext.current?.saveGraphicsState()
    body.addClip()
    NSGradient(colors: [
        NSColor(white: 1, alpha: 0.28), NSColor(white: 1, alpha: 0),
    ])?.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2),
             angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Clock ring - the "scheduled" half of the idea.
    let ringInset = rect.width * 0.24
    let ring = NSRect(x: rect.minX + ringInset, y: rect.minY + ringInset,
                      width: rect.width - ringInset * 2, height: rect.height - ringInset * 2)
    let ringPath = NSBezierPath(ovalIn: ring)
    ringPath.lineWidth = max(1, rect.width * 0.055)
    NSColor(white: 1, alpha: 0.92).setStroke()
    ringPath.stroke()

    // Play triangle - the "run it now" half.
    let c = NSPoint(x: ring.midX, y: ring.midY)
    let r = ring.width * 0.24
    let tri = NSBezierPath()
    tri.move(to: NSPoint(x: c.x - r * 0.62, y: c.y + r))
    tri.line(to: NSPoint(x: c.x - r * 0.62, y: c.y - r))
    tri.line(to: NSPoint(x: c.x + r, y: c.y))
    tri.close()
    NSColor(white: 1, alpha: 0.96).setFill()
    tri.fill()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { continue }
    // The NSImage is in points; force the pixel dimensions iconutil expects.
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:]) ?? png
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("wrote \(sizes.count) pngs to \(outDir)")
