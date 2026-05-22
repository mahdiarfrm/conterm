#!/usr/bin/env swift
// Renders the Conterm DMG window background: a white canvas with a
// subtle drag arrow between the two icon slots and the Conterm
// text-logo (tinted black) near the bottom. Output is a @2x TIFF so
// the background stays crisp on Retina displays.
//
// Usage: swift dmg-background.swift <out.tiff> <text-logo.png>
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(
        Data("usage: dmg-background.swift <out.tiff> <logo.png>\n".utf8))
    exit(1)
}
let outPath = args[1]
let logoPath = args[2]

// Window content size in points. Must match the Finder window bounds
// and icon positions set in scripts/release.sh. The bitmap is twice
// that in pixels; setting rep.size makes the graphics context map
// point coordinates → pixels at 2x automatically (crisp on Retina).
let W: CGFloat = 740
let H: CGFloat = 580

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)
else {
    FileHandle.standardError.write(Data("cannot allocate bitmap\n".utf8))
    exit(1)
}
rep.size = NSSize(width: W, height: H)

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

// White background (point coordinates, origin bottom-left).
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

// Subtle drag arrow between the icon slots. The icon row sits at
// Finder y=175 (top-left origin) → point y = H - 175.
let arrowY = H - 175
let arrow = NSBezierPath()
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 320, y: arrowY))
arrow.line(to: NSPoint(x: 425, y: arrowY))
arrow.move(to: NSPoint(x: 407, y: arrowY + 13))
arrow.line(to: NSPoint(x: 425, y: arrowY))
arrow.line(to: NSPoint(x: 407, y: arrowY - 13))
NSColor(white: 0, alpha: 0.32).setStroke()
arrow.stroke()

// Paint the Applications folder icon into the background, exactly
// under the "Applications" symlink slot (Finder {495,175}). macOS 26
// fails to render a symlink's resolved icon inside DMG windows, so we
// bake the icon here; the (icon-less) symlink still sits on top as
// the live drop target and supplies the "Applications" text label.
let appsIcon = NSWorkspace.shared.icon(forFile: "/Applications")
let iconSize: CGFloat = 112
appsIcon.draw(in: NSRect(x: 495 - iconSize / 2,
                         y: (H - 175) - iconSize / 2,
                         width: iconSize, height: iconSize),
              from: NSRect(origin: .zero, size: appsIcon.size),
              operation: .sourceOver, fraction: 1.0)

// Conterm text-logo near the bottom, horizontally centered. The
// source artwork is white; we tint it black for the white canvas by
// rendering it through itself as an alpha mask.
if let logo = NSImage(contentsOfFile: logoPath), logo.size.width > 0 {
    let full = NSRect(origin: .zero, size: logo.size)
    let blackLogo = NSImage(size: logo.size)
    blackLogo.lockFocus()
    logo.draw(in: full, from: full, operation: .sourceOver, fraction: 1.0)
    NSColor.black.setFill()
    full.fill(using: .sourceIn)  // recolor opaque pixels, keep alpha
    blackLogo.unlockFocus()

    let logoW: CGFloat = 250
    let logoH = logoW * logo.size.height / logo.size.width
    blackLogo.draw(in: NSRect(x: (W - logoW) / 2, y: 42,
                              width: logoW, height: logoH),
                   from: full, operation: .sourceOver, fraction: 1.0)
} else {
    FileHandle.standardError.write(
        Data("warning: could not load logo \(logoPath)\n".utf8))
}

NSGraphicsContext.restoreGraphicsState()

guard let tiff = rep.representation(using: .tiff, properties: [:]) else {
    FileHandle.standardError.write(Data("cannot encode TIFF\n".utf8))
    exit(1)
}
do {
    try tiff.write(to: URL(fileURLWithPath: outPath))
    print("OK: \(outPath) (\(Int(W))x\(Int(H)) @2x)")
} catch {
    FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
    exit(1)
}
