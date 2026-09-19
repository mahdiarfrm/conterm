import AppKit
import CoreText
import SwiftUI

/// The app icon reduced to one colour: the glass tile as an outline with
/// its `~` inside, and the four shapes it sits over — capsule, small disc,
/// large disc, triangle — solid where they show past it. A clear moat
/// stands in for the glass's edge, keeping the shapes off the tile. A
/// `Shape`, so it takes any fill and stays sharp at every size; the tile's
/// line and the `~` are heavier than the icon's so the mark still reads at
/// eyebrow size.
struct ContermGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        // Drawn in a 100-unit square, then fitted to `rect`.
        let tileFrame = CGRect(x: 19, y: 18, width: 62, height: 62)
        let tile = Path(roundedRect: tileFrame, cornerRadius: 20, style: .continuous)
        let bore = Path(roundedRect: tileFrame.insetBy(dx: 6, dy: 6),
                        cornerRadius: 14.5, style: .continuous)
        let moat = Path(roundedRect: tileFrame.insetBy(dx: -5, dy: -5),
                        cornerRadius: 24.5, style: .continuous)

        var behind = Path()
        behind.addRoundedRect(in: CGRect(x: 48, y: 0, width: 52, height: 31),
                              cornerSize: CGSize(width: 15.5, height: 15.5))
        behind.addEllipse(in: CGRect(x: 7, y: 8, width: 24, height: 24))
        behind.addEllipse(in: CGRect(x: 0, y: 62, width: 38, height: 38))
        behind.move(to: CGPoint(x: 77, y: 52))
        behind.addLine(to: CGPoint(x: 100, y: 94))
        behind.addLine(to: CGPoint(x: 54, y: 94))
        behind.closeSubpath()

        var mark = tile.subtracting(bore)
        mark.addPath(behind.subtracting(moat))
        mark.addPath(Self.tilde(width: 29, centeredAt: CGPoint(x: tileFrame.midX,
                                                              y: tileFrame.midY)))

        let side = min(rect.width, rect.height)
        let fit = CGAffineTransform(translationX: rect.midX - side / 2,
                                    y: rect.midY - side / 2)
            .scaledBy(x: side / 100, y: side / 100)
        return mark.applying(fit)
    }

    /// The system face's `~` as an outline, `width` units wide.
    private static func tilde(width: CGFloat, centeredAt center: CGPoint) -> Path {
        let font = NSFont.systemFont(ofSize: 100, weight: .bold) as CTFont
        var character: UniChar = 0x7E
        var glyph = CGGlyph()
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1),
              let outline = CTFontCreatePathForGlyph(font, glyph, nil) else { return Path() }
        let box = outline.boundingBoxOfPath
        guard box.width > 0 else { return Path() }
        let scale = width / box.width
        // Glyph outlines are y-up; the shape's space is y-down.
        let place = CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: scale, y: -scale)
            .translatedBy(x: -box.midX, y: -box.midY)
        return Path(outline).applying(place)
    }
}
