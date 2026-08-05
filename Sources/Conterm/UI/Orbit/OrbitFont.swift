import AppKit
import CoreText
import SwiftUI

/// Orbit's own typeface: a wide square grotesque, used for the wordmark and for
/// the small identifying marks on its chrome.
///
/// Eurostile is the face the mode was designed around, and it is licensed —
/// Monotype's, whatever a download site offers — so the app does not carry it.
/// It is used when the machine has it, and otherwise the bundled fallback is
/// Michroma, which is SIL OFL and close enough in proportion to keep the design
/// intact. Its licence ships beside it, as the OFL requires.
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
    static func resolved(_ size: CGFloat) -> String? {
        register()
        return candidates.first { NSFont(name: $0, size: size) != nil }
    }

    /// Rendered width of a string in this face. These faces are far wider than
    /// the system one at the same size, so estimating from the system metrics
    /// clipped every kind tag.
    static func width(_ s: String, size: CGFloat) -> CGFloat {
        if let name = resolved(size), let f = NSFont(name: name, size: size) {
            return ceil((s as NSString).size(withAttributes: [.font: f]).width)
        }
        return ceil(TabPill.textWidth(s, size: size) * 1.3)
    }

    /// The wordmark face at an arbitrary size. Falls back to a wide heavy
    /// system face when neither the licensed nor the bundled one is present.
    static func face(_ size: CGFloat) -> Font {
        if let name = resolved(size) { return .custom(name, size: size) }
        return .system(size: size - 1, weight: .heavy, design: .rounded).width(.expanded)
    }
}
