import SwiftUI

/// A tab rendered as a *stacked-glass card* — three visible layers:
///   1. a dark vibrancy base so the pill carves itself out of the chrome
///   2. an ultra-thin material slab in the middle (the "glass")
///   3. a top inner highlight stroke (the "wet" light catching the edge)
/// Selected tabs gain an accent fill behind the glass, lifted by a soft
/// outer glow. Number badge is a keycap-shaped chip on the right.
struct TabPill: View {
    @ObservedObject var tab: Tab
    var index: Int
    var isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    /// Open the rename overlay for this tab. Rename is now a focused
    /// glass panel (like search) — NOT an inline tab-bar TextField,
    /// which couldn't reliably hold first responder against the
    /// terminal NSView + context-menu focus restoration.
    var onBeginRename: () -> Void
    /// Slim sidebar-row layout (vertical mode): tighter padding, a lighter
    /// hover/selected wash instead of the full glass card, and no per-pill
    /// group accent — the collapsible section header carries the colour.
    var compact: Bool = false
    /// Rendered nested under a group folder header (vertical tree view): the
    /// folder owns the group colour, so the per-pill accent bar is dropped.
    var inGroupFolder: Bool = false

    @EnvironmentObject var tabGroups: TabGroupStore
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences
    @State private var hovering = false
    @State private var hoveringClose = false

    /// Resolved group for this tab (looked up via TabGroupStore).
    /// Re-evaluated on every body so changes propagate.
    private var group: TabGroup? { tabGroups.group(id: tab.groupID) }

    var body: some View {
        HStack(spacing: compact ? 7 : 8) {
            statusDot
            titleLabel
            Spacer(minLength: 0)
            if !compact { badge }
            closeButton
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .frame(width: hovering ? 18 : 0)
                .animation(Theme.Spring.snappy, value: hovering)
        }
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 6 : 7)
        .background(pillBackground)
        // Group accent: a thin coloured bar across the top of the
        // pill when this tab belongs to a group. Browser-style. In the
        // sidebar the section header owns the colour, so the per-pill bar
        // is dropped there.
        .overlay(alignment: .top) {
            if let g = group, !compact, !inGroupFolder {
                Capsule(style: .continuous)
                    .fill(TabGroup.color(forKey: g.colorKey))
                    .frame(height: 2)
                    .padding(.horizontal, 6)
                    .opacity(isSelected ? 0.95 : 0.55)
                    .allowsHitTesting(false)
            }
        }
        // (The selected-tab halo now travels: it's a single shared
        //  glow rendered by TabBar via matchedGeometry, so switching
        //  tabs glides the light across instead of snapping it.)
        .contentShape(RoundedRectangle(cornerRadius: Theme.pillCorner,
                                        style: .continuous))
        // AppKit-level click handling — no double-click disambiguation
        // delay. Single click selects; double click renames. Trailing
        // ~24 pt zone (where the close X sits when hovering) fires the
        // close action instead of select, so the close button stays
        // hit-testable rather than being swallowed by the hover catcher.
        .overlay {
            ClickCatcher(
                // Single-click selects. Double-click is a no-op (it
                // used to start rename and fought double-click-to-zoom).
                onSingle: onSelect,
                onDouble: {},
                trailingZoneWidth: hovering ? 24 : 0,
                onTrailingClick: onClose
            )
            .allowsHitTesting(true)
        }
        // Right-click a tab → standard tab menu. Rename opens a focused
        // glass overlay (reliable focus), not an inline field.
        .contextMenu {
            Button("Rename…") { onBeginRename() }
            Button("Close Tab") { onClose() }
            Divider()
            groupMenu
        }
        // No hover-scale in the sidebar — scaling rows in a tight list
        // reads as jitter. Horizontal cards still lift slightly.
        .scaleEffect(!compact && hovering && !isSelected ? 1.02 : 1.0)
        .onHover { hovering = $0 }
        .animation(Theme.Spring.snappy, value: hovering)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.7).combined(with: .opacity),
            removal:   .scale(scale: 0.5).combined(with: .opacity)
        ))
    }

    // MARK: - Background (three visible layers)

    /// Horizontal: a flat tinted lens on the window glass sheet. Vertical:
    /// the v2.0.0 frosted-glass card — a faint dark base for contrast on
    /// bright desktops, then `.ultraThinMaterial` that lifts in on hover /
    /// selection so the pill reads as translucent glass, not an opaque slab.
    /// Either way the travelling accent glow (TabBar) and `pillTrim` supply
    /// the selection cue on top.
    @ViewBuilder
    private var pillBackground: some View {
        let corner = Theme.pillCorner
        if compact {
            // Slim row, but each tab still reads as a bounded box: a faint
            // resting bed + hairline edge so the boundary never vanishes —
            // even mid-switch when the travelling selection glow has slid
            // off this pill. Fill + edge lift on hover / selection.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.09)
                                 : (hovering ? Color.white.opacity(0.06)
                                             : Color.white.opacity(0.035)))
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Color.white.opacity(isSelected ? 0.18 : 0.10),
                                      lineWidth: 0.5)
                )
        } else if prefs.tabOrientation == .vertical {
            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.black.opacity(isSelected ? 0.25 : 0.08))
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(isSelected ? 1.0 : (hovering ? 0.6 : 0.0))
                pillTrim
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(chromeFill(prefs, selected: isSelected))
                    .opacity(isSelected ? 1.0 : (hovering ? 0.9 : 0.7))
                pillTrim
            }
        }
    }

    /// Selected-accent wash + wet-glass edge highlight + outline —
    /// shared by both background variants (rides on top of whatever
    /// material is underneath).
    private var pillTrim: some View {
        let corner = Theme.pillCorner
        return ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.06),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            }
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isSelected ? 0.55 : 0.22),
                            Color.clear,
                        ],
                        startPoint: .top, endPoint: .center
                    ),
                    lineWidth: 0.5
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(
                    // Adaptive outline: white on dark glass, black on light
                    // — a white rim vanishes on a light pill, leaving it
                    // undefined.
                    isSelected
                        ? Theme.dynamic(light: NSColor(white: 0.0, alpha: 0.22),
                                        dark:  NSColor(white: 1.0, alpha: 0.30))
                        : Theme.dynamic(light: NSColor(white: 0.0, alpha: 0.10),
                                        dark:  NSColor(white: 1.0, alpha: 0.06)),
                    lineWidth: 0.5
                )
        }
    }

    // MARK: - Subviews

    private var statusDot: some View {
        // When the tab is in a group, the dot picks up the group
        // color so multiple grouped tabs read as related at a glance.
        let baseColor: Color = {
            if let g = group {
                return TabGroup.color(forKey: g.colorKey)
            }
            return isSelected ? Theme.textPrimary
                              : Theme.textSecondary.opacity(0.7)
        }()
        // An agent running in any of this tab's panes overrides the dot so
        // a background "needs you" / "thinking" is visible from the bar.
        let agentColor: Color? = {
            switch tab.agentPhase {
            case .attention: return Color(red: 0.93, green: 0.49, blue: 0.20)
            case .working:   return Color(red: 0.93, green: 0.49, blue: 0.20).opacity(0.85)
            default:         return nil
            }
        }()
        let color = agentColor ?? baseColor
        let lit = tab.agentPhase == .attention || isSelected
        return Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: lit ? color.opacity(0.6) : .clear,
                    radius: lit ? 3 : 0)
            .animation(Theme.Spring.snappy, value: isSelected)
            .animation(Theme.Spring.snappy, value: tab.agentPhase)
    }

    /// Right-click submenu for browser-style tab groups.
    @ViewBuilder
    private var groupMenu: some View {
        Menu("Group") {
            // Existing groups → "Move to X" with their colored bullet.
            if !tabGroups.groups.isEmpty {
                ForEach(tabGroups.groups) { g in
                    Button {
                        tab.groupID = g.id
                    } label: {
                        Label("Move to “\(g.name)”",
                              systemImage: "circle.fill")
                            .foregroundStyle(TabGroup.color(forKey: g.colorKey))
                    }
                }
                Divider()
            }
            // Always offer "New Group" — creates the group AND
            // assigns this tab to it.
            Button("New Group from This Tab") {
                let g = tabGroups.create()
                tab.groupID = g.id
            }
            // Manage / edit this tab's own group: rename + change
            // color + delete (deleting also un-assigns every tab
            // that was in it).
            if let gid = tab.groupID,
               let g = tabGroups.group(id: gid) {
                Divider()
                Button("Edit “\(g.name)” (Rename / Color / Delete)…") {
                    state.beginRenameGroup(gid)
                }
                Button("Remove from Group") {
                    tab.groupID = nil
                }
            }
        }
    }

    private var titleLabel: some View {
        Text(tab.title.isEmpty ? "shell" : tab.title)
            .font(.system(size: compact ? 12.5 : 13,
                           weight: isSelected ? .semibold : .regular,
                           design: .rounded))
            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Keycap-style ⌘N chip. Shown when selected/hovered, within the
    /// first 9 tabs.
    @ViewBuilder
    private var badge: some View {
        if index <= 9 {
            Text("⌘\(index)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(
                    ZStack {
                        Capsule().fill(chromeFill(prefs))
                        Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    }
                )
                .opacity(hovering || isSelected ? 1 : 0.0)
                .animation(Theme.Spring.snappy, value: hovering)
                .animation(Theme.Spring.snappy, value: isSelected)
        }
    }

    private var closeButton: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.textSecondary)
            .padding(3)
            .background(
                Circle().fill(hoveringClose ? Color.white.opacity(0.15) : .clear)
            )
            .scaleEffect(hoveringClose ? 1.2 : 1.0)
            .contentShape(Circle())
            .onHover { hoveringClose = $0 }
            .highPriorityGesture(TapGesture().onEnded(onClose))
            .animation(Theme.Spring.snappy, value: hoveringClose)
    }

}
