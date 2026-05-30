import AppKit
import SwiftUI

/// Canonical design tokens. Spring presets are listed here once so every
/// animated transition in the app uses the same physical language.
///
/// Visual identity: **neutral liquid glass**. No saturated tints — the
/// accent is a near-white cyan that disappears into the vibrancy rather
/// than tinting it. Surfaces are translucent whites/blacks; the system
/// material does the heavy lifting.
enum Theme {
    /// A color that resolves differently in light vs dark appearance.
    /// The window's appearance follows the Glass tint (see AppView), so
    /// these flip text/accent to stay legible on light-tinted glass.
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? dark : light
        })
    }

    // Palette — neutral, low-saturation. Lets whatever is behind the
    // window show through cleanly.
    static let bg            = Color.black.opacity(0.32)
    static let bgElevated    = Color.white.opacity(0.06)
    static let surfaceTint   = Color.white.opacity(0.03)

    /// Accent: near-white cool on dark glass, near-black cool on light
    /// glass. Stays neutral (not a saturated blue) so it doesn't tint
    /// the whole UI in light mode.
    static let accent        = dynamic(
        light: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1.0),
        dark:  NSColor(calibratedRed: 0.92, green: 0.96, blue: 1.00, alpha: 1.0))
    static let accentSoft    = dynamic(
        light: NSColor(white: 0.0, alpha: 0.10),
        dark:  NSColor(white: 1.0, alpha: 0.14))
    static let highlight     = Color(red: 0.85, green: 0.95, blue: 1.00)
    static let warning       = Color(red: 1.00, green: 0.80, blue: 0.55)

    static let textPrimary   = dynamic(
        light: NSColor(white: 0.0, alpha: 0.88),
        dark:  NSColor(white: 1.0, alpha: 0.96))
    static let textSecondary = dynamic(
        light: NSColor(white: 0.0, alpha: 0.55),
        dark:  NSColor(white: 1.0, alpha: 0.55))

    static let stroke        = Color.white.opacity(0.08)
    static let strokeStrong  = Color.white.opacity(0.18)

    /// A neutral, very faint white glow under the focused pane. Reads as
    /// "this is active" without coloring it.
    static let focusGlow     = Color.white.opacity(0.20)

    // Geometry tokens shared across the chrome.
    static let windowCorner:    CGFloat = 18
    static let paneCorner:      CGFloat = 12
    static let pillCorner:      CGFloat = 10
    static let tabBarHeight:    CGFloat = 38
    static let tabSidebarWidth: CGFloat = 138

    // Springs — three flavors that get reused everywhere.
    enum Spring {
        static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.85)
        static let soft   = Animation.spring(response: 0.45, dampingFraction: 0.78)
        static let bouncy = Animation.spring(response: 0.50, dampingFraction: 0.62)
        /// Shorter, slightly damped — used for split / tab adds
        /// where a long animation feels laggy because the whole
        /// SwiftUI tree rebuilds (via `.id()`) underneath.
        static let crisp  = Animation.spring(response: 0.22, dampingFraction: 0.88)
    }
}
