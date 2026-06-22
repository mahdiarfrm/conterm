// Turn a flat, full-bleed square PNG into Conterm's macOS app icon:
// round it to the squircle, inset it into the standard safe area, add the
// soft drop shadow, and emit ICONS_FINAL/{16,32,64,128,256,512,1024}.png
// (the set build.sh packs raw into AppIcon.icns). The source needs NO
// corners — the shape is applied here. Shape constants match gen-icon.swift.
//
//   swift scripts/shape-icon.swift SOURCE.png            # opaque icon
//   swift scripts/shape-icon.swift SOURCE.png --glass    # + ICONS_GLASS/ translucent variant
//
// --glass maps luminance→alpha (dark background fades toward see-through,
// bright elements stay solid) for the Arc-style look; tune `glassFloor`/
// `glassGamma` after eyeballing it on the Dock.

import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: swift shape-icon.swift SOURCE.png [--glass]\n", stderr); exit(1)
}
let srcPath = args[1]
let makeGlass = args.contains("--glass")

let canvas: CGFloat = 1024
let inset: CGFloat = 80          // safe-area margin (matches gen-icon.swift)
let cornerRadius: CGFloat = 200  // on the inset 864 square
let glassFloor: CGFloat = 0.0    // min alpha for the darkest pixels (0 = fully clear)
let glassGamma: CGFloat = 1.6    // >1 keeps mid-darks fainter

guard let imgSrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: srcPath) as CFURL, nil),
      let cgIn = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil) else {
    fputs("can't load \(srcPath)\n", stderr); exit(1)
}

let cs = CGColorSpaceCreateDeviceRGB()

/// Render the shaped 1024×1024 master once.
func renderMaster() -> CGImage {
    guard let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas),
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fputs("ctx alloc failed\n", stderr); exit(1)
    }
    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    ctx.interpolationQuality = .high

    let rect = CGRect(x: inset, y: inset, width: canvas - 2*inset, height: canvas - 2*inset)
    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius,
                      cornerHeight: cornerRadius, transform: nil)

    // Soft drop shadow under the squircle.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -30), blur: 80,
                  color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    // Clip to the squircle and draw the source filling the safe area.
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.draw(cgIn, in: rect)   // CGContext scales to fill the rect
    ctx.restoreGState()

    guard let out = ctx.makeImage() else { fputs("makeImage failed\n", stderr); exit(1) }
    return out
}

/// Re-key a shaped master so alpha tracks luminance (dark → transparent).
func toGlass(_ master: CGImage) -> CGImage {
    let w = master.width, h = master.height, bpr = w * 4
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: h * bpr)
    defer { buf.deallocate() }
    guard let c = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fputs("glass ctx failed\n", stderr); exit(1)
    }
    c.draw(master, in: CGRect(x: 0, y: 0, width: w, height: h))
    for i in stride(from: 0, to: h * bpr, by: 4) {
        let a = CGFloat(buf[i+3]) / 255.0
        guard a > 0 else { continue }                       // outside the squircle stays clear
        // premultiplied → recover luma, map to new alpha.
        let r = CGFloat(buf[i]) / 255.0, g = CGFloat(buf[i+1]) / 255.0, b = CGFloat(buf[i+2]) / 255.0
        let luma = (0.299*r + 0.587*g + 0.114*b) / max(a, 0.001)
        let na = glassFloor + (1 - glassFloor) * pow(min(max(luma, 0), 1), glassGamma)
        let scale = na / a
        buf[i]   = UInt8(min(255, CGFloat(buf[i])   * scale))
        buf[i+1] = UInt8(min(255, CGFloat(buf[i+1]) * scale))
        buf[i+2] = UInt8(min(255, CGFloat(buf[i+2]) * scale))
        buf[i+3] = UInt8(min(255, na * 255))
    }
    guard let out = c.makeImage() else { fputs("glass makeImage failed\n", stderr); exit(1) }
    return out
}

/// Downscale a 1024 master into the ICONS_FINAL set.
func emit(_ master: CGImage, into dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for s in [16, 32, 64, 128, 256, 512, 1024] {
        guard let c = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8,
                                bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
        c.interpolationQuality = .high
        c.clear(CGRect(x: 0, y: 0, width: s, height: s))
        c.draw(master, in: CGRect(x: 0, y: 0, width: s, height: s))
        guard let img = c.makeImage() else { continue }
        let rep = NSBitmapImageRep(cgImage: img)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "\(dir)/\(s).png"))
        }
    }
    print("wrote \(dir)/{16,32,64,128,256,512,1024}.png")
}

let master = renderMaster()
emit(master, into: "ICONS_FINAL")
if makeGlass { emit(toGlass(master), into: "ICONS_GLASS") }
