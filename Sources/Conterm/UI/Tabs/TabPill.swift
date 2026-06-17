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

    @EnvironmentObject var tabGroups: TabGroupStore
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences
    @State private var hovering = false
    @State private var hoveringClose = false

    /// Resolved group for this tab (looked up via TabGroupStore).
    /// Re-evaluated on every body so changes propagate.
    private var group: TabGroup? { tabGroups.group(id: tab.groupID) }

    var body: some View {
        HStack(spacing: 8) {
            statusDot
            titleLabel
            Spacer(minLength: 0)
            badge
            closeButton
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .frame(width: hovering ? 18 : 0)
                .animation(Theme.Spring.snappy, value: hovering)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(pillBackground)
        // Group accent: a thin coloured bar across the top of the
        // pill when this tab belongs to a group. Browser-style.
        .overlay(alignment: .top) {
            if let g = group {
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
        // close action instead of select — fixes the bug where the
        // catcher absorbed hover events so the close button could
        // never become hit-testable.
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
        .scaleEffect(hovering && !isSelected ? 1.02 : 1.0)
        .onHover { hovering = $0 }
        .animation(Theme.Spring.snappy, value: hovering)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.7).combined(with: .opacity),
            removal:   .scale(scale: 0.5).combined(with: .opacity)
        ))
    }

    // MARK: - Background (three visible layers)

    /// Horizontal: a flat tinted lens on the window glass sheet (the desktop
    /// reads through it). Vertical: a solid bed — the sidebar is a wider
    /// expanse where translucent pills over the desktop read as noise, so
    /// the pills go opaque. Either way the travelling accent glow (TabBar)
    /// and `pillTrim` supply the selection cue on top.
    private var pillBackground: some View {
        let corner = Theme.pillCorner
        let vertical = prefs.tabOrientation == .vertical
        return ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(vertical ? Theme.paneTitleBar
                               : chromeFill(prefs, selected: isSelected))
                .opacity(vertical ? 1.0 : (isSelected ? 1.0 : (hovering ? 0.9 : 0.7)))
            pillTrim
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
                    isSelected ? Color.white.opacity(0.30)
                                : Color.white.opacity(0.06),
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
        return Circle()
            .fill(baseColor)
            .frame(width: 6, height: 6)
            .shadow(color: isSelected ? baseColor.opacity(0.55) : .clear,
                    radius: isSelected ? 3 : 0)
            .animation(Theme.Spring.snappy, value: isSelected)
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
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular,
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
