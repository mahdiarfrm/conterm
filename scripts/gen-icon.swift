// Generates Resources/AppIcon.png (1024×1024) for Conterm — a minimal
// glassy terminal icon: rounded square with a translucent gradient,
// soft inner glow, top sheen, and a "> _" prompt symbol in the center.
//
// Run with:
//   swift scripts/gen-icon.swift && bash scripts/make-icon.sh Resources/AppIcon.png

import AppKit
import CoreGraphics
import Foundation

let size = CGSize(width: 1024, height: 1024)
let outPath = "Resources/AppIcon.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: .alphaFirst,
    bytesPerRow: 0, bitsPerPixel: 32
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Clear to fully transparent first.
ctx.clear(CGRect(origin: .zero, size: size))

// Outer rounded square — masks all the glass content.
let inset: CGFloat = 80
let bgRect = CGRect(x: inset, y: inset,
                     width: size.width - 2*inset,
                     height: size.height - 2*inset)
let cornerRadius: CGFloat = 200
let bgPath = NSBezierPath(roundedRect: bgRect,
                           xRadius: cornerRadius,
                           yRadius: cornerRadius).cgPath

// Drop shadow under the square (soft, large).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -30),
              blur: 80,
              color: NSColor.black.withAlphaComponent(0.45).cgColor)
ctx.addPath(bgPath)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()
ctx.restoreGState()

// Glass base: vertical gradient (deep slate top → near-black bottom).
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let baseGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor(red: 0.12, green: 0.14, blue: 0.20, alpha: 1.0).cgColor,
        NSColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1.0).cgColor,
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    baseGradient,
    start: CGPoint(x: 0, y: bgRect.maxY),
    end:   CGPoint(x: 0, y: bgRect.minY),
    options: []
)
ctx.restoreGState()

// Glass top sheen — bright white gradient fading down across the top.
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let sheen = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor.white.withAlphaComponent(0.30).cgColor,
        NSColor.white.withAlphaComponent(0.05).cgColor,
        NSColor.clear.cgColor,
    ] as CFArray,
    locations: [0.0, 0.35, 0.70]
)!
ctx.drawLinearGradient(
    sheen,
    start: CGPoint(x: 0, y: bgRect.maxY),
    end:   CGPoint(x: 0, y: bgRect.minY),
    options: []
)
ctx.restoreGState()

// Diagonal sheen (top-leading corner glass-highlight stripe).
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let diagSheen = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor.white.withAlphaComponent(0.18).cgColor,
        NSColor.clear.cgColor,
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    diagSheen,
    start: CGPoint(x: bgRect.minX, y: bgRect.maxY),
    end:   CGPoint(x: bgRect.midX, y: bgRect.midY),
    options: []
)
ctx.restoreGState()

// Inner highlight stroke (the "wet glass edge").
ctx.saveGState()
let innerStroke = NSBezierPath(roundedRect: bgRect.insetBy(dx: 6, dy: 6),
                                xRadius: cornerRadius - 6,
                                yRadius: cornerRadius - 6)
ctx.addPath(innerStroke.cgPath)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.20).cgColor)
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// Subtle outer stroke (defines the silhouette).
ctx.saveGState()
ctx.addPath(bgPath)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
ctx.setLineWidth(2)
ctx.strokePath()
ctx.restoreGState()

// "> _" prompt glyph in the center.
let prompt = "> _"
let promptFontSize: CGFloat = 320
let promptFont = NSFont.systemFont(ofSize: promptFontSize, weight: .light)
let promptAttrs: [NSAttributedString.Key: Any] = [
    .font: promptFont,
    .foregroundColor: NSColor.white.withAlphaComponent(0.95),
    .shadow: { () -> NSShadow in
        let s = NSShadow()
        s.shadowColor = NSColor.white.withAlphaComponent(0.4)
        s.shadowBlurRadius = 18
        s.shadowOffset = .zero
        return s
    }(),
]
let promptStr = NSAttributedString(string: prompt, attributes: promptAttrs)
let textSize = promptStr.size()
let textOrigin = CGPoint(
    x: (size.width - textSize.width) / 2,
    y: (size.height - textSize.height) / 2 - 10
)
promptStr.draw(at: textOrigin)

NSGraphicsContext.restoreGraphicsState()

// Write PNG.
guard let data = rep.representation(using: .png, properties: [:]) else {
    fputs("ERROR: failed to encode PNG\n", stderr)
    exit(1)
}
let url = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try data.write(to: url)
print("Wrote \(outPath) (\(data.count) bytes)")
