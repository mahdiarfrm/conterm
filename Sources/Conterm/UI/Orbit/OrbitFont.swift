import AppKit
import CoreText
import SwiftUI

/// Orbit's own typeface: a wide square grotesque, used for the wordmark and for
/// the small identifying marks on its chrome.
///
/// Eurostile is the face the mode was designed around, and it is licensed —
/// Monotype's, whatever a download site offers — so the app does not carry it.
/// It is used when the machine has it. Otherwise the bundled fallback is
/// Michroma, SIL OFL, which is the closest free face to Eurostile Extended:
/// same wide proportions, same squared counters. Its licence ships beside it,
/// as the OFL requires.
@MainActor
enum OrbitFont {
    /// Tried in order: what you may have licensed, then what is bundled.
    static let candidates = [
        "EurostileBQ-BoldExtended", "Eurostile Bold Extended", "Eurostile BQ",
        "Michroma-Regular", "Michroma",
    ]

    static var registered = false
    static func register() {
        guard !registered else { return }
        registered = true
        guard let url = Bundle.main.url(forResource: "michroma-regular", withExtension: "ttf")
        else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// Which candidate this machine has, resolved once.
    ///
    /// Cached because the answer cannot change after registration and the cost
    /// of asking is not small: a miss is a full font-table lookup, and every
    /// card on the canvas asks — for its width, and once per layer of
    /// `OrbitText`. Uncached, a thirty-node map spent hundreds of font lookups
    /// per frame and the map locked up for seconds at a time.
    nonisolated(unsafe) private static var nameCache: String??
    static func resolvedName(_ size: CGFloat) -> String? {
        if let cached = nameCache { return cached }
        register()
        // Size is irrelevant to *which* face exists, so one lookup answers for
        // every size the chrome asks about.
        let found = candidates.first { NSFont(name: $0, size: 12) != nil }
        nameCache = .some(found)
        return found
    }

    /// Whether the resolved face is the fallback, which has only one weight and
    /// therefore needs `OrbitText` to thicken it. A licensed Eurostile Bold
    /// Extended is already bold and must be left alone.
    static var needsSynthesisedWeight: Bool {
        resolvedName(12).map { $0.hasPrefix("Michroma") } ?? false
    }

    /// The `NSFont` at one size, kept — building one is cheap only the first
    /// time, and `width` is called once per card per layout pass.
    nonisolated(unsafe) private static var sized: [CGFloat: NSFont] = [:]
    private static func nsFont(_ size: CGFloat) -> NSFont? {
        if let f = sized[size] { return f }
        guard let name = resolvedName(size), let f = NSFont(name: name, size: size)
        else { return nil }
        sized[size] = f
        return f
    }

    /// Rendered width of a string in this face. These faces are far wider than
    /// the system one at the same size, so estimating from the system metrics
    /// clipped every kind tag.
    static func width(_ s: String, size: CGFloat) -> CGFloat {
        guard let f = nsFont(size) else {
            return ceil(TabPill.textWidth(s, size: size) * 1.4)
        }
        return ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }

    /// The face at an arbitrary size. Falls back to a wide heavy system face
    /// when neither the licensed nor the bundled one is present.
    nonisolated(unsafe) private static var faces: [CGFloat: Font] = [:]
    static func face(_ size: CGFloat) -> Font {
        if let f = faces[size] { return f }
        let font: Font
        if let name = resolvedName(size) { font = .custom(name, size: size) }
        else { font = .system(size: size - 1, weight: .black, design: .rounded).width(.expanded) }
        faces[size] = font
        return font
    }
}

/// Text in the mode's face, thickened.
///
/// Michroma ships one weight and nothing will synthesise a heavier cut of it:
/// `NSFontManager.convert(toHaveTrait: .boldFontMask)` hands back the same
/// font, and a stroke attribute doesn't survive into SwiftUI's `Text`. Drawing
/// the glyphs again a fraction off thickens the stroke without touching the
/// metrics — which is what a display face needs at the sizes this chrome uses,
/// where a single pass reads thin next to the system UI beside it.
///
/// A licensed Eurostile Bold Extended is already bold, so it is drawn once.
struct OrbitText: View {
    let text: String
    var size: CGFloat
    var tracking: CGFloat = 0
    /// How far the extra passes sit from the first, in points. Beyond about
    /// half a point the letterforms start to smear rather than thicken.
    var weight: CGFloat = 0.34

    var body: some View {
        let base = Text(text).font(OrbitFont.face(size)).tracking(tracking)
        // One extra pass on the diagonal, not three. Each is a full text layout
        // and there is one of these on every card — three of them cost four
        // times the glyph work for a difference nobody can see.
        ZStack(alignment: .leading) {
            if OrbitFont.needsSynthesisedWeight { base.offset(x: weight, y: weight) }
            base
        }
        .fixedSize()
    }
}
