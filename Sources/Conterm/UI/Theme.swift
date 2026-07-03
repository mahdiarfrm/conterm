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

    // Palette — neutral, low-saturation.

    /// Opaque backing for a terminal pane. Each pane is a solid tile laid
    /// on the window glass sheet — opaque so the glass shows only in the
    /// top bar + gaps, and so the streaming region never blends against the
    /// desktop. Near-black to frame the terminal cells at the rounded edge.
    static let paneTile      = Color(red: 0.05, green: 0.055, blue: 0.075)

    /// Solid bed for the pane-floating chips (the dir/title pill, the
    /// command-result badge). Opaque so they read as solid chips over the
    /// terminal, a step lighter than `paneTile` for separation.
    static let paneTitleBar  = Color(red: 0.12, green: 0.13, blue: 0.16)

    /// Bed for the title pill while the pane is SSH'd. Same lightness as
    /// `paneTitleBar` but pushed cool/blue so a remote pane reads as
    /// remote at a glance, with no per-frame cost.
    static let paneRemoteBar = Color(red: 0.07, green: 0.13, blue: 0.20)

    /// SSH cyan, on the dark pill bed — the remote-state hue for the
    /// glyph glow, border, and connect sweep.
    static let sshAccent     = Color(red: 0.45, green: 0.85, blue: 1.0)
    /// SSH blue for the collapsed (light) pill, where the bright cyan
    /// would wash out against white.
    static let sshAccentDeep = Color(red: 0.10, green: 0.50, blue: 0.95)

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

    /// Non-adaptive accent for chrome that floats over the dark terminal
    /// in BOTH appearances (pane title pill, suggestion strip). The
    /// regular `accent` flips near-black in light mode and would vanish
    /// against the dark bed — this stays the cool near-white.
    static let accentOnDark  = Color(red: 0.92, green: 0.96, blue: 1.00)
    static let warning       = Color(red: 1.00, green: 0.80, blue: 0.55)

    static let textPrimary   = dynamic(
        light: NSColor(white: 0.0, alpha: 0.88),
        dark:  NSColor(white: 1.0, alpha: 0.96))
    static let textSecondary = dynamic(
        light: NSColor(white: 0.0, alpha: 0.55),
        dark:  NSColor(white: 1.0, alpha: 0.55))

    static let stroke        = dynamic(
        light: NSColor(white: 0.0, alpha: 0.10),
        dark:  NSColor(white: 1.0, alpha: 0.08))
    static let strokeStrong  = dynamic(
        light: NSColor(white: 0.0, alpha: 0.16),
        dark:  NSColor(white: 1.0, alpha: 0.18))

    /// Opaque bed for floating chrome (command palette, overlays) when
    /// Liquid Glass is off — a clean near-white on light (kept bright so a
    /// darkening wash on top doesn't turn it muddy grey), near-black on dark.
    static let panelBed      = dynamic(
        light: NSColor(calibratedRed: 0.975, green: 0.978, blue: 0.985, alpha: 1.0),
        dark:  NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.05, alpha: 1.0))
    /// Opaque bed for a small raised chip (suggestion circle). Near-black
    /// on dark to match the panels and the agent pill — the hairline rim
    /// defines the disc — and near-white on light. Opaque so it neither
    /// samples the backdrop nor needs a shadow.
    static let chipBed       = dynamic(
        light: NSColor(calibratedWhite: 0.88, alpha: 1.0),
        dark:  NSColor(calibratedRed: 0.05, green: 0.055, blue: 0.07, alpha: 1.0))
    /// Opaque bed for a vertical-sidebar tab pill. The sidebar is a wide
    /// expanse where translucent pills over the desktop read as noise, so
    /// the pill goes opaque — near-white on light, the chrome grey on dark.
    static let tabBed        = dynamic(
        light: NSColor(calibratedWhite: 0.97, alpha: 1.0),
        dark:  NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 1.0))
    /// Focused/hover row wash. Preserves the dark-mode value (white 0.08)
    /// and gives a matching dark wash in light mode.
    static let selectionFill = dynamic(
        light: NSColor(white: 0.0, alpha: 0.06),
        dark:  NSColor(white: 1.0, alpha: 0.08))
    /// Translucent recessed wash for a heavier chrome bar (the system-stats
    /// widget, the layout switcher) — a dark veil that sinks the bar a step
    /// below the glass around it. Lighter in light mode so it reads as a
    /// subtle recess instead of a muddy black slab.
    static let recessedWash  = dynamic(
        light: NSColor(white: 0.0, alpha: 0.06),
        dark:  NSColor(white: 0.0, alpha: 0.18))

    // Geometry tokens shared across the chrome.
    static let windowCorner:    CGFloat = 18
    static let paneCorner:      CGFloat = 12
    // Near-capsule on a ~28 pt tab pill; corners read round, not boxy.
    static let pillCorner:      CGFloat = 14
    static let tabBarHeight:    CGFloat = 38

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
