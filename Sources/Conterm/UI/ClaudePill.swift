import AppKit
import SwiftUI

/// Floating status pill for an AI coding agent (Claude Code / opencode)
/// running in a pane. Liquid-glass capsule: the agent's monochrome mark
/// on the LEFT, then the status text. It stays visible the whole time
/// the agent is running — calm while *ready*, an orange neon light
/// sweeping the capsule edge while *thinking*, steady amber when it
/// *needs you*. Vanishes only when the session ends.
///
/// The sweeping glow only animates while the agent is *working*, so it
/// costs nothing while merely ready/attention.
struct AgentPill: View {
    let status: AgentStatus
    @EnvironmentObject var prefs: Preferences

    /// `.key` only when this view's window is key and its app is
    /// frontmost. The sweep and pulse are gated on this: an animation
    /// that isn't on screen still drives continuous compositor
    /// recomposites, so a non-key pane must stay at zero render cost.
    @Environment(\.controlActiveState) private var activeState

    @State private var pulse = false
    /// Mirrors `SystemPressure.wantsLowAnimation` (Low Power Mode or
    /// thermal pressure) so a hot machine sheds the sweep first.
    @State private var systemLite = false

    private var working: Bool { status.phase == .working }
    private var attention: Bool { status.phase == .attention }
    private var windowIsKey: Bool { activeState == .key }

    /// System Reduce Motion: users who ask the OS for no motion get the
    /// static ring.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The static-ring fallback. Not a user preference — the sweep is
    /// compositor-cheap (see SweepRing) — but it still yields to the OS
    /// Reduce Motion setting and to power/thermal pressure, which shed
    /// the remaining per-frame compositing.
    private var lite: Bool { reduceMotion || systemLite }

    var body: some View {
        HStack(spacing: 9) {
            mark
            Text(status.label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                // Pinned light, not adaptive: the pill keeps its dark bed in
                // both appearances (it floats over the dark terminal), so the
                // label must stay light or it vanishes in light mode.
                .foregroundStyle(Color(white: 0.96))
                .lineLimit(1)
                .fixedSize()
                // Crossfade the words instead of a hard swap, so
                // "thinking…" → "Ready." → "needs you" dissolves.
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        // Flat black bed: the pill floats over the opaque terminal, and its
        // sweep/glow/ring animation is the beauty here — a flat opaque bed
        // is cheapest (no per-frame glass re-lens) and makes the animation
        // pop against the dark cells.
        .background(flatPillBackground)
        // Phase-keyed identity so the ring (a different shape per
        // phase) crossfades on transition instead of popping.
        .overlay {
            if lite {
                liteRing
            } else {
                neonRing.id(status.phase).transition(.opacity)
            }
        }
        // No outer shadow while working: a live filter over the animating
        // ring would re-render per frame — the SweepRing's stacked halo
        // passes carry the working glow instead.
        .shadow(color: glowColor.opacity(
                    (lite || working)
                        ? 0
                        : (attention ? 0.45 : 0.15)),
                radius: (lite || working)
                    ? 0
                    : (attention ? 9 : 5))
        // Spring (not ease) the morph: the capsule width tracks the
        // label length, the mark tint and glow ramp, all on one buttery
        // physical curve. Keyed on `phase` (not the whole status) so a
        // streaming progress percent doesn't re-trigger the spring +
        // capsule relayout on every OSC update — that overlapping-spring
        // storm drove a continuous AppKit layout / CA-commit load.
        .animation(Theme.Spring.snappy, value: status.phase)
        .onAppear { startAnimations() }
        .onChange(of: status.phase) { _, _ in startAnimations() }
        .onChange(of: lite) { _, _ in startAnimations() }
        .onChange(of: windowIsKey) { _, _ in startAnimations() }
        .onReceive(SystemPressure.shared.$wantsLowAnimation) { systemLite = $0 }
    }

    /// Flat near-black capsule bed — opaque so the streaming terminal
    /// behind costs nothing, with a hairline rim for definition when the
    /// animated ring is quiet.
    private var flatPillBackground: some View {
        Capsule(style: .continuous)
            .fill(Color(red: 0.05, green: 0.055, blue: 0.07))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
    }

    /// Low-animation overlay used whenever the pill is `lite` (the
    /// lite-pill or low-power-glass preference). A flat colored border
    /// replaces the gradient sweep / blur halo; only the attention
    /// state still pulses so a needs-you is still noticeable.
    @ViewBuilder
    private var liteRing: some View {
        let color: Color = (working || attention) ? glowColor
                                                  : Color.white.opacity(0.16)
        let opacity: Double = attention ? (pulse ? 0.85 : 0.40)
                                        : (working ? 0.75 : 1.0)
        Capsule(style: .continuous)
            .strokeBorder(color.opacity(opacity), lineWidth: 1.2)
            .allowsHitTesting(false)
    }

    // MARK: - Agent mark (left)

    @ViewBuilder
    private var mark: some View {
        // Pinned light for the same reason as the label — see `body`.
        let tint = (working || attention) ? glowColor : Color.white.opacity(0.6)
        let templated = status.tool.markIsTemplate
        // Cached decode: `mark` re-evaluates every frame while the sweep
        // animates, so reading the PNG here uncached hit the disk per frame.
        if let asset = status.tool.markAsset,
           let img = MarkImage.load(asset, template: templated) {
            Image(nsImage: img)
                .resizable().interpolation(.high)
                // Preserve the mark's aspect (OpenCode's is a tall
                // block — squishing it into a square distorted it).
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                // Template marks get tinted; designed artwork shows
                // in its own colours.
                .foregroundStyle(templated ? tint : Color.primary)
                // The mark does not spin: any SwiftUI repeatForever
                // animation re-renders the hosting view's graph every
                // frame on macOS — the SweepRing carries the working
                // motion compositor-side instead.
        } else {
            Image(systemName: status.tool.fallbackSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    // MARK: - Neon ring

    /// Per-agent accent (Claude=orange, opencode=violet, …).
    private var glowColor: Color { status.tool.glowColor }

    @ViewBuilder
    private var neonRing: some View {
        // When the window isn't key, freeze the working/attention ring
        // on a static rim: same visual weight as ready, none of the
        // animated cost.
        if !windowIsKey {
            Capsule(style: .continuous)
                .strokeBorder(glowColor.opacity(working || attention ? 0.55 : 0.16),
                              lineWidth: 1.0)
                .allowsHitTesting(false)
        } else if working {
            // Pure-CA sweep: static conic gradient rotated by transform,
            // masked through the capsule stroke, glow baked as stacked
            // stroke passes (see SweepRing). Nothing re-renders per frame
            // — the whole animation runs compositor-side.
            SweepRing(color: glowColor)
                .allowsHitTesting(false)
        } else if attention {
            Capsule(style: .continuous)
                .strokeBorder(glowColor.opacity(pulse ? 0.85 : 0.40),
                              lineWidth: 1.4)
                .shadow(color: glowColor.opacity(pulse ? 0.6 : 0.25),
                        radius: pulse ? 10 : 4)
                .allowsHitTesting(false)
        } else {
            // ready: a soft, static rim so it still reads as "alive".
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }

    private func startAnimations() {
        // Bail out early when this window isn't key — no repeatForever
        // gets a chance to start. The animation re-arms via the
        // .onChange(of: windowIsKey) handler when focus returns.
        guard windowIsKey else {
            pulse = false
            return
        }
        if lite {
            // Lite mode: no working-state animation. Only attention
            // pulses, so a needs-you is still noticeable.
            if attention {
                pulse = false
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                pulse = false
            }
            return
        }
        if working {
            // No SwiftUI-driven animation while working — the CA ring
            // self-animates and per-frame ViewGraph churn is the cost.
        } else if attention {
            pulse = false
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            pulse = false
        }
    }
}
