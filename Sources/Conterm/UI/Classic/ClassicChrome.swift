import SwiftUI

// Classic interface style: chrome shared by the Classic palette and the
// Classic Orbit panels.

/// Shared chrome for the palette's floating glass bubbles: panel
/// background, clip, border, liquid-glass top-edge highlight, drop
/// shadow. `darken` lays an extra wash over the glass so the input
/// bar reads heavier than the results panel.
struct PaletteBubble: ViewModifier {
    let cornerRadius: CGFloat
    var darken: Double = 0
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        // "Light" tracks the light-glass tint (the app's actual light mode),
        // falling back to the system scheme.
        let light = prefs.lightGlass || scheme == .light
        // No darkening in light mode, only a whisper in dark, so the input
        // bar and results panel read as one cohesive surface — separated by
        // the gap + border, not a tone shift.
        let wash = light ? 0 : darken * 0.3
        return content
            .background(
                ZStack {
                    // `Glass panels` on → real frosted Liquid Glass. Off
                    // (default) → a solid black panel: an opaque sheet that
                    // doesn't sample the terminal behind it. `darken` sinks
                    // the input bar a touch below the results either way.
                    if prefs.liquidGlassPanels, #available(macOS 26, *) {
                        PaneLiquidGlass(cornerRadius: cornerRadius,
                                        frostiness: 0.85,
                                        light: prefs.lightGlass)
                    } else {
                        Theme.panelBed
                    }
                    if wash > 0 { Color.black.opacity(wash) }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.strokeStrong,
                                  lineWidth: light ? 1.25 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.32), .clear],
                            startPoint: .top, endPoint: .center
                        ),
                        lineWidth: 1
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.45), radius: 30, x: 0, y: 12)
    }
}
