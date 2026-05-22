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

/// Bridges AppKit's `NSGlassEffectView` — the real macOS 26 Liquid
/// Glass system material (dynamic lensing, specular highlights,
/// adaptive tint) — into SwiftUI as a full-bleed backdrop.
///
/// The slider maps to Apple's two glass styles plus a tint:
///   • low  → `.clear`   (very transparent, content reads through)
///   • high → `.regular` (standard frosted glass)
/// A subtle dark tint whose alpha rises with the slider adds depth at
/// the frosted end. The window-level CGS blur radius (WindowController)
/// still rides underneath for a continuous desktop-blur ramp.
///
/// `NSViewType` is the base `NSView` so this file compiles against the
/// macOS 14 deployment target; the `NSGlassEffectView` is only ever
/// constructed/touched inside `if #available(macOS 26, *)`.
private struct RealLiquidGlass: NSViewRepresentable {
    var glassiness: Double
    var light: Bool = false

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 0          // window already clips its corners
            apply(to: g)
            return g
        }
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26, *), let g = nsView as? NSGlassEffectView {
            apply(to: g)
        }
    }

    @available(macOS 26, *)
    private func apply(to g: NSGlassEffectView) {
        // ONE fixed style — `.clear`, the most transparent. We do NOT
        // switch to `.regular`: NSGlassEffectView has only two discrete
        // styles, so flipping between them mid-slider produced a hard
        // "clear → suddenly dark" jump. Instead the whole clear↔frosted
        // range is driven CONTINUOUSLY by (a) the tint alpha here and
        // (b) the window CGS blur radius (WindowController), so the
        // slider ramps smoothly end to end.
        g.style = .clear
        // Smooth linear tint ramp: ~transparent at 0 → noticeably
        // frosted/dense at 1. Dark mode tints toward cool near-black;
        // light mode toward cool near-white. The glass itself stays
        // clear/refractive in both — only the tint colour flips, which
        // is exactly the "dark/light" feel without any font jank.
        let a = glassiness * 0.5
        g.tintColor = light
            ? NSColor(calibratedRed: 0.90, green: 0.92, blue: 0.96, alpha: a)
            : NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: a)
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
    @ViewBuilder
    func glassPill(tinted: Bool = false) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self
                .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        }
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
