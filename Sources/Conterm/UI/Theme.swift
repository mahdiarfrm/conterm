import SwiftUI

/// Canonical design tokens. Spring presets are listed here once so every
/// animated transition in the app uses the same physical language.
///
/// Visual identity: **neutral liquid glass**. No saturated tints — the
/// accent is a near-white cyan that disappears into the vibrancy rather
/// than tinting it. Surfaces are translucent whites/blacks; the system
/// material does the heavy lifting.
enum Theme {
    // Palette — neutral, low-saturation. Lets whatever is behind the
    // window show through cleanly.
    static let bg            = Color.black.opacity(0.32)
    static let bgElevated    = Color.white.opacity(0.06)
    static let surfaceTint   = Color.white.opacity(0.03)

    /// A near-white accent with the faintest cyan lean — reads as
    /// "highlight" without painting the whole UI a color.
    static let accent        = Color(red: 0.92, green: 0.96, blue: 1.00)
    static let accentSoft    = Color.white.opacity(0.14)
    static let highlight     = Color(red: 0.85, green: 0.95, blue: 1.00)
    static let warning       = Color(red: 1.00, green: 0.80, blue: 0.55)

    static let textPrimary   = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.55)

    static let stroke        = Color.white.opacity(0.08)
    static let strokeStrong  = Color.white.opacity(0.18)

    /// A neutral, very faint white glow under the focused pane. Reads as
    /// "this is active" without coloring it.
    static let focusGlow     = Color.white.opacity(0.20)

    // Geometry. The top bar got bumped a notch on user feedback — was
    // too compact at 32 / 11 pt.
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
