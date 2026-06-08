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

    /// `.key` when this view's window is the key window AND its app is
    /// frontmost. Used to suspend the sweep/pulse the moment Conterm
    /// drops to the background — the animation has no perceptual value
    /// while you can't see it, but it keeps the GPU compositor warm
    /// (visible in `powermetrics` as continuous COMPOSITOR wakes).
    @Environment(\.controlActiveState) private var activeState

    @State private var sweep: Double = 0
    @State private var pulse = false

    private var working: Bool { status.phase == .working }
    private var attention: Bool { status.phase == .attention }
    private var windowIsKey: Bool { activeState == .key }

    var body: some View {
        HStack(spacing: 9) {
            mark
            Text(status.label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
                // Crossfade the words instead of a hard swap, so
                // "thinking…" → "Ready." → "needs you" dissolves.
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .glassPill()
        // Phase-keyed identity so the ring (a different shape per
        // phase) crossfades on transition instead of popping.
        .overlay {
            if prefs.agentPillLite {
                liteRing
            } else {
                neonRing.id(status.phase).transition(.opacity)
            }
        }
        .shadow(color: glowColor.opacity(
                    prefs.agentPillLite
                        ? 0
                        : (working ? 0.55 : (attention ? 0.45 : 0.15))),
                radius: prefs.agentPillLite
                    ? 0
                    : (working ? 12 : (attention ? 9 : 5)))
        // Spring (not ease) the whole morph: the capsule width
        // tracks the label length, the mark tint and glow ramp,
        // all on one buttery physical curve.
        .animation(Theme.Spring.snappy, value: status)
        .onAppear { startAnimations() }
        .onChange(of: status.phase) { _, _ in startAnimations() }
        .onChange(of: prefs.agentPillLite) { _, _ in startAnimations() }
        .onChange(of: windowIsKey) { _, _ in startAnimations() }
    }

    /// Low-animation overlay used when `agentPillLite` is on. A flat
    /// colored border replaces the gradient sweep / blur halo; only
    /// the attention state still pulses so a needs-you is still
    /// noticeable from a glance.
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
        let tint = (working || attention) ? glowColor : Theme.textSecondary
        if let asset = status.tool.markAsset,
           let url = Bundle.main.url(forResource: asset, withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            let templated = status.tool.markIsTemplate
            let prepared: NSImage = {
                let c = img.copy() as! NSImage
                c.isTemplate = templated
                return c
            }()
            Image(nsImage: prepared)
                .resizable().interpolation(.high)
                // Preserve the mark's aspect (OpenCode's is a tall
                // block — squishing it into a square distorted it).
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                // Template marks get tinted; designed artwork shows
                // in its own colours.
                .foregroundStyle(templated ? tint : Color.primary)
                // Mark spins gently while thinking; skipped in lite
                // mode and whenever this window isn't key so we don't
                // burn the compositor while you're in another app.
                .rotationEffect(.degrees(
                    (working && !prefs.agentPillLite && windowIsKey)
                        ? sweep * 360 : 0))
        } else {
            Image(systemName: status.tool.fallbackSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(
                    (working && !prefs.agentPillLite && windowIsKey)
                        ? sweep * 360 : 0))
        }
    }

    // MARK: - Neon ring

    /// Per-agent accent (Claude=orange, opencode=violet, …).
    private var glowColor: Color { status.tool.glowColor }

    @ViewBuilder
    private var neonRing: some View {
        // When the window isn't key, freeze the working/attention ring
        // on a static rim — same visual weight as ready, none of the
        // animated cost. Comes back the instant the window is keyed.
        if !windowIsKey {
            Capsule(style: .continuous)
                .strokeBorder(glowColor.opacity(working || attention ? 0.55 : 0.16),
                              lineWidth: 1.0)
                .allowsHitTesting(false)
        } else if working {
            Capsule(style: .continuous)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear,                 location: 0.00),
                            .init(color: glowColor.opacity(0.0), location: 0.55),
                            .init(color: glowColor,              location: 0.78),
                            .init(color: .white,                 location: 0.84),
                            .init(color: glowColor,              location: 0.90),
                            .init(color: glowColor.opacity(0.0), location: 1.00),
                        ]),
                        center: .center,
                        angle: .degrees(sweep * 360)
                    ),
                    lineWidth: 2.2
                )
                .blur(radius: 4)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .clear,      location: 0.0),
                                    .init(color: glowColor.opacity(0.0), location: 0.6),
                                    .init(color: .white,      location: 0.84),
                                    .init(color: glowColor.opacity(0.0), location: 1.0),
                                ]),
                                center: .center,
                                angle: .degrees(sweep * 360)
                            ),
                            lineWidth: 1.0
                        )
                )
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
            sweep = 0
            pulse = false
            return
        }
        if prefs.agentPillLite {
            // Lite mode: no sweep, no working-state animation. Only
            // attention pulses, so a needs-you is still noticeable.
            sweep = 0
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
            sweep = 0
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                sweep = 1
            }
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
