import AppKit
import SwiftUI

/// Real liquid-glass backdrop.
///
/// Design intent vs. the legacy backdrop:
/// - Blur is **always on** at a constant material strength — the
///   `glassiness` slider no longer cross-fades a dark panel's opacity
///   (which read as "brighter ⟷ darker", not a glass change).
/// - The slider drives the **actual CGS background-blur radius** at the
///   window level (see `WindowController`), a tangible clear⟷frosted
///   change. This view supplies the material + glass refraction on top.
/// - **Reduce Transparency** (Accessibility, or Low Power Mode) makes
///   macOS render every vibrancy material flat-opaque with zero blur —
///   no app can blur in that mode. We detect it and degrade to a
///   deliberately solid, tastefully tinted surface so it looks
///   intentional instead of "the slider just changes opacity".
struct LiquidGlassBackdrop: View {
    /// 0 ≈ clear glass, 1 ≈ heavy frost. Used here for the subtle
    /// frost tint + (in the reduced-transparency fallback) the solid
    /// surface opacity.
    var glassiness: Double
    /// Dark vs light "mode" — expressed purely as the glass TINT
    /// (dark near-black vs light near-white). The glass stays clear/
    /// refractive either way; the slider still controls frost.
    var light: Bool = false

    @StateObject private var a11y = ReduceTransparencyObserver()

    var body: some View {
        Group {
            if a11y.reduced {
                reducedFallback
            } else if #available(macOS 26, *) {
                // True Apple Liquid Glass (the real system material with
                // dynamic lensing + specular highlights). macOS 26+ only.
                RealLiquidGlass(glassiness: glassiness, light: light)
            } else {
                // macOS 14–15: classic vibrancy approximation.
                legacyVibrancyGlass
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.25), value: a11y.reduced)
    }

    // MARK: - Vibrancy approximation (macOS 14–15 fallback)

    private var legacyVibrancyGlass: some View {
        ZStack {
            // Always-on genuine vibrancy. The actual blur RADIUS is
            // controlled at the window level (CGS) by the slider; this
            // is the material/tint that rides on top of it.
            GlassBackground(material: .hudWindow,
                            blending: .behindWindow,
                            state: .followsWindowActiveState)

            // Faint extra frost as the slider moves toward "frosted",
            // layered on the always-present blur (never replaces it).
            Color.white
                .opacity(0.05 + glassiness * 0.10)
                .blendMode(.plusLighter)

            glassRefraction
        }
    }

    /// The bits that make a blurred surface read as *glass* rather than
    /// flat frost: a crisp specular top edge, a soft diagonal sheen,
    /// and a subtle bottom inner-shadow for depth.
    private var glassRefraction: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.40),
                        Color.white.opacity(0.10),
                        Color.clear,
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 28)
                .blendMode(.plusLighter)
                Spacer(minLength: 0)
            }
            LinearGradient(
                colors: [Color.white.opacity(0.10), Color.clear],
                startPoint: .topLeading, endPoint: .center
            )
            .blendMode(.plusLighter)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.12)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 54)
                .blendMode(.multiply)
            }
        }
    }

    // MARK: - Reduced-transparency fallback (no blur possible)

    /// macOS gives us no blur here, so we don't pretend. A clean,
    /// slightly-tinted solid whose density tracks the slider, plus the
    /// same edge highlight so it still looks like a designed surface.
    private var reducedFallback: some View {
        ZStack {
            Color(red: 0.09, green: 0.10, blue: 0.13)
                .opacity(0.72 + glassiness * 0.22)
            LinearGradient(
                colors: [Color.white.opacity(0.10), Color.clear],
                startPoint: .top, endPoint: .center
            )
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - True Apple Liquid Glass (macOS 26+)

/// Real macOS 26 Liquid Glass for the window backdrop.
///
/// `NSGlassEffectView` exposes only two clarity styles — `.clear` (most
/// see-through) and `.regular` (standard frosted) — and no blur-radius
/// knob in between. To turn the Chrome glass slider into a real
/// clarity control instead of just a tint, this view layers BOTH
/// styles as siblings (each samples the same parent backdrop) and
/// crossfades them by opacity:
///   • slider 0  → only `.clear` visible (desktop reads through)
///   • slider 1  → only `.regular` visible (frosted; tinted dark or light)
///   • mid       → smooth blend of the two
/// Dark vs Light flips the tint colour on both layers so the toggle
/// is visible regardless of slider position.
private struct RealLiquidGlass: View {
    var glassiness: Double
    var light: Bool = false

    var body: some View {
        if #available(macOS 26, *) {
            ZStack {
                NativeClear(tintColor: clearTint)
                    .opacity(1.0 - glassiness)
                NativeRegular(tintColor: regularTint)
                    .opacity(glassiness)
            }
        } else {
            Color.clear
        }
    }

    /// Light tint on the `.clear` (transparent-end) glass — small
    /// floor so the Dark/Light toggle stays visible even when the
    /// Chrome slider sits at Clear. Modest so see-through-ness wins.
    @available(macOS 26, *)
    private var clearTint: NSColor {
        light
            ? NSColor(calibratedRed: 0.90, green: 0.92, blue: 0.96, alpha: 0.12)
            : NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 0.06)
    }

    /// Heavier tint on the `.regular` (frosted-end) glass.
    @available(macOS 26, *)
    private var regularTint: NSColor {
        light
            ? NSColor(calibratedRed: 0.90, green: 0.92, blue: 0.96, alpha: 0.28)
            : NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 0.14)
    }

    @available(macOS 26, *)
    private struct NativeClear: NSViewRepresentable {
        var tintColor: NSColor

        func makeNSView(context: Context) -> NSGlassEffectView {
            let g = NSGlassEffectView()
            g.style = .clear
            // Fill the window square; the system rounds + clips the
            // whole window (and its blur) at the system corner radius.
            g.cornerRadius = 0
            g.tintColor = tintColor
            return g
        }
        func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
            nsView.tintColor = tintColor
        }
    }

    @available(macOS 26, *)
    private struct NativeRegular: NSViewRepresentable {
        var tintColor: NSColor

        func makeNSView(context: Context) -> NSGlassEffectView {
            let g = NSGlassEffectView()
            g.style = .regular
            g.cornerRadius = 0
            g.tintColor = tintColor
            return g
        }
        func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
            nsView.tintColor = tintColor
        }
    }
}

// MARK: - Frosted Liquid Glass panel (modal overlays)

/// Frosted Liquid Glass surface for modal overlay panels. Uses the
/// same AppKit `NSGlassEffectView` the window backdrop uses, but with
/// the `.regular` style (frosted) and a tint so the panel reads as a
/// distinct, legible glass card over the terminal.
struct PaneLiquidGlass: NSViewRepresentable {
    let cornerRadius: CGFloat
    /// 0 = clear, 1 = heaviest frost the tint can apply on `.regular`.
    var frostiness: Double = 0.8
    /// Follow the chrome's Glass tint setting (dark vs light).
    var light: Bool = false

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = cornerRadius
            apply(to: g)
            return g
        }
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26, *), let g = nsView as? NSGlassEffectView {
            g.cornerRadius = cornerRadius
            apply(to: g)
        }
    }

    @available(macOS 26, *)
    private func apply(to g: NSGlassEffectView) {
        g.style = .regular
        let a = 0.12 + frostiness * 0.32
        g.tintColor = light
            ? NSColor(calibratedRed: 0.90, green: 0.92, blue: 0.96, alpha: a)
            : NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: a)
    }
}

/// Backdrop for floating overlay panels (Settings, Command Palette,
/// Search, Notifications, Rename, GroupRename, floating sidebar card).
///
/// Defaults to the original `NSVisualEffectView .hudWindow` vibrancy
/// stack with a dark tint on top — the look these panels were designed
/// against. Flipping `prefs.liquidGlassPanels` routes them to a
/// frosted `.regular` Liquid Glass surface (macOS 26+) for a coherent
/// look with the rest of the chrome.
struct OverlayPanelBackground: View {
    let cornerRadius: CGFloat
    var tint: Color = Color(red: 0.08, green: 0.10, blue: 0.14).opacity(0.22)

    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        if prefs.liquidGlassPanels, !prefs.lowPowerGlass, #available(macOS 26, *) {
            // Live Liquid Glass: frosted + refractive, but `NSGlassEffectView`
            // re-lenses the terminal behind an open panel every frame.
            PaneLiquidGlass(cornerRadius: cornerRadius,
                            frostiness: 0.8,
                            light: prefs.lightGlass)
        } else if prefs.lowPowerGlass {
            // Static frosted card. No vibrancy view, so it never samples
            // (and reveals) the desktop behind the window the way a
            // `.behindWindow` material does — and costs nothing per frame.
            staticFrost
        } else {
            // Behind-window vibrancy: blurs the desktop through the window.
            ZStack {
                GlassBackground(material: .hudWindow).opacity(0.92)
                tint
            }
        }
    }

    /// Flat opaque-enough dark (or light) surface — keeps the wallpaper
    /// out and samples nothing. No sheen: a single even tone.
    private var staticFrost: some View {
        ZStack {
            (prefs.lightGlass
                ? Color(red: 0.92, green: 0.94, blue: 0.97)
                : Color(red: 0.09, green: 0.10, blue: 0.13))
                .opacity(0.93)
            tint
        }
    }
}

// MARK: - Liquid-glass pill (individual chrome controls)

extension View {
    /// Wrap a pill/capsule control in real Apple Liquid Glass on
    /// macOS 26+ (Apple auto-handles Reduce Transparency / light-dark),
    /// falling back to the prior `.ultraThinMaterial` capsule on macOS
    /// 14–15. Used for the tab pill, search, stats, and ⌘K controls so
    /// each floating control reads as liquid glass — without frosting
    /// the whole window-top band.
    func glassPill(tinted: Bool = false) -> some View {
        modifier(GlassPillModifier())
    }

    /// Glass pill that drops to a static frosted fill when `lowPower`
    /// is set. Used by chrome that floats over the live terminal (the
    /// agent pill): Apple's Liquid Glass re-lenses its backdrop on every
    /// change, so over a streaming pane it re-blurs up to 60×/s for the
    /// whole agent run. The static fill reads as the same capsule at
    /// zero per-frame cost.
    func glassPill(lowPower: Bool) -> some View {
        modifier(GlassPillModifier(lowPower: lowPower))
    }
}

/// Glass-pill capsule whose tint adapts to the current colour scheme:
/// dark tint on a dark window keeps the pill defined on bright
/// wallpapers; white tint on a light window keeps it from going inky.
private struct GlassPillModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    /// Skip Apple's live-sampling Liquid Glass and paint a static
    /// frosted capsule instead, so terminal repaints behind the pill
    /// cost nothing.
    var lowPower: Bool = false

    func body(content: Content) -> some View {
        let isLight = colorScheme == .light
        let tint = isLight ? Color.white.opacity(0.55) : Color.black.opacity(0.24)
        let edge: [Color] = isLight
            ? [Color.white.opacity(0.85), Color.white.opacity(0.20)]
            : [Color.white.opacity(0.30), Color.white.opacity(0.05)]
        let fallbackStroke = isLight
            ? Color.black.opacity(0.10)
            : Color.white.opacity(0.18)

        if lowPower {
            // Opaque enough to obscure terminal text behind the small
            // capsule without sampling it: a translucent fill is a flat
            // alpha blend, not the gaussian re-blur Liquid Glass costs.
            let frost = isLight
                ? Color.white.opacity(0.62)
                : Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.72)
            content
                .background(
                    Capsule(style: .continuous)
                        .fill(frost)
                        .overlay(
                            Capsule(style: .continuous)
                                .fill(LinearGradient(
                                    colors: [Color.white.opacity(isLight ? 0.22 : 0.12),
                                             .clear],
                                    startPoint: .top, endPoint: .center))
                                .blendMode(.plusLighter)
                        )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: edge,
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.5)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                )
        } else if #available(macOS 26, *) {
            content
                .glassEffect(.regular.tint(tint), in: .capsule)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: edge,
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.5)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                )
        } else {
            content
                .background(Capsule(style: .continuous).fill(tint))
                .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(fallbackStroke, lineWidth: 0.5)
                )
        }
    }
}

extension View {
    /// Conditionally wrap in a glass pill — when `enabled` is false the
    /// view is returned bare (used by the unified toolbar bar, which
    /// supplies a single shared glass surface instead of one per icon).
    @ViewBuilder
    func glassPill(enabled: Bool) -> some View {
        if enabled { glassPill() } else { self }
    }

    /// Same idea but for a rounded-rect control (the tab pill uses a
    /// continuous rounded rectangle, not a true capsule).
    @ViewBuilder
    func glassRoundedRect(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular,
                             in: .rect(cornerRadius: cornerRadius,
                                       style: .continuous))
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
        }
    }
}

/// Tracks `accessibilityDisplayShouldReduceTransparency` and republishes
/// when the user toggles it (or Low Power Mode flips it) so the
/// backdrop swaps live without a relaunch.
@MainActor
final class ReduceTransparencyObserver: ObservableObject {
    @Published var reduced: Bool

    private var token: NSObjectProtocol?

    init() {
        reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reduced = NSWorkspace.shared
                    .accessibilityDisplayShouldReduceTransparency
            }
        }
    }

    isolated deinit {
        if let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }
}
