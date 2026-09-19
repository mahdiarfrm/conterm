import AppKit
import SwiftUI

// Classic interface style: the chips that float over a pane — the agent pill,
// its tool bubbles, the History capsule, the command badge and the Ansible
// run badge — as they are drawn when `Preferences.interfaceStyle` is
// `.classic`. `PaneChrome` picks between these and the Liquid Drop forms.

/// Classic interface style. Floating status pill for an AI coding agent (Claude Code / opencode)
/// running in a pane. Liquid-glass capsule: the agent's monochrome mark
/// on the LEFT, then the status text. It stays visible the whole time
/// the agent is running — calm while *ready*, an orange neon light
/// sweeping the capsule edge while *thinking*, steady amber when it
/// *needs you*. Vanishes only when the session ends.
///
/// The sweeping glow only animates while the agent is *working*, so it
/// costs nothing while merely ready/attention.
struct ClassicAgentPill: View {
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
        if let asset = status.tool.pillMarkAsset,
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

/// Classic interface style. One kind of call in flight as a bubble: the mark, monochrome on the
/// pill's dark bed, ringed in the kind's colour — the mark says what, the
/// ring says whose. While the call runs the ring is the same
/// compositor-side sweep the agent pill uses; a bubble held past its
/// call's end shows a still rim, with a red dot when the call failed.
/// `count` badges several calls of the kind running at once.
struct ClassicAgentToolBubble: View {
    let run: AgentToolRun
    var count: Int = 1
    var size: CGFloat = 28
    var action: () -> Void

    /// The sweep only animates while it can be seen and the machine isn't
    /// asking for less motion — same gates as the pill.
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var systemLite = false
    @State private var hovering = false

    private var color: Color { run.kind.color }
    private static let failColor = Color(red: 1.0, green: 0.42, blue: 0.42)
    private static let bed = Color(red: 0.05, green: 0.055, blue: 0.07)
    /// Pinned light like the pill's label: the bubble floats over the dark
    /// terminal in both appearances.
    private static let ink = Color(white: 0.96)

    private var sweeps: Bool {
        run.isRunning && activeState == .key && !reduceMotion && !systemLite
    }

    private var ringColor: Color {
        if run.isRunning { return color.opacity(0.8) }
        return run.failed ? Self.failColor.opacity(0.7) : color.opacity(0.55)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Self.bed)
                Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                AgentToolGlyph(kind: run.kind,
                               color: Self.ink.opacity(run.isRunning || hovering ? 1 : 0.75),
                               size: size * 0.52)
            }
            .frame(width: size, height: size)
            .overlay {
                if sweeps {
                    SweepRing(color: color).allowsHitTesting(false)
                } else {
                    Circle()
                        .strokeBorder(ringColor, lineWidth: run.isRunning ? 1.3 : 1.0)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Self.ink)
                        .padding(.horizontal, size * 0.12)
                        .frame(height: size * 0.38)
                        .background(Capsule().fill(Self.bed))
                        .overlay(Capsule().strokeBorder(color.opacity(0.7), lineWidth: 0.8))
                        .offset(x: size * 0.12, y: size * 0.08)
                } else if !run.isRunning, run.failed {
                    Circle()
                        .fill(Self.failColor)
                        .frame(width: size * 0.3, height: size * 0.3)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.7), lineWidth: 1))
                        .offset(x: size * 0.06, y: size * 0.06)
                }
            }
            // No shadow under the sweep: its halo passes are the glow, and a
            // live filter over an animating ring re-renders per frame.
            .shadow(color: color.opacity(sweeps ? 0 : (hovering ? 0.55 : 0.22)),
                    radius: hovering ? 7 : 3)
            .scaleEffect(hovering ? 1.08 : 1.0)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Spring.snappy, value: hovering)
        .onReceive(SystemPressure.shared.$wantsLowAnimation) { systemLite = $0 }
        .help(help)
    }

    private var help: String {
        let state: String
        if run.isRunning { state = count > 1 ? "\(count) running" : "running" }
        else if run.failed { state = "failed" }
        else { state = "done" }
        return "\(run.kind.displayName) · \(state)\n\(run.title)"
    }
}

/// Classic interface style. The pane's record of finished calls, as one glass capsule leading
/// the agent pill's cluster: a count and the way in to the panel. No mark of its own — a
/// session runs many kinds of thing, and one logo would misname the rest.
/// Real Liquid Glass on macOS 26; the system thin material before that.
struct ClassicAgentToolHistoryButton: View {
    let count: Int
    /// Matched to the agent pill it sits beside.
    var height: CGFloat = 26
    var action: () -> Void
    @EnvironmentObject var prefs: Preferences
    @State private var hovering = false

    private var ink: Color {
        prefs.lightGlass ? Color.black.opacity(0.82) : Color.white.opacity(0.92)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(ink)
                Text("History")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink)
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ink.opacity(0.85))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(ink.opacity(0.14)))
            }
            .padding(.leading, 10).padding(.trailing, 7)
            .frame(height: height)
            .background(glass)
            .glassPill()
            .shadow(color: .black.opacity(hovering ? 0.35 : 0.22),
                    radius: hovering ? 8 : 4, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.04 : 1.0)
        .animation(Theme.Spring.snappy, value: hovering)
        .onHover { hovering = $0 }
        .help("What the agent did in this pane")
    }

    @ViewBuilder
    private var glass: some View {
        if #available(macOS 26, *) {
            PaneLiquidGlass(cornerRadius: height / 2, frostiness: 0.35,
                            light: prefs.lightGlass)
                .clipShape(Capsule(style: .continuous))
        } else {
            Capsule(style: .continuous).fill(.ultraThinMaterial)
        }
    }
}

struct ClassicCommandBadge: View {
    let result: Pane.CommandResult
    @EnvironmentObject var prefs: Preferences

    private var unknownExit: Bool { result.exitCode < 0 }

    private var tint: Color {
        if unknownExit { return Color.white.opacity(0.6) }
        return result.failed ? Color(red: 1.0, green: 0.42, blue: 0.42)
                             : Color(red: 0.45, green: 0.86, blue: 0.55)
    }
    private var icon: String {
        if unknownExit { return "clock" }
        return result.failed ? "xmark.circle.fill" : "checkmark.circle.fill"
    }
    private var label: String {
        let dur = formatCommandDuration(result.durationNs)
        return result.failed ? "exit \(result.exitCode) · \(dur)" : dur
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            ZStack {
                Capsule(style: .continuous).fill(Theme.paneTitleBar)
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.16))
                    .blendMode(.plusLighter)
            }
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(tint.opacity(0.45), lineWidth: 0.6)
        )
    }
}

/// Classic interface style. Pane badge while a playbook is live (or just finished): counts at a
/// glance, click for the cockpit. Event-driven text only — no ambient
/// animation.
struct ClassicAnsiblePill: View {
    let run: AnsibleCenter.Run
    var onTap: () -> Void

    private var stateTint: Color {
        if run.failedTotal > 0 { return Color.red.opacity(0.95) }
        if run.finished { return Color(red: 0.45, green: 0.85, blue: 0.55) }
        return Theme.accent
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if let mark = CommandRow.bundledTemplateImage(named: "ansible-mark") {
                    Image(nsImage: mark)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 10, height: 10)
                        .foregroundStyle(stateTint)
                } else {
                    Image(systemName: run.finished
                          ? (run.failedTotal > 0 ? "xmark.circle.fill"
                                                 : "checkmark.circle.fill")
                          : "play.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(stateTint)
                }
                Text("\(run.playbook) · \(run.summary)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.chipBed))
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Ansible run — click for the cockpit")
    }
}
