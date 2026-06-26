import AppKit
import SwiftUI

/// Wraps a tab's pane tree in SwiftUI. Recursively renders nested splits
/// driven by `PaneNode`.
struct TerminalContainer: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var notifications: NotificationStore
    var isActive: Bool

    var body: some View {
        // The pane tree is owned by AppKit (PaneTreeView): a surviving pane is
        // only reframed across splits/closes, never reparented, so libghostty's
        // IOSurface stays attached. No .id-rebuild / host-reuse workaround.
        if let app = state.ghostty {
            PaneTreeHost(tree: tab.paneTree, app: app, state: state,
                         notifications: notifications, prefs: prefs)
        } else {
            Text("libghostty failed to initialize")
                .foregroundStyle(Theme.warning)
        }
    }
}

private struct TreeView: View {
    @ObservedObject var node: PaneNode
    // PaneTree must be @ObservedObject — when activePaneID flips,
    // SwiftUI needs to re-render this subtree so PaneView's isActive
    // prop reflects the new active pane. With a plain `let`,
    // activePaneID changes don't trigger a body recompute and the
    // dim-scrim ends up stale (the symptom: 2 panes look focused).
    @ObservedObject var tree: PaneTree

    var body: some View {
        switch node.kind {
        case .leaf(let pane):
            // Index = 1-based position of this pane in the tab's
            // depth-first leaf order. Used by the pane's title bar
            // to show its ⌥N keybind. Recomputed each render — fast
            // (a few comparisons) and always correct after restructure.
            let allLeaves = tree.root.leaves()
            let idx = (allLeaves.firstIndex(where: { $0.id == pane.id }) ?? -1) + 1
            PaneView(pane: pane,
                      isActive: tree.activePaneID == pane.id,
                      index: idx,
                      onFocus: { tree.focus(pane) })
        case .split(let axis, let a, let b):
            SplitArea(node: node, tree: tree, axis: axis, first: a, second: b)
        }
    }
}

private struct SplitArea: View {
    @ObservedObject var node: PaneNode
    @ObservedObject var tree: PaneTree
    let axis: SplitAxis
    let first: PaneNode
    let second: PaneNode

    var body: some View {
        GeometryReader { geo in
            let total = axis == .horizontal ? geo.size.width : geo.size.height
            let firstSize = max(80, total * node.firstFraction)
            let dividerThickness: CGFloat = 6

            if axis == .horizontal {
                HStack(spacing: 0) {
                    TreeView(node: first, tree: tree)
                        .frame(width: firstSize - dividerThickness / 2)
                    divider(total: total)
                    TreeView(node: second, tree: tree)
                }
            } else {
                VStack(spacing: 0) {
                    TreeView(node: first, tree: tree)
                        .frame(height: firstSize - dividerThickness / 2)
                    divider(total: total)
                    TreeView(node: second, tree: tree)
                }
            }
        }
    }

    private func divider(total: CGFloat) -> some View {
        SplitDivider(
            axis: axis,
            onHoverChange: { hovering in
                // The window is movable-by-background (WindowChrome) and a
                // SwiftUI view can't opt out via `mouseDownCanMoveWindow`.
                // Suspend background dragging while the cursor is on the
                // divider so a resize drag isn't reinterpreted as a window
                // move; restore on exit — but not during a drag, since a
                // fast drag can briefly leave the thin hit area.
                if hovering {
                    NSApp.keyWindow?.isMovableByWindowBackground = false
                } else if node.dividerDrag == nil {
                    NSApp.keyWindow?.isMovableByWindowBackground = true
                }
            },
            onChanged: { value in
                // A new drag (startLocation changes) re-anchors to the live
                // fraction + the current global cursor position.
                if node.dividerDrag?.startLocation != value.startLocation {
                    node.dividerDrag = PaneNode.DividerDrag(
                        startLocation: value.startLocation,
                        anchorMouse: NSEvent.mouseLocation,
                        anchorFraction: node.firstFraction)
                    NSApp.keyWindow?.isMovableByWindowBackground = false
                }
                guard let drag = node.dividerDrag else { return }
                // Drive resize from the GLOBAL cursor position (screen
                // coords): a SwiftUI drag value's location reads through the
                // AppKit hosting y-flipped. Screen y increases upward, so a
                // downward drag grows the top pane (positive delta);
                // rightward grows the left pane.
                let m = NSEvent.mouseLocation
                let deltaPx = axis == .horizontal ? (m.x - drag.anchorMouse.x)
                                                  : (drag.anchorMouse.y - m.y)
                let raw = drag.anchorFraction + Double(deltaPx / max(total, 1))
                // Magnetic mid-snap at exactly 50 % within ±2.5 %, clamped.
                let snapped = abs(raw - 0.5) < 0.025 ? 0.5 : raw
                node.firstFraction = min(0.88, max(0.12, snapped))
            },
            onEnded: {
                node.dividerDrag = nil
                NSApp.keyWindow?.isMovableByWindowBackground = true
            })
    }
}

/// Hairline divider. Resting state: nearly invisible. Hover: brightens
/// and gains a soft glow. Hit area is wider than the visual stroke so
/// the user can grab it easily without showing a fat slab at rest.
///
/// Must stay pure SwiftUI with no backing NSView: an NSView sibling of
/// the libghostty surface views perturbs the CoreAnimation commit during
/// pane teardown and trips libghostty's surface-free-during-draw renderer
/// abort. The drag is handled by a SwiftUI gesture reading
/// `NSEvent.mouseLocation` (screen coords sidestep the AppKit y-flip),
/// with drag state on the PaneNode rather than @State so a mid-drag
/// re-render can't cancel the gesture.
private struct SplitDivider: View {
    let axis: SplitAxis
    let onHoverChange: (Bool) -> Void
    let onChanged: (DragGesture.Value) -> Void
    let onEnded: () -> Void
    @State private var hovering = false

    var body: some View {
        let line: CGFloat = hovering ? 1.5 : 0.8
        // A horizontal line (the .vertical split between stacked panes) is
        // harder to land on than a vertical one — vertical cursor aim is
        // coarser — so give it a taller grab band to feel as easy to seize.
        let hit: CGFloat = axis == .vertical ? 12 : 8
        Rectangle()
            .fill(hovering ? Color.white.opacity(0.55) : Color.white.opacity(0.10))
            .frame(width: axis == .horizontal ? line : nil,
                   height: axis == .vertical   ? line : nil)
            .shadow(color: hovering ? Color.white.opacity(0.45) : .clear,
                    radius: hovering ? 4 : 0)
            .frame(width: axis == .horizontal ? hit : nil,
                   height: axis == .vertical   ? hit : nil)
            .contentShape(Rectangle())
            .onHover { h in
                hovering = h
                onHoverChange(h)
                if h {
                    (axis == .horizontal ? NSCursor.resizeLeftRight
                                         : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onChanged($0) }
                    .onEnded { _ in onEnded() }
            )
            .animation(Theme.Spring.snappy, value: hovering)
    }
}

/// Floating glass pill that sits at the top of every pane. Shows
/// the pane's current directory (or remote host when SSH'd) plus a
/// keybind chip (⌥1..⌥9) for keyboard pane-switching. Made small and
/// translucent so it doesn't fight the terminal output behind it.
private struct PaneTitleBar: View {
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
private struct CommandBadge: View {
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

/// Human-friendly run time for a command badge / notification.
/// < 1s → "420ms"; < 10s → "1.4s"; < 60s → "12s"; else "2m 03s".
private func formatCommandDuration(_ ns: UInt64) -> String {
    let seconds = Double(ns) / 1_000_000_000
    if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
    if seconds < 10 { return String(format: "%.1fs", seconds) }
    if seconds < 60 { return "\(Int(seconds.rounded()))s" }
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return String(format: "%dm %02ds", m, s)
}

/// Returns a friendly short label for `cwd`. Replaces home dir with
/// `~`, preserves the `~/` (or `/`) anchor so the user can always tell
/// which root the path is under, and shows up to the last three path
/// segments — deeper paths are signalled with an ellipsis between the
/// anchor and the tail (e.g. `~/…/sibche/v5-infra/services`). The
/// 3-segment depth is a compromise between "just the basename"
/// (too little context) and the full path (overflows the pill on
/// narrow panes).
@MainActor
private func friendlyDirLabel(for cwd: String?) -> String {
    guard let cwd, !cwd.isEmpty else { return "—" }
    let home = NSHomeDirectory()
    if cwd == home { return "~" }
    if cwd == "/" { return "/" }

    var rest: String
    var anchor: String
    if cwd.hasPrefix(home + "/") {
        rest = String(cwd.dropFirst(home.count + 1))
        anchor = "~/"
    } else if cwd.hasPrefix("/") {
        rest = String(cwd.dropFirst())
        anchor = "/"
    } else {
        rest = cwd
        anchor = ""
    }

    let parts = rest.split(separator: "/").map(String.init)
    let maxTail = 3
    if parts.count <= maxTail {
        return anchor + parts.joined(separator: "/")
    }
    return anchor + "…/" + parts.suffix(maxTail).joined(separator: "/")
}

private struct PaneView: View {
    @ObservedObject var pane: Pane
    var isActive: Bool
    var index: Int
    var onFocus: () -> Void
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences
    /// Transient command-result chip, shown for a few seconds after a
    /// command finishes (set by the `pane.lastCommand` observer below).
    @State private var commandBadge: Pane.CommandResult?
    /// Generation token for the "needs you" auto-dismiss timer, so a new
    /// attention restarts the 30s clock instead of an old timer clearing it.
    @State private var attentionGen = 0

    /// Tab that owns this pane, for resyncing its aggregated `agentPhase`
    /// (the tab-bar dot) whenever this pane's agent phase is cleared here.
    private var owningTab: Tab? {
        state.tabs.first { $0.paneTree.root.leaves().contains { $0.id == pane.id } }
    }

    var body: some View {
        let corner = Theme.paneCorner
        return ZStack {
            // 1. Background fill. Solid panes (default): an OPAQUE tile, so
            //    glass only ever shows where there's no terminal under it
            //    (top bar + gaps) and the streaming region never blends
            //    against the desktop — markedly cooler on fanless Macs.
            //    When off, the backing is clear so a translucent terminal
            //    (its own background-opacity / blur) reveals the glass
            //    behind the cells — lusher, but the desktop re-composites
            //    under the stream.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(prefs.opaquePanes ? Theme.paneTile : Color.clear)

            // 2. The terminal itself. We previously wrapped this in
            //    compositingGroup() for anti-aliased corners, but
            //    that pushed an offscreen render layer between
            //    SwiftUI's compositor and libghostty's CAMetalLayer,
            //    which under heavy reparenting (rapid splits) left
            //    older panes stuck showing a stale frame.
            if let app = state.ghostty {
                GeometryReader { geo in
                    GhosttySurfaceRep(
                        pane: pane,
                        app: app,
                        size: CGSize(width: max(0, geo.size.width - 2),
                                      height: max(0, geo.size.height - 2)))
                        .padding(1)
                }
                .clipShape(
                    RoundedRectangle(cornerRadius: corner - 1,
                                      style: .continuous)
                )
            } else {
                Text("libghostty failed to initialize")
                    .foregroundStyle(Theme.warning)
            }

            // 3. Dim wash over inactive panes — ON TOP of the Metal
            //    surface so it actually darkens it.
            if !isActive {
                RoundedRectangle(cornerRadius: corner - 1, style: .continuous)
                    .fill(Color.black.opacity(0.32))
                    .padding(1)
                    .allowsHitTesting(false)
            }

            // 4. Glass top-edge highlight — painted ON TOP of the
            //    Metal layer so the glass effect reaches into the
            //    rounded corners instead of being hidden under terminal
            //    content. The original used `.stroke(LinearGradient...)`
            //    but an Instruments trace showed `rgba64_shade_axial_RGB`
            //    was the top single hot path (35% of active CPU during
            //    mouse activity) — every gradient stroke per pane is
            //    re-rasterised by `RIPLayerBltShade` on each frame.
            //    Flat color stroke is functionally identical to the eye
            //    here but cheap.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(
                    Color.white.opacity(isActive ? 0.32 : 0.07),
                    lineWidth: isActive ? 1.5 : 0.5
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)

            // 5. Outer border — also on top so it cleanly defines the
            //    pane's edge against the window background and shows
            //    the active state.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(
                    isActive ? Color.white.opacity(0.55) : Color.white.opacity(0.05),
                    lineWidth: isActive ? 1 : 0.5
                )
                .allowsHitTesting(false)

            // 5b. Focus halo — a rim that signals the active pane.
            //     Implemented as a doubled-up strokeBorder rather than
            //     stacked `.shadow()` modifiers: each `.shadow()` is a
            //     Core Image filter on the underlying CALayer and is
            //     re-evaluated by the compositor every frame, which
            //     becomes the dominant render cost with many panes.
            if isActive {
                RoundedRectangle(cornerRadius: corner + 2, style: .continuous)
                    .strokeBorder(Theme.highlight.opacity(0.18), lineWidth: 3)
                    .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Theme.highlight.opacity(0.75), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }

            // 6. Floating glass title bar pinned to the top-right
            //    corner. Shows dir (or remote host when SSH'd) +
            //    ⌥N keybind chip. Doesn't take layout space (overlay).
            //    User-toggleable via Settings → Panes.
            if prefs.showPaneTitleBar {
                PaneTitleBar(
                    dirLabel: friendlyDirLabel(for: pane.cwd),
                    remoteHost: pane.remoteHost,
                    index: index,
                    isActive: isActive
                )
                .padding(.top, 10)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topTrailing)
                // Hit-testable so the pill's click-to-collapse works; the
                // surrounding frame is empty (no background), so clicks
                // elsewhere fall through to the terminal.
                .transition(.opacity)
            }

            // 7. Claude Code status pill — top-center. Appears only
            //    while an agent is active in this pane; the rotating
            //    orange neon ring animates only while it's "working".
            if pane.agent.phase != .idle {
                AgentPill(status: pane.agent)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .top)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // 8. Transient command-result chip — bottom-trailing, near
            //    the prompt. Surfaces the exit status + run time of the
            //    last command that failed or took a moment; self-dismisses
            //    after a few seconds. Independent of the title-bar setting.
            if let badge = commandBadge {
                CommandBadge(result: badge)
                    .padding(.bottom, 10)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomTrailing)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onChange(of: pane.lastCommand) { _, result in
            // Stay calm: only surface failures and commands that took a
            // beat — sub-second successes (ls, cd, git status) shouldn't
            // pop a chip on every prompt return.
            guard prefs.commandAlerts, let result,
                  result.failed || result.durationSeconds >= 2 else { return }
            withAnimation(Theme.Spring.snappy) { commandBadge = result }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                // Only clear if no newer command has replaced it.
                if commandBadge?.at == result.at {
                    withAnimation(Theme.Spring.snappy) { commandBadge = nil }
                }
            }
        }
        .animation(Theme.Spring.snappy, value: pane.agent)
        // No .onTapGesture for focus: a SwiftUI tap gesture recomputes
        // this view's body on every pointer move to test whether a tap is
        // still in flight, which is wasteful during mouse activity.
        // SurfaceView.mouseDown owns focus transfer; the dim / title-bar /
        // agent-pill overlays use `.allowsHitTesting(false)` so clicks
        // fall through to it.
        // Pure opacity fade on insert/remove — no scale, because a
        // scale animation forces the libghostty IOSurface layer
        // through a CALayer affine transform on every frame, which
        // is what makes split / close feel laggy. Opacity alone
        // animates cheaply on the compositor.
        .transition(.opacity)
        // Stable identity per pane so resizing/diff doesn't remount.
        .id(pane.id)
        .onAppear { if isActive { pullKeyboardFocus() } }
        .onChange(of: isActive) { _, now in
            if now {
                pullKeyboardFocus()
                // Focusing the pane acknowledges a "needs you": stop the
                // attention pulse (its continuous render) — you're looking
                // at it now. The notification in the center stays.
                if pane.agent.phase == .attention {
                    // Acknowledged, not gone: drop to `.ready` so the pulse
                    // stops but the agent stays in the roster (it's still
                    // running, just no longer demanding attention).
                    pane.agent = AgentStatus(phase: .ready, tool: pane.agent.tool)
                    owningTab?.recomputeAgentPhase()
                }
            }
        }
        // "needs you" calms to `.ready` after 30s even unfocused, so a pill
        // you never return to stops pulsing (and draining) — but the agent
        // stays in the roster, since it's still alive and waiting.
        .onChange(of: pane.agent.phase) { _, phase in
            guard phase == .attention else { return }
            attentionGen &+= 1
            let gen = attentionGen
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if attentionGen == gen, pane.agent.phase == .attention {
                    pane.agent = AgentStatus(phase: .ready, tool: pane.agent.tool)
                    owningTab?.recomputeAgentPhase()
                }
            }
        }
        .animation(Theme.Spring.soft, value: isActive)
    }

    /// Pulls AppKit's first-responder to this pane's NSView so typing
    /// works without a click. Bounces to the next runloop so the view is
    /// fully mounted in the window before we ask for the responder swap.
    private func pullKeyboardFocus() {
        DispatchQueue.main.async {
            guard let v = pane.controller?.view,
                  let w = v.window,
                  w.isKeyWindow else { return }
            w.makeFirstResponder(v)
        }
    }
}

/// OSC 7 reports pwd as `file://hostname/percent-encoded/path`. Without
/// decoding, the title looks like `~%2FDocuments` or has replacement
/// glyphs (?). URL-parse → strip scheme → percent-decode → last
/// component. Falls through gracefully for plain-path inputs too.
@MainActor
private func decodePwdForTitle(_ raw: String) -> String {
    let path = decodePwdToPath(raw)
    let base = (path as NSString).lastPathComponent
    return base.isEmpty ? path : base
}

/// Returns the full decoded absolute path from an OSC 7 pwd report.
/// Handles `file://`, `kitty-shell-cwd://` (what Ghostty's bundled zsh
/// integration emits), bare paths, and `user@host:path` strings (the
/// non-standard format many zsh prompt-title hooks emit through OSC 7).
@MainActor
private func decodePwdToPath(_ raw: String) -> String {
    decodePwd(raw).path
}

/// Returns both the decoded path AND the URL host (if any) from
/// an OSC 7 pwd report. The host lets us detect SSH state: when
/// the OSC 7 URL's host doesn't match our local hostname, we're
/// inside an ssh session.
@MainActor
private func decodePwd(_ raw: String) -> (path: String, host: String?) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: trimmed),
       url.scheme == "file" || url.scheme == "kitty-shell-cwd" {
        return (url.path, url.host)
    }
    if let colonIdx = trimmed.firstIndex(of: ":"),
       trimmed[trimmed.startIndex..<colonIdx].contains("@") {
        let path = String(trimmed[trimmed.index(after: colonIdx)...])
        return (expandTilde(path), nil)
    }
    return (expandTilde(trimmed.removingPercentEncoding ?? trimmed), nil)
}

/// Local hostname(s) for SSH-detection purposes. Both bare ("x0rz")
/// and dotted ("x0rz.local") forms are returned so an OSC title in
/// either form matches.
///
/// CRITICAL: this must use ONLY non-blocking, local sources. The old
/// implementation called `Host.current().names`, which performs a
/// synchronous reverse-DNS resolution. It was triggered lazily by the
/// first shell-prompt OSC title — right during the launch animation —
/// so on a network with slow/unreachable DNS the main thread blocked
/// for seconds: the intro froze, the OS flagged the app
/// non-responsive, then it "skipped" once DNS finally timed out.
/// `gethostname(2)` + `ProcessInfo.hostName` are pure local syscalls
/// (no network) and give us everything we actually need.
@MainActor
private let localHostnames: Set<String> = {
    var names = Set<String>(["localhost"])

    func add(_ raw: String) {
        let lc = raw.lowercased()
        guard !lc.isEmpty else { return }
        names.insert(lc)
        // Also index the bare form before the first dot
        // (e.g. "x0rz" from "x0rz.local").
        if let dot = lc.firstIndex(of: ".") {
            names.insert(String(lc[lc.startIndex..<dot]))
        }
    }

    // Kernel hostname via gethostname(2) — a pure local syscall, no
    // network/DNS, microseconds. This is exactly the value a shell's
    // prompt `%m` / `hostname` reports, which is what appears in the
    // `user@host:path` OSC titles we match against. We deliberately do
    // NOT use `Host.current()` or `ProcessInfo.hostName` here — both
    // can perform blocking DNS resolution.
    var buf = [CChar](repeating: 0, count: 256)
    if gethostname(&buf, buf.count) == 0 {
        add(String(cString: buf))
    }

    return names
}()

/// `~` / `~/foo` → `<HOME>` / `<HOME>/foo`. Bare paths pass through.
@MainActor
private func expandTilde(_ p: String) -> String {
    if p == "~" { return NSHomeDirectory() }
    if p.hasPrefix("~/") { return NSHomeDirectory() + String(p.dropFirst(1)) }
    return p
}

/// If the title looks like a command line that starts with `ssh`
/// (or `mosh`, also a remote-shell tool), extract the target host
/// argument. Aliases from `~/.ssh/config` come through as the user
/// typed them — we don't try to resolve them, since the alias is
/// usually the more meaningful label anyway.
///
/// Returns nil for anything that isn't an ssh/mosh command line.
@MainActor
private func extractSshTarget(from title: String) -> String? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard let first = parts.first,
          first == "ssh" || first == "mosh" || first == "ssh-copy-id" else {
        return nil
    }
    // Walk past flags. Some ssh flags take an argument (e.g. `-i key`,
    // `-p port`, `-o opt`); we consume both flag and value.
    let flagsWithArg: Set<Character> = ["i", "p", "o", "F", "L", "R", "D", "l", "J", "W", "b", "B", "c", "E", "I", "m", "O", "Q", "S", "w"]
    var i = 1
    while i < parts.count {
        let p = parts[i]
        if p.hasPrefix("-") {
            // `-X` may take an arg; `-Xvalue` is bundled (no arg
            // needed); `--foo=bar` always has the arg inline.
            if p.count == 2, let ch = p.last, flagsWithArg.contains(ch), i + 1 < parts.count {
                i += 2
                continue
            }
            i += 1
            continue
        }
        // First non-flag word is the host (possibly `user@host`).
        if let atIdx = p.firstIndex(of: "@") {
            return String(p[p.index(after: atIdx)...])
        }
        return p
    }
    return nil
}

/// Is this title in the local `user@<localhostname>:path` form? We
/// use this to know when an ssh session has ended (and clear the
/// pane's `remoteHost`).
@MainActor
private func isLocalPromptTitle(_ title: String) -> Bool {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let atIdx = trimmed.firstIndex(of: "@"),
          let colonIdx = trimmed[atIdx...].firstIndex(of: ":") else { return false }
    let host = trimmed[trimmed.index(after: atIdx)..<colonIdx].lowercased()
    return localHostnames.contains(host)
}

/// Extract a usable absolute path from a title string. Accepts:
/// - `user@host:path` (omz_termsupport format)
/// - `~` and `~/foo` (ghostty integration format for ≤3-deep paths)
/// - bare `/foo` (already absolute)
/// Returns nil for the truncated `…/last/3/parts` form (we can't
/// recover the full path from that), or for command strings emitted
/// during preexec.
@MainActor
private func extractCwdFromTitle(_ title: String) -> String? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }

    // omz format: `user@host:path`
    if Ghostty.SurfaceController.looksLikeUserAtHostPath(trimmed) {
        return decodePwdToPath(trimmed)
    }
    // Already an absolute path or tilde-shortened path.
    if trimmed == "~" || trimmed.hasPrefix("~/") {
        return expandTilde(trimmed)
    }
    if trimmed.hasPrefix("/") {
        return trimmed
    }
    return nil
}

/// String-based filter — does the decoded value plausibly look like an
/// absolute filesystem path? We do NOT use `FileManager.fileExists`
/// because that triggers macOS TCC ("would like to access Documents")
/// permission dialogs whenever the shell cd's into a protected dir.
/// The garbage emits we want to reject contain control characters and
/// don't start with "/", so a simple syntactic check is sufficient.
@MainActor
private func isPlausibleAbsolutePath(_ p: String) -> Bool {
    guard p.hasPrefix("/") else { return false }
    guard p.count >= 1, p.count < 4096 else { return false }
    // No ASCII control characters (covers \x00-\x1F + \x7F). These are
    // the signature of corrupted OSC payloads — clean filesystem paths
    // on macOS never contain them in practice.
    for scalar in p.unicodeScalars {
        if scalar.value < 0x20 || scalar.value == 0x7F { return false }
    }
    return true
}

/// The actual NSViewRepresentable that births the libghostty surface.
/// Returns a stable `SurfaceHostView` container, not the SurfaceView
/// directly — see SurfaceHostView's doc comment for the architectural
/// reasoning.
private struct GhosttySurfaceRep: NSViewRepresentable {
    @ObservedObject var pane: Pane
    let app: Ghostty.App
    /// The current SwiftUI-allocated size, threaded from the
    /// enclosing GeometryReader. We use this to drive layout
    /// updates because SwiftUI on macOS doesn't reliably fire
    /// NSView resize hooks on the representable view.
    let size: CGSize
    @EnvironmentObject var state: AppState
    @EnvironmentObject var notifications: NotificationStore
    @EnvironmentObject var prefs: Preferences

    func makeNSView(context: Context) -> Ghostty.SurfaceHostView {
        // If this pane already has a controller (e.g. SwiftUI is
        // re-mounting our representable after a split moved the pane
        // into a different layout slot), reuse the existing host.
        // NEVER create a second controller — that's what caused the
        // "empty pane" ghosts during rapid splits (and explains the
        // tty-number jumps-by-2 the user noticed).
        if let existing = pane.controller, let host = existing.hostView {
            return host
        }

        // Build the controller and assign it to `pane.controller`
        // BEFORE doing anything that could yield to SwiftUI (e.g.
        // calling `start()` which triggers ghostty_surface_new). The
        // @Published pane.controller setter can trigger a re-render
        // mid-construction; if that re-render races a second
        // makeNSView call before we've assigned pane.controller,
        // we'd create a second controller + a second surface
        // (visible as duplicate/skipped tty numbers).
        let view = Ghostty.SurfaceView(frame: .zero)
        let host = Ghostty.SurfaceHostView(surfaceView: view)
        let controller = Ghostty.SurfaceController(app: app)
        controller.view = view
        controller.hostView = host
        view.controller = controller
        controller.startingDir = pane.startingDir
        pane.controller = controller

        let owningTab = state.tabs.first { tab in
            tab.paneTree.root.leaves().contains { $0.id == pane.id }
        }
        controller.onPwdChange = { [weak pane, weak owningTab] newPwd in
            DispatchQueue.main.async {
                let decoded = decodePwd(newPwd)
                // STRING-based validation only — do NOT use
                // FileManager.fileExists here (triggers TCC).
                if isPlausibleAbsolutePath(decoded.path) {
                    pane?.cwd = decoded.path
                    clog("conterm: pane.cwd ← \(decoded.path)  (raw=\(newPwd))")
                    // A real OSC 7 pwd comes from the SHELL's precmd —
                    // it only fires when we're back at the shell prompt,
                    // never from inside a full-screen agent TUI. So if
                    // an agent pill is showing, the agent has exited
                    // (e.g. Ctrl+D'd opencode, whose own exit signal is
                    // unreliable). Clear it. Agent-agnostic + free.
                    if let p = pane, p.agent.phase != .idle {
                        p.agent = .idle
                        owningTab?.recomputeAgentPhase()
                    }
                } else {
                    clog("conterm: REJECT pane.cwd \(decoded.path) (raw=\(newPwd))")
                }
                // SSH detection: when OSC 7's URL has a host
                // component AND it doesn't match our local hostname,
                // we're inside an ssh session. The title bar uses
                // this in place of the local cwd. When you `exit`
                // the ssh session, the local shell emits OSC 7 again
                // with the local host — and remoteHost is cleared.
                if let host = decoded.host?.lowercased() {
                    if localHostnames.contains(host) {
                        if pane?.remoteHost != nil {
                            pane?.remoteHost = nil
                        }
                    } else {
                        if pane?.remoteHost != host {
                            pane?.remoteHost = host
                            clog("conterm: pane.remoteHost ← \(host)")
                        }
                    }
                }
                if let tab = owningTab {
                    let label = decodePwdForTitle(newPwd)
                    tab.pwdLabel = label
                    tab.refreshTitleFromMetadata()
                }
            }
        }
        controller.onTitleChange = { [weak pane, weak owningTab] newTitle in
            DispatchQueue.main.async {
                if newTitle.contains("\u{FFFD}") { return }

                // SSH DETECTION via the command title that oh-my-zsh's
                // preexec sets. When you run `ssh myserver`, omz
                // emits OSC 2 with the full command line as the title
                // — we parse the host argument and show it in the
                // badge. Aliases from ~/.ssh/config show as you typed
                // them (e.g. `ssh server-prod` → "server-prod"),
                // which is usually what you want.
                if let host = extractSshTarget(from: newTitle) {
                    if pane?.remoteHost != host {
                        pane?.remoteHost = host
                        clog("conterm: pane.remoteHost ← \(host)  (from ssh title)")
                    }
                } else if let candidate = extractCwdFromTitle(newTitle) {
                    // Title is back to a normal prompt — we're either
                    // local OR inside the remote ssh prompt. Auto-clear
                    // remoteHost only when it's a LOCAL-looking title
                    // (user@<localhost>:~/path).
                    if isLocalPromptTitle(newTitle), pane?.remoteHost != nil {
                        pane?.remoteHost = nil
                        clog("conterm: pane.remoteHost ← nil  (back to local prompt)")
                    }
                    if isPlausibleAbsolutePath(candidate),
                       pane?.cwd != candidate {
                        pane?.cwd = candidate
                        clog("conterm: pane.cwd ← \(candidate)  (from title fallback, raw=\(newTitle))")
                    }
                }

                guard let tab = owningTab else { return }
                tab.shellTitle = newTitle
                tab.refreshTitleFromMetadata()
            }
        }
        controller.onActivate = { [weak pane, weak owningTab] in
            DispatchQueue.main.async {
                guard let pane, let tab = owningTab else { return }
                // Tick only on a real focus change — onActivate also
                // re-fires for the already-active pane (app activation,
                // overlay dismiss refocus), which must stay silent.
                if tab.paneTree.activePaneID != pane.id {
                    SoundEffects.shared.play(.paneSwitch)
                }
                tab.paneTree.focus(pane)
            }
        }
        controller.onClose = { [weak pane, weak owningTab, weak state] in
            DispatchQueue.main.async {
                guard let pane, let tab = owningTab, let state else { return }
                state.closePane(tab: tab, paneID: pane.id)
            }
        }
        controller.onSplit = { [weak pane, weak owningTab, weak state] axis in
            DispatchQueue.main.async {
                guard let pane, let tab = owningTab, let state else { return }
                // Make sure the split happens off THIS pane (right-click
                // doesn't change focus), then split the active tab.
                tab.paneTree.focus(pane)
                state.select(tab.id)
                state.splitSelected(direction: axis)
            }
        }
        // Claude Code (or any agent) progress → "working" pill.
        // OSC 9;4 states: 0 remove · 1 set(%) · 2 error · 3 indeterminate
        // · 4 pause. set/indeterminate ⇒ thinking; remove/error clears.
        // OSC 9;4 progress only AUGMENTS the working state with a
        // percent — it never drives phase (that's the deterministic
        // protocol below). state 1=set(%), others ignored here.
        controller.onAgentProgress = { [weak pane] state, percent in
            DispatchQueue.main.async {
                guard let pane, pane.agent.phase == .working else { return }
                if state == 1, percent >= 0 {
                    // Bucket to 5% steps: an agent can emit progress many
                    // times a second, and each distinct value rewrites the
                    // pill label (which carries the percent) and re-renders
                    // it. Only publish when the displayed step changes.
                    let bucket = min(100, (percent / 5) * 5)
                    guard pane.agent.progress != bucket else { return }
                    var s = pane.agent; s.progress = bucket; pane.agent = s
                }
            }
        }
        // Esc while the agent is "thinking" = user interrupt. Claude
        // Code's Esc cancel emits no Stop hook, so the pill would stay
        // on "thinking…"; flip it to "interrupted", then settle to the
        // ready prompt the agent returns to — unless a new turn (a fresh
        // prompt/tool hook) already moved the phase on.
        controller.onInterrupt = { [weak pane, weak owningTab] in
            DispatchQueue.main.async {
                guard let pane, pane.agent.phase == .working else { return }
                let tool = pane.agent.tool
                pane.agent = AgentStatus(phase: .interrupted, tool: tool)
                owningTab?.recomputeAgentPhase()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    guard pane.agent.phase == .interrupted,
                          pane.agent.tool == tool else { return }
                    pane.agent = AgentStatus(phase: .ready, tool: tool)
                    owningTab?.recomputeAgentPhase()
                }
            }
        }
        // Deterministic protocol: the Claude/opencode hooks emit
        //   OSC 9 ; conterm-agent:<tool>:<state>[:<transcript_path>] BEL
        // <state> ∈ start | prompt | idle | attention | end. Claude carries
        // its transcript path so the command center reads the exact session.
        // We ONLY react to our own prefix, so normal desktop
        // notifications never hijack the pill.
        controller.onAgentNotify = { [weak pane, weak owningTab, notifications] title, body in
            DispatchQueue.main.async {
                guard let pane else { return }
                let msg = body.isEmpty ? title : body
                let prefix = "conterm-agent:"
                guard let r = msg.range(of: prefix) else { return }
                let parts = msg[r.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: ":", maxSplits: 2).map(String.init)
                guard let toolRaw = parts.first else { return }
                let tool = AgentTool(rawValue: toolRaw) ?? .generic
                let stateStr = parts.count > 1 ? parts[1] : ""
                // A path is paths-only (no colons on macOS); empty means the
                // hook couldn't read it — leave whatever we already have.
                if parts.count > 2, !parts[2].isEmpty {
                    pane.agentTranscriptPath = parts[2]
                }
                let phase: AgentStatus.Phase
                switch stateStr {
                case "start", "idle", "stop": phase = .ready
                case "prompt", "working":     phase = .working
                case "attention", "notify":   phase = .attention
                case "end", "exit":           phase = .idle
                default:                      return
                }
                if phase == .idle { pane.agentTranscriptPath = nil }
                let prev = pane.agent.phase
                let next = AgentStatus(phase: phase, tool: tool,
                                       progress: nil)
                // Defensive dedupe: never re-render the pill for an
                // identical state, even if a hook/plugin double-sends.
                guard pane.agent != next else { return }
                pane.agent = next
                owningTab?.recomputeAgentPhase()

                // Feed the notification center on the two transitions
                // worth surfacing: the agent needs you (blocked on
                // input/permission), and the agent just finished a turn
                // (working → ready). Everything else (start, end, the
                // initial ready) is pill-only noise — don't post it.
                let name = tool.displayName
                if phase == .attention, prev != .attention {
                    notifications.post(tool: tool,
                                       title: "\(name) needs you",
                                       message: "Waiting for your input")
                } else if phase == .ready, prev == .working {
                    notifications.post(tool: tool,
                                       title: "\(name) finished",
                                       message: "Task complete — back to you")
                }
            }
        }
        // OSC 133 command-end marks. Updates the pane's transient
        // result badge, and — for commands long enough that you'd have
        // stepped away — posts a notification when one finishes while
        // you're NOT watching this pane (different pane / tab / window,
        // or Conterm in the background).
        controller.onCommandFinished = { [weak pane, weak owningTab, weak state, notifications, prefs] exitCode, durationNs in
            DispatchQueue.main.async {
                guard let pane else { return }

                // OSC 133;D fires from the outer interactive shell when
                // its foreground command exits. If the agent's Stop /
                // SessionEnd hook failed to land (wrapped process tree,
                // killed mid-stream), the agent's `claude` command
                // exiting still walks back to a shell prompt and emits
                // 133;D. Clearing the pill here makes that the secondary
                // safety net alongside the OSC 7 PWD path above.
                if pane.agent.phase != .idle {
                    pane.agent = .idle
                    owningTab?.recomputeAgentPhase()
                }

                guard prefs.commandAlerts else { return }
                let result = Pane.CommandResult(exitCode: exitCode,
                                                durationNs: durationNs,
                                                at: Date())
                pane.lastCommand = result

                guard durationNs >= 10_000_000_000 else { return }  // 10s
                let watching = NSApp.isActive
                    && state?.selectedID == owningTab?.id
                    && owningTab?.paneTree.activePaneID == pane.id
                guard !watching else { return }
                let dir = friendlyDirLabel(for: pane.cwd)
                let dur = formatCommandDuration(durationNs)
                if result.failed {
                    notifications.post(tool: .generic,
                                       title: "Command failed",
                                       message: "exit \(exitCode) · \(dur) · \(dir)")
                } else {
                    notifications.post(tool: .generic,
                                       title: "Command finished",
                                       message: "\(dur) · \(dir)")
                }
            }
        }

        _ = controller.start(view: view)
        pane.startingDir = nil
        // A surface born into a non-selected tab (session restore
        // mounts every tab's panes at once) must start with its
        // renderer paused, not wait for the next tab switch.
        state.syncSurfaceOcclusion()

        return host
    }

    func updateNSView(_ host: Ghostty.SurfaceHostView, context: Context) {
        // Drive the size update through the host's layout cycle.
        // Setting needsLayout=true schedules layout() on the next
        // AppKit display tick; layout() in turn calls
        // surfaceView.pushSizeToSurface() with the host's current
        // (now-updated) bounds.
        if host.bounds.size != size {
            host.needsLayout = true
        }
    }

    static func dismantleNSView(_ host: Ghostty.SurfaceHostView, coordinator: ()) {}
}
