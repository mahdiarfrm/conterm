import AppKit
import CoreText
import SwiftUI

/// Registers the bundled Eurostile Bold Extended once for the process so the
/// Orbit wordmark can use it. No-op if the resource is absent.
@MainActor
enum OrbitFont {
    static var registered = false
    static func register() {
        guard !registered else { return }
        registered = true
        guard let url = Bundle.main.url(forResource: "eurostile-bold-extended", withExtension: "otf")
        else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// Rendered width of a string in this face. Eurostile Bold Extended is far
    /// wider than the system face at the same size, so estimating from the
    /// system metrics clipped every kind tag.
    static func width(_ s: String, size: CGFloat) -> CGFloat {
        register()
        for name in ["EurostileBQ-BoldExtended", "Eurostile Bold Extended", "Eurostile BQ"] {
            if let f = NSFont(name: name, size: size) {
                return ceil((s as NSString).size(withAttributes: [.font: f]).width)
            }
        }
        return ceil(TabPill.textWidth(s, size: size) * 1.3)
    }

    /// The wordmark face at an arbitrary size — the mode's own typeface, used
    /// for its chrome as well as the title. Falls back to a wide heavy system
    /// face when the bundled font is unavailable.
    static func face(_ size: CGFloat) -> Font {
        register()
        for name in ["EurostileBQ-BoldExtended", "Eurostile Bold Extended", "Eurostile BQ"]
        where NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size - 1, weight: .heavy, design: .rounded).width(.expanded)
    }
}
