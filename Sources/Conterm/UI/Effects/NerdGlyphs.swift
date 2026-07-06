import AppKit
import SwiftUI

/// Distro marks from the Font Logos block (U+F300…) of an installed
/// Nerd Font. Resolution is best-effort — scan the installed families
/// once for one that actually carries the block — and callers keep
/// their own fallback mark for machines without any Nerd Font.
@MainActor
enum NerdGlyphs {
    /// Substring of an os-release PRETTY_NAME (lowercased) → Font Logos
    /// codepoint, per nerd-fonts glyphnames.json.
    private static let distros: [(key: String, scalar: UInt32)] = [
        ("ubuntu",    0xF31B),
        ("debian",    0xF306),
        ("fedora",    0xF30A),
        ("arch",      0xF303),
        ("alpine",    0xF300),
        ("centos",    0xF304),
        ("rocky",     0xF32B),
        ("alma",      0xF31D),
        ("red hat",   0xF316),
        ("rhel",      0xF316),
        ("suse",      0xF314),
        ("manjaro",   0xF312),
        ("nixos",     0xF313),
        ("kali",      0xF327),
        ("void",      0xF32E),
        ("raspberry", 0xF315),
        ("gentoo",    0xF30D),
        ("linux",     0xF31A),   // tux — generic fallback, keep last
    ]

    /// Distro mark for an OS name as a normalized vector path, or nil
    /// when the OS is unknown or no Nerd Font is installed. The glyph's
    /// outline is extracted and refit by the caller's frame — Nerd Font
    /// symbol metrics (baseline, advance, cell padding) vary wildly
    /// between patched fonts, so rendering the raw character never
    /// sits right in UI text.
    static func distroPath(for os: String) -> Path? {
        guard let fontName = nerdFontName(),
              let match = distros.first(where: { os.contains($0.key) }),
              let scalar = UnicodeScalar(match.scalar) else { return nil }
        let ct = CTFontCreateWithName(fontName as CFString, 64, nil)
        var chars = Array(String(Character(scalar)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(ct, &chars, &glyphs, chars.count),
              glyphs[0] != 0,
              let cgPath = CTFontCreatePathForGlyph(ct, glyphs[0], nil)
        else { return nil }
        return Path(cgPath)
    }

    // Double optional: nil = not yet resolved, .some(nil) = no Nerd
    // Font installed (also cached, so the family scan runs once).
    private static var resolved: String??

    private static func nerdFontName() -> String? {
        if let r = resolved { return r }
        // The dedicated symbols font first, then anything self-labeled
        // as a Nerd Font, then the "NF"-suffixed short names.
        let families = NSFontManager.shared.availableFontFamilies
        let candidates = ["Symbols Nerd Font Mono", "Symbols Nerd Font"]
            + families.filter { $0.contains("Nerd Font") || $0.hasSuffix(" NF") }
        let probe = Character(UnicodeScalar(0xF31B)!)
        for name in candidates {
            if let font = NSFont(name: name, size: 12), hasGlyph(font, probe) {
                resolved = .some(name)
                return name
            }
        }
        resolved = .some(nil)
        return nil
    }

    private static func hasGlyph(_ font: NSFont, _ ch: Character) -> Bool {
        var chars = Array(String(ch).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, &chars, &glyphs,
                                            chars.count) && glyphs[0] != 0
    }
}

/// Scales and centers a glyph outline into whatever frame it's given,
/// flipping from font space (y-up) into view space.
struct FittedGlyph: Shape {
    let base: Path

    nonisolated func path(in rect: CGRect) -> Path {
        let b = base.boundingRect
        guard b.width > 0, b.height > 0 else { return Path() }
        let scale = min(rect.width / b.width, rect.height / b.height)
        var t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
        t = t.scaledBy(x: scale, y: -scale)
        t = t.translatedBy(x: -b.midX, y: -b.midY)
        return base.applying(t)
    }
}
