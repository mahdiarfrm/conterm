import AppKit
import SwiftUI

struct PaneTitleBar: View {
    let dirLabel: String
    /// Non-nil when the pane is inside an ssh session — shown
    /// instead of the local cwd, with a 🌐 globe glyph to make the
    /// remote state visually obvious. Cleared automatically when
    /// you exit the ssh session.
    let remoteHost: String?
    let index: Int
    let isActive: Bool
    @EnvironmentObject var prefs: Preferences
    /// Collapsed: a small light capsule showing only the logo (status dot
    /// or ssh glyph) + the ⌥N keybind. Click the pill to toggle. Per-pane,
    /// transient — not persisted.
    @State private var collapsed = false

    /// One-shot "connection established" sweep: a light band glides across
    /// the capsule once when the pane goes local → remote, then stops.
    /// `shimmering` keeps the overlay out of the tree at rest so the remote
    /// pill costs nothing per frame once connected.
    @State private var shimmerPhase: CGFloat = 0
    @State private var shimmering = false

    /// The sweep only fires when the pane's window is key — an off-screen
    /// animation still drives compositor recomposites — and is dropped
    /// under Reduce Motion.
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var labelText: String {
        remoteHost ?? dirLabel
    }

    private var labelIcon: String? {
        remoteHost == nil ? nil : "network"
    }

    /// When SSH'd, paint the dot in a distinct hue so users see at
    /// a glance which panes are remote.
    private var dotColor: Color {
        if remoteHost != nil {
            return isActive ? Theme.sshAccent : Theme.sshAccent.opacity(0.55)
        }
        return isActive ? Theme.accentOnDark : Color.white.opacity(0.35)
    }

    var body: some View {
        HStack(spacing: collapsed ? 7 : 9) {
            // Logo: ssh glyph when remote, otherwise the status dot.
            if let icon = labelIcon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(collapsed
                        ? Theme.sshAccentDeep
                        : (isActive ? Color.white : Color.white.opacity(0.7)))
                    .shadow(color: (!collapsed && isActive) ? Theme.sshAccent.opacity(0.7) : .clear,
                            radius: 4)
            } else {
                Circle()
                    .fill(collapsed ? collapsedDot : dotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: (!collapsed && isActive) ? dotColor.opacity(0.7) : .clear,
                            radius: 4)
            }
            if !collapsed {
                Text(labelText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if index >= 1 && index <= 9 {
                KeybindChip(label: "⌥\(index)", isActive: isActive, light: collapsed)
            }
        }
        .padding(.horizontal, collapsed ? 9 : 12)
        .padding(.vertical, 6)
        .background(
            ZStack {
                if collapsed {
                    // Light, solid capsule — the compact state.
                    Capsule(style: .continuous).fill(Color.white.opacity(0.92))
                } else {
                    // Solid (opaque) bed: the pill floats over the opaque
                    // terminal, so it reads as a solid chip, not glass. The
                    // cool variant marks an SSH pane statically — no per-frame
                    // cost over a long remote session.
                    Capsule(style: .continuous)
                        .fill(remoteHost != nil ? Theme.paneRemoteBar : Theme.paneTitleBar)
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(isActive ? 0.10 : 0.0))
                        .blendMode(.plusLighter)
                }
            }
        )
        // One-shot light sweep on connect — kept out of the tree at rest.
        .overlay {
            if shimmering { connectSweep }
        }
        // Flat strokeBorder (solid colour) — a LinearGradient stroke
        // here forces macOS to re-rasterise on every SwiftUI redraw,
        // which dominates compositing cost during mouse activity.
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.6)
        )
        // Collapsed pill is a bright light capsule, so it must dim on an
        // inactive pane the way the expanded pill does through its colours
        // — otherwise an unfocused pane still looks lit.
        .opacity(collapsed && !isActive ? 0.5 : 1)
        // Tap toggles the compact state. contentShape makes the whole
        // capsule the hit target; the surrounding overlay frame stays
        // empty so clicks elsewhere fall through to the terminal.
        .contentShape(Capsule(style: .continuous))
        .onTapGesture {
            withAnimation(Theme.Spring.snappy) { collapsed.toggle() }
        }
        // .shadow() removed: per-pane shadows are CIFilters that
        // the compositor re-evaluates every frame; with many panes
        // they were the dominant lag cost. The strokeBorder above
        // already separates the title bar from the terminal cells.
        .animation(Theme.Spring.snappy, value: isActive)
        .animation(Theme.Spring.snappy, value: dirLabel)
        .animation(Theme.Spring.snappy, value: remoteHost)
        .animation(Theme.Spring.snappy, value: collapsed)
        // Fire the connect sweep only on a live local → remote (or host
        // switch) transition; a pane that restores already-remote stays
        // statically tinted without replaying it.
        .onChange(of: remoteHost) { old, new in
            guard new != nil, old != new, !reduceMotion, activeState == .key else { return }
            shimmerPhase = 0
            shimmering = true
            withAnimation(.easeOut(duration: 0.8)) {
                shimmerPhase = 1
            } completion: {
                shimmering = false
            }
        }
    }

    /// Capsule border: cyan while remote, neutral white otherwise; darker
    /// on the collapsed light bed. Flat solid colours only — see the note
    /// on the stroke overlay.
    private var borderColor: Color {
        if collapsed { return Color.black.opacity(0.12) }
        if remoteHost != nil {
            return Theme.sshAccent.opacity(isActive ? 0.45 : 0.18)
        }
        return Color.white.opacity(isActive ? 0.30 : 0.10)
    }

    /// A narrow band of cyan light that travels left → right across the
    /// capsule once, clipped to the pill so it reads as the glass catching
    /// light at the moment the remote link comes up.
    private var connectSweep: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.clear, Theme.sshAccent.opacity(0.55), .clear],
                        startPoint: .leading, endPoint: .trailing)
                )
                .frame(width: w * 0.4)
                .offset(x: -0.45 * w + shimmerPhase * 1.5 * w)
                .blendMode(.plusLighter)
        }
        .clipShape(Capsule(style: .continuous))
        .allowsHitTesting(false)
    }

    /// Status dot colour in the collapsed (light) capsule — must read on
    /// the light bed, so darker than the expanded variant.
    private var collapsedDot: Color {
        remoteHost != nil
            ? Color(red: 0.10, green: 0.50, blue: 0.95)
            : Color.black.opacity(0.55)
    }
}

private struct KeybindChip: View {
    let label: String
    let isActive: Bool
    /// Dark-on-light styling for the collapsed (light) title pill.
    var light: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(light
                ? Color.black.opacity(0.7)
                : (isActive ? Theme.accentOnDark : Color.white.opacity(0.55)))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(light
                        ? Color.black.opacity(0.08)
                        : Color.white.opacity(isActive ? 0.18 : 0.06))
            )
    }
}

/// Small glass chip showing how the last shell command finished:
/// a green check + duration on success, a red ✗ + exit code on
/// failure, a neutral clock when the shell reported no exit code.
/// Matches the title pill's glass styling so the two read as a set.
struct CommandBadge: View {
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
