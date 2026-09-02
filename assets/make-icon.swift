// Turns assets/source-icon.png into the PNG set that iconutil wants.
// Run via assets/make-icon.sh; only needed when the artwork changes, since the built
// icon.icns is committed.
//
// Two things it has to do beyond resizing:
//
//  - Trim the flat black border. Art tends to arrive as an opaque square, and an app
//    icon whose corners are opaque renders as a black tile in the Dock.
//  - Round off the corners itself. Cropping to the artwork's bounds keeps the black
//    that sits outside the rounded shape, so the corners have to be masked away.
//
// Everything used here is in AppKit, so this needs no tools beyond the Swift compiler.

import AppKit

let args = CommandLine.arguments
let srcPath = args.count > 1 ? args[1] : "./source-icon.png"
let outDir = args.count > 2 ? args[2] : "./icon.iconset"

guard let src = NSImage(contentsOfFile: srcPath),
      let srcCG = src.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fatalError("could not read \(srcPath)") }

let w = srcCG.width, h = srcCG.height

// Read the pixels once so the border scan is cheap.
var pixels = [UInt8](repeating: 0, count: w * h * 4)
guard let scan = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                           bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("could not build a scan context") }
scan.draw(srcCG, in: CGRect(x: 0, y: 0, width: w, height: h))

// "Black" with a little slack: the artwork's own background is dark, but not this dark.
func isBorder(_ x: Int, _ y: Int) -> Bool {
    let i = (y * w + x) * 4
    return pixels[i] < 8 && pixels[i + 1] < 8 && pixels[i + 2] < 8
}

var minX = 0, maxX = w - 1, minY = 0, maxY = h - 1
let midX = w / 2, midY = h / 2
while minX < midX, (0..<h).allSatisfy({ isBorder(minX, $0) }) { minX += 1 }
while maxX > midX, (0..<h).allSatisfy({ isBorder(maxX, $0) }) { maxX -= 1 }
while minY < midY, (0..<w).allSatisfy({ isBorder($0, minY) }) { minY += 1 }
while maxY > midY, (0..<w).allSatisfy({ isBorder($0, maxY) }) { maxY -= 1 }

// Square it off from the centre of what was found, so a slightly uneven trim does not
// stretch the artwork.
let side = min(maxX - minX + 1, maxY - minY + 1)
let cropX = minX + (maxX - minX + 1 - side) / 2
let cropY = minY + (maxY - minY + 1 - side) / 2
guard let art = srcCG.cropping(to: CGRect(x: cropX, y: cropY, width: side, height: side))
else { fatalError("crop failed") }
print("trimmed to \(side)x\(side) at \(cropX),\(cropY)")

// macOS art sits inside its canvas rather than filling it: 824 of 1024, the rest left
// clear for the system's shadow.
let canvas = 1024.0, inset = (canvas - 824.0) / 2

let master = NSImage(size: NSSize(width: canvas, height: canvas))
master.lockFocus()
let shape = NSRect(x: inset, y: inset, width: 824, height: 824)
let path = NSBezierPath(roundedRect: shape, xRadius: 824 * 0.225, yRadius: 824 * 0.225)
path.addClip()
NSImage(cgImage: art, size: shape.size).draw(in: shape)
master.unlockFocus()

let sizes: [(px: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (px, name) in sizes {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { continue }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    if let png = bitmap.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    }
}
print("wrote \(sizes.count) pngs to \(outDir)")
