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
            // Only mount the layer(s) actually needed. Each NSGlassEffectView
            // is a live material that composites continuously, so a fully
            // transparent second layer still burns GPU. At the default clear
            // setting only `.clear` mounts — half the glass cost.
            ZStack {
                if glassiness < 0.999 {
                    NativeClear(tintColor: clearTint)
                        .opacity(1.0 - glassiness)
                }
                if glassiness > 0.001 {
                    NativeRegular(tintColor: regularTint)
                        .opacity(glassiness)
                }
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

// MARK: - Frosted Liquid Glass panel (live overlay glass)

/// Real macOS 26 Liquid Glass surface for overlay panels — a frosted,
/// refractive `.regular` `NSGlassEffectView` with a tint so the panel reads
/// as a distinct glass card. Used only when `Glass panels` is on; it
/// re-lenses the terminal behind the open panel every frame, so it's opt-in.
struct PaneLiquidGlass: NSViewRepresentable {
    let cornerRadius: CGFloat
    /// 0 = clear, 1 = heaviest frost the tint applies.
    var frostiness: Double = 0.8
    /// Follow the chrome's dark/light tint.
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

// MARK: - Overlay panel backdrop (modal panels over the terminal)

/// Backdrop for floating overlay panels (Settings, Search, Notifications,
/// Rename, GroupRename, floating sidebar card).
///
/// `Glass panels` off (default): a solid card — cheaper, since these panels
/// cover the streaming terminal, the one place live glass re-lenses every
/// frame. On: real frosted Liquid Glass (macOS 26+).
struct OverlayPanelBackground: View {
    let cornerRadius: CGFloat
    /// Frost density for the live-glass variant.
    var frostiness: Double = 0.8

    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        if prefs.liquidGlassPanels, #available(macOS 26, *) {
            PaneLiquidGlass(cornerRadius: cornerRadius,
                            frostiness: frostiness,
                            light: prefs.lightGlass)
        } else {
            (prefs.lightGlass
                ? Color(red: 0.96, green: 0.97, blue: 0.98)
                : Color(red: 0.05, green: 0.05, blue: 0.06))
        }
    }
}

// MARK: - Chrome capsules (flat lenses on the glass sheet)

// Every chrome control — tab pills, action clusters, pane badges, the
// agent-pill bed — is a flat translucent fill, NEVER `NSGlassEffectView` /
// `.glassEffect`. The window already carries one sheet of real Liquid Glass
// (`LiquidGlassBackdrop`); a second glass view nested inside it both pays a
// per-frame re-lens AND draws the black-line artifacts AppKit produces when
// glass stacks on glass. A flat tint instead reads as a lens *on* the sheet:
// over the top bar the desktop shows through it, over a pane it's a clean
// dark capsule — and it costs nothing per frame.

/// Translucent capsule/rect fill for a chrome control. `selected` lifts it
/// a touch so an active control reads as more present without changing the
/// material.
@MainActor
func chromeFill(_ prefs: Preferences, selected: Bool = false) -> Color {
    if prefs.lightGlass {
        return Color.white.opacity(selected ? 0.58 : 0.40)
    }
    return Color.black.opacity(selected ? 0.32 : 0.20)
}

/// Hairline top-edge highlight for a chrome capsule — the "wet" light that
/// catches the rim. Used with `.blendMode(.plusLighter)` so it only ever
/// brightens.
@MainActor
func chromeEdge(_ prefs: Preferences) -> [Color] {
    prefs.lightGlass
        ? [Color.white.opacity(0.85), Color.white.opacity(0.20)]
        : [Color.white.opacity(0.30), Color.white.opacity(0.06)]
}

extension View {
    /// Wrap a pill/capsule control in the flat chrome capsule.
    func glassPill() -> some View {
        modifier(GlassPillModifier())
    }

    /// Conditionally wrap in a glass pill — when `enabled` is false the
    /// view is returned bare (used by the unified toolbar bar, which
    /// supplies a single shared surface instead of one per icon).
    @ViewBuilder
    func glassPill(enabled: Bool) -> some View {
        if enabled { glassPill() } else { self }
    }
}

private struct GlassPillModifier: ViewModifier {
    @EnvironmentObject private var prefs: Preferences

    func body(content: Content) -> some View {
        content
            .background(Capsule(style: .continuous).fill(chromeFill(prefs)))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: chromeEdge(prefs),
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
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
