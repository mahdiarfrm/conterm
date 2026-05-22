// Crops a PNG to its fully-opaque artwork (alpha ≥ 200) and rescales
// to fill a 1024×1024 canvas with a small safe-area margin. Skips
// translucent decorations (drop shadows, glassy outer frames, etc.).
//
//   swift scripts/fit-icon.swift Resources/AppIcon.png

import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: swift fit-icon.swift <source.png> [output.png]\n", stderr)
    exit(1)
}
let sourcePath = args[1]
let outPath = args.count >= 3 ? args[2] : sourcePath
let canvasSize: CGFloat = 1024
let safeMargin: CGFloat = 40
let opaqueThreshold: UInt8 = 200

// Load via CGImageSource (skip NSImage caching weirdness).
guard let src = CGImageSourceCreateWithURL(
    URL(fileURLWithPath: sourcePath) as CFURL, nil
), let cgIn = CGImageSourceCreateImageAtIndex(src, 0, nil)
else { fputs("can't load \(sourcePath)\n", stderr); exit(1) }
let w = cgIn.width, h = cgIn.height
print("loaded: \(w)x\(h)")

// Decode to a known RGBA8 buffer.
let cs = CGColorSpaceCreateDeviceRGB()
let bpp = 4
let bpr = w * bpp
let total = h * bpr
let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: total)
defer { buf.deallocate() }
buf.initialize(repeating: 0, count: total)
guard let decode = CGContext(
    data: buf, width: w, height: h, bitsPerComponent: 8,
    bytesPerRow: bpr, space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fputs("ctx alloc failed\n", stderr); exit(1) }
decode.draw(cgIn, in: CGRect(x: 0, y: 0, width: w, height: h))

// Find bbox of solidly-opaque pixels (a ≥ opaqueThreshold). NOTE: the
// decoded buffer is in CG bottom-up coordinates — buf[y=0..] is the
// VISUAL BOTTOM of the image. We convert back to image coords at the
// end before cropping.
var minX = w, minY_buf = h, maxX = -1, maxY_buf = -1
for y in 0..<h {
    for x in 0..<w {
        let a = buf[y * bpr + x * bpp + 3]
        if a >= opaqueThreshold {
            if x < minX { minX = x }
            if y < minY_buf { minY_buf = y }
            if x > maxX { maxX = x }
            if y > maxY_buf { maxY_buf = y }
        }
    }
}
guard maxX >= 0 else {
    fputs("no solid artwork found (everything is translucent)\n", stderr)
    exit(1)
}
// Convert buffer y → image y (flip vertically).
let imageY1 = (h - 1) - maxY_buf
let imageY2 = (h - 1) - minY_buf
let cw = maxX - minX + 1, ch = imageY2 - imageY1 + 1
print("opaque bbox (image coords): (\(minX),\(imageY1))-(\(maxX),\(imageY2))  \(cw)x\(ch)")

// Crop the CGImage to that bbox.
guard let cropped = cgIn.cropping(
    to: CGRect(x: minX, y: imageY1, width: cw, height: ch)
) else { fputs("crop failed\n", stderr); exit(1) }

// Compose onto a fresh 1024×1024 canvas, scaled to fill (minus margin).
let target = canvasSize - 2 * safeMargin
let scale = min(target / CGFloat(cw), target / CGFloat(ch))
let drawW = CGFloat(cw) * scale, drawH = CGFloat(ch) * scale
let drawX = (canvasSize - drawW) / 2
let drawY = (canvasSize - drawH) / 2

guard let outCtx = CGContext(
    data: nil,
    width: Int(canvasSize), height: Int(canvasSize),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fputs("output ctx failed\n", stderr); exit(1) }
outCtx.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
outCtx.interpolationQuality = .high
outCtx.draw(cropped, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))

guard let outImage = outCtx.makeImage() else {
    fputs("makeImage failed\n", stderr); exit(1)
}
let rep = NSBitmapImageRep(cgImage: outImage)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("png encode failed\n", stderr); exit(1)
}
try pngData.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(pngData.count) bytes)  artwork scaled to \(Int(drawW))x\(Int(drawH))")
