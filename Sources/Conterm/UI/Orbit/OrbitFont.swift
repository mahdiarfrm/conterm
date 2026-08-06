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

    /// The first candidate this machine actually has.
    static func resolvedName(_ size: CGFloat) -> String? {
        register()
        return candidates.first { NSFont(name: $0, size: size) != nil }
    }

    /// Whether the resolved face is the fallback, which has only one weight and
    /// therefore needs `OrbitText` to thicken it. A licensed Eurostile Bold
    /// Extended is already bold and must be left alone.
    static var needsSynthesisedWeight: Bool {
        resolvedName(12).map { $0.hasPrefix("Michroma") } ?? false
    }

    /// Rendered width of a string in this face. These faces are far wider than
    /// the system one at the same size, so estimating from the system metrics
    /// clipped every kind tag.
    static func width(_ s: String, size: CGFloat) -> CGFloat {
        guard let name = resolvedName(size), let f = NSFont(name: name, size: size) else {
            return ceil(TabPill.textWidth(s, size: size) * 1.4)
        }
        return ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }

    /// The face at an arbitrary size. Falls back to a wide heavy system face
    /// when neither the licensed nor the bundled one is present.
    static func face(_ size: CGFloat) -> Font {
        guard let name = resolvedName(size) else {
            return .system(size: size - 1, weight: .black, design: .rounded).width(.expanded)
        }
        return .custom(name, size: size)
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
        ZStack(alignment: .leading) {
            if OrbitFont.needsSynthesisedWeight {
                base.offset(x: weight)
                base.offset(y: weight)
                base.offset(x: weight, y: weight)
            }
            base
        }
        .fixedSize()
    }
}
